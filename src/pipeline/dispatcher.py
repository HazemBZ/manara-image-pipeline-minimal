"""SQS delivery is at-least-once. Pin one source version and start one Standard execution."""

import json
import logging
import os
from urllib.parse import unquote_plus

from boto3.dynamodb.conditions import Attr

from pipeline.common import JOB_ID, client, table

log = logging.getLogger(__name__)
log.setLevel(logging.INFO)


def dispatch(record):
    if not record.get("eventName", "").startswith("ObjectCreated:"):
        return
    bucket = record["s3"]["bucket"]["name"]
    key = unquote_plus(record["s3"]["object"]["key"])
    version = record["s3"]["object"].get("versionId")
    if bucket != os.environ["SOURCE_BUCKET"]:
        raise ValueError("Unexpected source bucket")
    parts = key.split("/")
    if len(parts) != 3 or parts[0] != "uploads" or parts[2] != "input":
        raise ValueError("Unexpected source key")
    job_id = parts[1]
    if not JOB_ID.fullmatch(job_id) or not version or version == "null":
        raise ValueError("A valid job and a versioned source object are required")
    jobs = table()
    try:
        jobs.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET source_version = if_not_exists(source_version, :v), #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":v": version, ":s": "QUEUED"},
            ConditionExpression=(
                Attr("source_key").eq(key)
                & Attr("status").is_in(["AWAITING_UPLOAD", "QUEUED"])
                & (Attr("source_version").not_exists() | Attr("source_version").eq(version))
            ),
        )
    except jobs.meta.client.exceptions.ConditionalCheckFailedException:
        item = jobs.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
        if not item:
            raise ValueError("Upload has no registered job") from None
        # A different upload version, or a job that has already started/finished, is a no-op.
        log.info("Ignored duplicate or superseded event for job %s", job_id)
        return

    payload = {"job_id": job_id, "source_key": key, "source_version": version}
    states = client("stepfunctions")
    try:
        states.start_execution(
            stateMachineArn=os.environ["STATE_MACHINE_ARN"],
            name=job_id,
            input=json.dumps(payload, sort_keys=True),
        )
    except states.exceptions.ExecutionAlreadyExists:
        # Stable execution name + stable payload closes the DDB/StartExecution retry gap.
        log.info("Execution already exists for job %s", job_id)


def handler(event, context):
    failures = []
    for message in event["Records"]:
        try:
            body = json.loads(message["body"])
            if body.get("Event") == "s3:TestEvent":
                continue
            for record in body["Records"]:
                dispatch(record)
        except Exception:
            # Per-message boundary: let SQS retry this message without replaying successful ones.
            log.exception("Dispatch failed for message %s", message["messageId"])
            failures.append({"itemIdentifier": message["messageId"]})
    return {"batchItemFailures": failures}
