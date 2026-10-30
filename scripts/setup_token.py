"""Generate a demo token locally. Only its SHA-256 hash is passed to Terraform."""

import argparse
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rotate", action="store_true", help="Replace the existing demo token")
    args = parser.parse_args()
    directory = ROOT / ".secrets"
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    path = directory / "demo-token"
    if path.exists() and not args.rotate:
        token = path.read_text().strip()
        print("Reusing the existing token. Use --rotate to intentionally replace it.")
    else:
        token = secrets.token_urlsafe(48)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(token + "\n")
    path.chmod(0o600)
    config = ROOT / "infra" / "credentials.auto.tfvars.json"
    config.write_text(
        json.dumps({"token_sha256": hashlib.sha256(token.encode()).hexdigest()}) + "\n"
    )
    config.chmod(0o600)
    print("Token saved to .secrets/demo-token (not printed). Only the hash is deployed.")
    print("Paste this token into the deployed UI; never commit it or include it in a recording.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
