#!/usr/bin/env bash
# Colorful Lode → local Git → signed Lun cells → caller-owned DAG steps.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${LODE_DAG_PYTHON:-}" ]]; then
  python="$LODE_DAG_PYTHON"
else
  python=
  for candidate in python3 python3.13 python3.12; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))' 2>/dev/null; then
      python="$candidate"
      break
    fi
  done
fi
if [[ -z "$python" ]] || ! "$python" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))' 2>/dev/null; then
  printf 'Error: Python 3.12+ is required; set LODE_DAG_PYTHON to its executable.\n' >&2
  exit 2
fi
exec "$python" "$here/_demo.py" "$@"
