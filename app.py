"""One Lambda: SQS messages → read S3 image → resize/watermark → write private S3."""

import io
import json
import logging
import os
import warnings
from functools import cache
from urllib.parse import unquote_plus

import boto3
from PIL import Image, ImageDraw, ImageOps

MAX_BYTES = 5 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 16_000_000
log = logging.getLogger(__name__)
log.setLevel(logging.INFO)


@cache
def s3():
    return boto3.client("s3")


def process_image(data):
    """Make one JPEG, at most 1280px per side. No database or workflow engine."""
    if not 0 < len(data) <= MAX_BYTES:
        raise ValueError("Image must be between 1 byte and 5 MiB")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(io.BytesIO(data)) as original:
            if original.format not in {"JPEG", "PNG", "WEBP"}:
                raise ValueError("Only JPEG, PNG, and WebP are supported")
            if getattr(original, "n_frames", 1) != 1:
                raise ValueError("Use a static image, not an animation")
            image = ImageOps.exif_transpose(original).convert("RGBA")
            image.thumbnail((1280, 1280), Image.Resampling.LANCZOS)
            # Flatten transparency onto white and keep only pixels, not EXIF/GPS metadata.
            output = Image.new("RGB", image.size, "white")
            output.paste(image, mask=image.getchannel("A"))
    draw = ImageDraw.Draw(output)
    text = "Manara"
    draw.text(
        (max(0, output.width - 55), max(0, output.height - 20)),
        text,
        fill="white",
        stroke_width=1,
        stroke_fill="black",
    )
    encoded = io.BytesIO()
    output.save(encoded, "JPEG", quality=85)
    return encoded.getvalue()


def process_record(record):
    if not record.get("eventName", "").startswith("ObjectCreated:"):
        return
    bucket = record["s3"]["bucket"]["name"]
    key = unquote_plus(record["s3"]["object"]["key"])
    if bucket != os.environ["SOURCE_BUCKET"] or not key.startswith("uploads/"):
        raise ValueError("Unexpected source bucket or key")
    result = s3().get_object(Bucket=bucket, Key=key)
    with result["Body"] as body:
        if result["ContentLength"] > MAX_BYTES:
            raise ValueError("Image exceeds 5 MiB")
        data = body.read(MAX_BYTES + 1)
    processed = process_image(data)
    # Same input key → same output key: duplicate deliveries overwrite, not multiply, results.
    destination = "processed/" + key.removeprefix("uploads/") + ".jpg"
    s3().put_object(
        Bucket=os.environ["OUTPUT_BUCKET"],
        Key=destination,
        Body=processed,
        ContentType="image/jpeg",
        ServerSideEncryption="AES256",
    )
    log.info("Processed %s", key)


def handler(event, context):
    failures = []
    for message in event["Records"]:
        try:
            body = json.loads(message["body"])
            if body.get("Event") == "s3:TestEvent":
                continue
            for record in body["Records"]:
                process_record(record)
        except Exception:
            # The failed message is retried by SQS, then moved to its DLQ.
            log.exception("Image job failed for message %s", message["messageId"])
            failures.append({"itemIdentifier": message["messageId"]})
    return {"batchItemFailures": failures}
