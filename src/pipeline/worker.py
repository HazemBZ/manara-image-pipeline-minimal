"""Step Functions tasks exchange S3 references, never binary image payloads."""

import json
import logging
import os
import time

from boto3.dynamodb.conditions import Attr

from pipeline.common import JOB_ID, MAX_BYTES, VARIANTS, client, table
from pipeline.imaging import InvalidImage, decode, jpeg, resized, watermarked

log = logging.getLogger(__name__)
log.setLevel(logging.INFO)


def read_object(bucket, key, version=None):
    params = {"Bucket": bucket, "Key": key}
    if version:
        params["VersionId"] = version
    result = client("s3").get_object(**params)
    with result["Body"] as stream:
        if result["ContentLength"] > MAX_BYTES:
            raise InvalidImage("Object is too large")
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise InvalidImage("Object is too large")
    return data


def write_intermediate(job_id, filename, data):
    client("s3").put_object(
        Bucket=os.environ["DESTINATION_BUCKET"],
        Key=f"internal/{job_id}/{filename}.jpg",
        Body=data,
        ContentType="image/jpeg",
        ServerSideEncryption="AES256",
    )


def source_image(event, mime=None):
    data = read_object(os.environ["SOURCE_BUCKET"], event["source_key"], event["source_version"])
    return decode(data, mime)


def validate(event):
    jobs = table()
    item = jobs.get_item(Key={"job_id": event["job_id"]}, ConsistentRead=True)["Item"]
    image, fmt = source_image(event, item["content_type"])
    metadata = {"width": image.width, "height": image.height, "format": fmt}
    jobs.update_item(
        Key={"job_id": event["job_id"]},
        UpdateExpression="SET #s = :s, metadata = :m",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "PROCESSING", ":m": metadata},
        ConditionExpression=Attr("source_version").eq(event["source_version"])
        & Attr("status").is_in(["QUEUED", "PROCESSING"]),
    )
    return {**event, "metadata": metadata}


def resize(event):
    image, _ = source_image(event)
    for name, size in VARIANTS.items():
        write_intermediate(event["job_id"], f"resized-{name}", jpeg(resized(image, size)))
    return event


def watermark(event):
    job_id = event["job_id"]
    for name in VARIANTS:
        data = read_object(
            os.environ["DESTINATION_BUCKET"], f"internal/{job_id}/resized-{name}.jpg"
        )
        image, _ = decode(data)
        result = watermarked(image, os.environ.get("WATERMARK_TEXT", "Manara"))
        write_intermediate(job_id, f"watermarked-{name}", jpeg(result))
    return event


def store(event):
    job_id = event["job_id"]
    bucket = os.environ["DESTINATION_BUCKET"]
    for name in VARIANTS:
        client("s3").copy_object(
            Bucket=bucket,
            Key=f"images/{job_id}/{name}.jpg",
            CopySource={"Bucket": bucket, "Key": f"internal/{job_id}/watermarked-{name}.jpg"},
            MetadataDirective="REPLACE",
            ContentType="image/jpeg",
            CacheControl="public, max-age=86400, immutable",
            ServerSideEncryption="AES256",
        )
    table().update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET #s = :s, completed_at = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "COMPLETED", ":t": int(time.time())},
        ConditionExpression=Attr("source_version").eq(event["source_version"])
        & Attr("status").is_in(["PROCESSING", "COMPLETED"]),
    )
    return event


def mark_failed(event):
    jobs = table()
    try:
        jobs.update_item(
            Key={"job_id": event["job_id"]},
            UpdateExpression="SET #s = :s, #e = :e, completed_at = :t",
            ExpressionAttributeNames={"#s": "status", "#e": "error"},
            ExpressionAttributeValues={
                ":s": "FAILED",
                ":e": "Image processing failed. Check the workflow execution logs.",
                ":t": int(time.time()),
            },
            ConditionExpression=Attr("job_id").exists()
            & ~Attr("status").is_in(["COMPLETED", "FAILED"]),
        )
        return True
    except jobs.meta.client.exceptions.ConditionalCheckFailedException:
        return False


def handler(event, context):
    if "detail" in event:
        # Recovery for whole-execution timeouts/aborts; Catch cannot catch these.
        detail = event["detail"]
        job_id = detail.get("name", detail.get("executionArn", "").rsplit(":", 1)[-1])
        if not JOB_ID.fullmatch(job_id):
            raise ValueError("Invalid execution name")
        if mark_failed({"job_id": job_id}):
            client("sns").publish(
                TopicArn=os.environ["TOPIC_ARN"],
                Subject="Image processing failed",
                Message=json.dumps({"job_id": job_id, "status": "FAILED"}),
            )
        return {"job_id": job_id}
    job_id = event.get("job_id", "")
    if not JOB_ID.fullmatch(job_id):
        raise ValueError("Invalid job ID")
    action = os.environ["TASK_ACTION"]
    log.info("Task %s for job %s", action, job_id)
    if action == "fail":
        mark_failed(event)
        return {"job_id": job_id, "status": "FAILED"}
    return {"validate": validate, "resize": resize, "watermark": watermark, "store": store}[action](
        event
    )
