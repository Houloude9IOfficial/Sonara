#!/usr/bin/env python3
"""Package the existing officially signed Android release on macOS or Linux."""

from __future__ import annotations

import hashlib
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "sonara"
ANDROID = APP / "android"


def main() -> None:
    key = ANDROID / "release-key.jks"
    properties = ANDROID / "key.properties"
    if not key.is_file() or not properties.is_file():
        raise SystemExit(
            "Android production signing requires the approved release-key.jks "
            "and key.properties in apps/sonara/android."
        )
    subprocess.run(["flutter", "build", "apk", "--release"], cwd=APP, check=True)
    source = APP / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if not source.is_file():
        raise SystemExit(f"Android release was not found at {source}")
    version = next(
        line.partition(":")[2].strip().split("+", 1)[0]
        for line in (APP / "pubspec.yaml").read_text().splitlines()
        if line.startswith("version:")
    )
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    target = dist / f"Sonara-{version}-android.apk"
    shutil.copy2(source, target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_name(target.name + ".sha256").write_text(f"{digest}  {target.name}\n")
    print(target)


if __name__ == "__main__":
    main()
