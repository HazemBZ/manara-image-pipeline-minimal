"""A shared, high-entropy demo token; not a multi-user identity system."""

import hashlib
import hmac
import os


def handler(event, context):
    headers = {key.lower(): value for key, value in event.get("headers", {}).items()}
    header = headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    expected = os.environ.get("TOKEN_SHA256", "")
    authorized = (
        scheme.lower() == "bearer"
        and 32 <= len(token) <= 512
        and len(expected) == 64
        and hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), expected)
    )
    return {"isAuthorized": bool(authorized)}
