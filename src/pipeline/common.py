"""Reusable AWS connections and small, deterministic helpers."""

import json
import os
import re
from decimal import Decimal
from functools import lru_cache

import boto3
from botocore.config import Config

MAX_BYTES = 10 * 1024 * 1024
MAX_PIXELS = 20_000_000
MIME_FORMATS = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}
JOB_ID = re.compile(r"^[0-9a-f]{32}$")
VARIANTS = {"thumbnail": (320, 320), "large": (1920, 1920)}
SDK_CONFIG = Config(
    retries={"mode": "standard", "total_max_attempts": 3},
    connect_timeout=3,
    read_timeout=20,
)


@lru_cache
def client(service):
    return boto3.client(service, config=SDK_CONFIG)


@lru_cache
def table():
    return boto3.resource("dynamodb", config=SDK_CONFIG).Table(os.environ["TABLE_NAME"])


def json_default(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Not JSON serializable: {type(value)}")


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body, default=json_default),
    }
