#!/usr/bin/env bash
# Run lun's example locally: start a lun, have it build the pricing project
# (`Examples/pricing`), register its `invoice` graph as a session and update
# its inputs (`Examples/Client.lean`).
#
#   Examples/run.sh [LINEN_DIR] [-- CLIENT OPTIONS…]
#
# The project pins linen v1.9.2 from GitHub, so the first build clones and
# compiles linen (minutes). With LINEN_DIR (a linen checkout, >= 1.3.0) the
# project takes linen from there instead and reuses its build. Either way lun
# runs in local mode (LUN_ALLOW_LOCAL=1), which admits the file:// repository
# the project is copied into (and a path dependency). Client options, e.g.
# `--dot invoice.dot`, go after `--`.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
linen=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then linen="$(cd "$1" && pwd)"; shift; fi
[ "${1:-}" = "--" ] && shift
work="$(mktemp -d /tmp/lun-example.XXXXXX)"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

# The project, as a git repository.
repo="$work/repo"
mkdir -p "$repo/pricing"
(cd "$here/pricing" && tar --exclude .lake -cf - .) | (cd "$repo/pricing" && tar -xf -)
if [ -n "$linen" ]; then
  printf '%s\n' 'name = "pricing"' 'defaultTargets = ["Pricing"]' \
    '[[require]]' 'name = "linen"' "path = \"$linen\"" \
    '[[lean_lib]]' 'name = "Pricing"' > "$repo/pricing/lakefile.toml"
  (cd "$repo/pricing" && lake update >/dev/null 2>&1)   # a manifest pointing at $linen
fi
git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" -c user.email=example@lun -c user.name=example -c commit.gpgsign=false commit -q -m pricing
commit="$(git -C "$repo" rev-parse HEAD)"

# lun, and the client.
(cd "$root" && lake build lun lun-example >/dev/null)
LUN_WORKDIR="$work/lun" LUN_PORT="$port" LUN_ALLOW_LOCAL=1 LUN_TOKEN=example \
  "$root/.lake/build/bin/lun" >"$work/lun.log" 2>&1 &
lun_pid=$!
trap 'kill $lun_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/_health" >/dev/null && break; sleep 0.2; done

"$root/.lake/build/bin/lun-example" --lun "http://127.0.0.1:$port" --token example \
  --repo "file://$repo" --commit "$commit" --path pricing "$@"
echo "(lun's log and builds: $work)"
