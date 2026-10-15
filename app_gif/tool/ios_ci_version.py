"""Derive a fresh Codemagic build number from the committed app version."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def build_version(pubspec: str, project_build_number: str) -> tuple[str, int]:
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", pubspec, re.M)
    if not match:
        raise ValueError("pubspec.yaml must contain version: major.minor.patch+build")
    if not re.fullmatch(r"[0-9]+", project_build_number) or int(project_build_number) < 1:
        raise ValueError("PROJECT_BUILD_NUMBER must be a positive integer")
    build = int(match[2]) + int(project_build_number)
    if build > 9999:
        raise ValueError("Build number exceeds the iOS first-component limit; update versioning")
    return match[1], build


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--project-build-number", required=True)
    args = parser.parse_args()
    name, number = build_version(args.pubspec.read_text(encoding="utf-8"), args.project_build_number)
    # CM_ENV exports these to every later command; FLUTTER_BUILD_* is reserved.
    print(f"DOTLOOP_BUILD_NAME={name}")
    print(f"DOTLOOP_BUILD_NUMBER={number}")


if __name__ == "__main__":
    main()
