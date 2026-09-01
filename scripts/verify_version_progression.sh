#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_VERSION="$(tr -d '[:space:]' < "${PROJECT_DIR}/VERSION")"
LATEST_VERSION="$(git -C "${PROJECT_DIR}" tag --list 'v[0-9]*' --sort=-v:refname | head -n 1 | sed 's/^v//')"

if [[ -z "${LATEST_VERSION}" ]]; then
    exit 0
fi

python3 - "${CURRENT_VERSION}" "${LATEST_VERSION}" <<'PY'
import re
import sys

def parse(value: str):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?", value)
    if match is None:
        raise SystemExit(f"Invalid semantic version: {value}")
    release = tuple(int(match.group(index)) for index in range(1, 4))
    prerelease = match.group(4)
    identifiers = None if prerelease is None else prerelease.split(".")
    return release, identifiers

def newer(current: str, latest: str) -> bool:
    current_release, current_pre = parse(current)
    latest_release, latest_pre = parse(latest)
    if current_release != latest_release:
        return current_release > latest_release
    if current_pre is None:
        return latest_pre is not None
    if latest_pre is None:
        return False
    for left, right in zip(current_pre, latest_pre):
        if left == right:
            continue
        left_numeric = left.isdigit()
        right_numeric = right.isdigit()
        if left_numeric and right_numeric:
            return int(left) > int(right)
        if left_numeric != right_numeric:
            return not left_numeric
        return left > right
    return len(current_pre) > len(latest_pre)

if not newer(sys.argv[1], sys.argv[2]):
    raise SystemExit(
        f"VERSION must be newer than the latest published tag: "
        f"current={sys.argv[1]} latest={sys.argv[2]}"
    )
PY
