#!/bin/sh
set -eu

project_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_root"

# Build the committed project and assets; the Laravel website is not required.
python3 setup-cast.py
swift test --package-path "$project_root"
