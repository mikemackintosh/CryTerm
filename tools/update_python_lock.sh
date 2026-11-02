#!/bin/bash
# Regenerates the hash-pinned lock files for the Python packages iTerm2 installs
# into every script environment (iterm2, certifi, pyobjc and their dependencies).
#
# iTerm2 installs these with `uv pip install --require-hashes`, so it installs
# exactly the files recorded here and nothing PyPI serves later. Rerun this when
# you deliberately want newer versions, review the diff, and commit it.
#
# One universal lock covers every Python version from 3.8 up. It keeps environment
# markers (python_full_version, and pyobjc's platform_release gates on the Darwin
# version) for uv to evaluate on the Mac at install time. Resolving for a fixed
# target triple instead drops every platform_release-gated framework, because uv
# has no Darwin version to compare against when cross-compiling.
# Each package's hashes cover all of its files, so the lock works on Apple Silicon
# and Intel.
#
# Usage: tools/update_python_lock.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
out_dir=sources/API/PythonLocks
# Inside the repo, because a Dockerized uv can only see the project directory.
# A fixed path keeps the lock files' "# via -r" comments stable across runs.
work=tmp/python-lock
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

printf 'iterm2\ncertifi\npyobjc\n' > "$work/requirements.in"
mkdir -p "$out_dir"

rm -f "$out_dir"/*.lock
uv pip compile "$work/requirements.in" \
    --universal \
    --python-version 3.8 \
    --only-binary :all: \
    --generate-hashes \
    --no-header \
    --quiet \
    -o "$out_dir/python.lock"
echo "Wrote $out_dir/python.lock with $(grep -cE '^[A-Za-z0-9].*==' "$out_dir/python.lock") pinned requirements"
