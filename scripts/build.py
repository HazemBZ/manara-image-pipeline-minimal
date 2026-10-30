"""Build deterministic handler and Linux/Python 3.13 dependency-layer ZIPs."""

import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"


def archive(source, destination):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for path in sorted(source.rglob("*")):
            if (
                not path.is_file()
                or "__pycache__" in path.parts
                or path.suffix == ".pyc"
                or any(part.endswith(".egg-info") for part in path.parts)
            ):
                continue
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), (2024, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(info, path.read_bytes())


def main():
    BUILD.mkdir(exist_ok=True)
    archive(ROOT / "src", BUILD / "handlers.zip")
    with tempfile.TemporaryDirectory(prefix="layer-", dir=BUILD) as directory:
        layer = Path(directory)
        subprocess.run(
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "--target",
                str(layer / "python"),
                "--only-binary=:all:",
                "--no-compile",
                "--platform",
                "manylinux_2_28_x86_64",
                "--platform",
                "manylinux2014_x86_64",
                "--implementation",
                "cp",
                "--abi",
                "cp313",
                "--python-version",
                "3.13",
                "--no-deps",
                "-r",
                str(ROOT / "requirements-lambda.txt"),
            ],
            check=True,
        )
        archive(layer, BUILD / "layer.zip")
    artifacts = {
        name: hashlib.sha256((BUILD / name).read_bytes()).hexdigest()
        for name in ("handlers.zip", "layer.zip")
    }
    (BUILD / "manifest.json").write_text(json.dumps(artifacts, indent=2) + "\n")
    print("Built handlers.zip and layer.zip for Lambda Python 3.13 / x86_64.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
