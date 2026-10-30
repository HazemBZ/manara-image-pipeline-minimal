"""Authenticated upload grants and job status. Never proxy image bytes through Lambda."""

import base64
import json
import os
import time
import uuid

from pipeline.common import JOB_ID, MAX_BYTES, MIME_FORMATS, client, response, table


def handler(event, context):
    route = event.get("routeKey", "")
    if route == "POST /uploads":
        return create_upload(event)
    if route == "GET /jobs/{job_id}":
        return get_job(event.get("pathParameters", {}).get("job_id", ""))
    return response(404, {"error": "Not found"})


def create_upload(event):
    try:
        raw = event.get("body") or "{}"
        if len(raw) > 8192:
            return response(413, {"error": "Request body too large"})
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw, validate=True).decode("utf-8")
        body = json.loads(raw)
        if not isinstance(body, dict):
            raise ValueError("Expected an object")
        mime = body.get("content_type")
        size = body.get("size")
        if not isinstance(mime, str) or mime not in MIME_FORMATS:
            return response(400, {"error": "Choose a JPEG, PNG, or WebP image"})
        if isinstance(size, bool) or not isinstance(size, int) or not 1 <= size <= MAX_BYTES:
            return response(400, {"error": "Image must be between 1 byte and 10 MiB"})
    except (ValueError, UnicodeError, TypeError):
        return response(400, {"error": "Invalid JSON request"})

    job_id = uuid.uuid4().hex
    source_key = f"uploads/{job_id}/input"
    now = int(time.time())
    upload = client("s3").generate_presigned_post(
        Bucket=os.environ["SOURCE_BUCKET"],
        Key=source_key,
        Fields={"Content-Type": mime},
        Conditions=[{"Content-Type": mime}, ["content-length-range", size, size]],
        ExpiresIn=300,
    )
    table().put_item(
        Item={
            "job_id": job_id,
            "status": "AWAITING_UPLOAD",
            "content_type": mime,
            "expected_bytes": size,
            "source_key": source_key,
            "created_at": now,
            "upload_expires_at": now + 300,
            "expires_at": now + 30 * 86400,
        }
    )
    return response(201, {"job_id": job_id, "upload": upload, "expires_in": 300})


def get_job(job_id):
    if not JOB_ID.fullmatch(job_id):
        return response(400, {"error": "Invalid job ID"})
    item = table().get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
    if not item or item["expires_at"] <= int(time.time()):
        return response(404, {"error": "Job not found or expired"})
    public = {
        key: item[key]
        for key in ("job_id", "status", "created_at", "completed_at", "metadata", "error")
        if key in item
    }
    if item["status"] == "AWAITING_UPLOAD" and item["upload_expires_at"] < int(time.time()):
        # A delayed S3 event may still advance this job. This is a UI hint, not a stored state.
        public["upload_expired"] = True
    if item["status"] == "COMPLETED":
        base = os.environ["CDN_URL"].rstrip("/")
        public["images"] = {
            name: f"{base}/images/{job_id}/{name}.jpg" for name in ("thumbnail", "large")
        }
    return response(200, public)
