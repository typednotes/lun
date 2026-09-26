#!/usr/bin/env bash
# End-to-end test of lun, locally: fetch (git, file://), manifest check,
# signature and DAG checks, compilation, cell and DAG services.
#
#   test/e2e.sh [LINEN_DIR]
#
# LINEN_DIR is a linen checkout carrying `Control.Reactive` and
# `Control.Monad.Effect.Handler` (linen >= 1.3.0), default ../linen. The test
# runs lun in local mode (LUN_ALLOW_LOCAL=1), which is what admits the
# file:// repository and the fixture's path dependency on that checkout.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
linen="$(cd "${1:-$root/../linen}" && pwd)"
port="${LUN_E2E_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
work="$(mktemp -d /tmp/lun-e2e.XXXXXX)"
base="http://127.0.0.1:$port"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# ── The fixture, as a git repository ────────────────────────────────────────
repo="$work/repo"
mkdir -p "$repo/lean"
(cd "$here/fixture" && tar --exclude .lake -cf - .) | (cd "$repo/lean" && tar -xf -)
sed -i.bak "s|path = \"../../../linen\"|path = \"$linen\"|" "$repo/lean/lakefile.toml"
rm "$repo/lean/lakefile.toml.bak"
(cd "$repo/lean" && lake update >/dev/null 2>&1)   # a manifest pointing at $linen
git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" -c user.email=e2e@lun -c user.name=e2e -c commit.gpgsign=false commit -q -m fixture
commit="$(git -C "$repo" rev-parse HEAD)"
# A later commit, so "commit on branch" is tested with a non-head commit too.
echo "-- later" >> "$repo/lean/Fixture.lean"
git -C "$repo" -c user.email=e2e@lun -c user.name=e2e -c commit.gpgsign=false commit -q -am later
git -C "$repo" branch -q other "$commit"~0
git -C "$repo" checkout -q -b orphan-branch
git -C "$repo" reset -q --hard "$commit"
echo "-- unrelated" >> "$repo/lean/Fixture.lean"
git -C "$repo" -c user.email=e2e@lun -c user.name=e2e -c commit.gpgsign=false commit -q -am unrelated
unrelated="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q main

# ── lun ────────────────────────────────────────────────────────────────────
(cd "$root" && lake build lun >/dev/null)
LUN_WORKDIR="$work/lun" LUN_PORT="$port" LUN_ALLOW_LOCAL=1 LUN_TOKEN=secret \
  LUN_ID_SALT=e2e "$root/.lake/build/bin/lun" >"$work/lun.log" 2>&1 &
lun_pid=$!
trap 'kill $lun_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "$base/_health" >/dev/null && break; sleep 0.2; done
curl -sf "$base/_health" >/dev/null || fail "lun did not start: $(cat "$work/lun.log")"
pass "health"

api() { # METHOD PATH [BODY] -> prints "STATUS BODY"
  local out
  out="$(curl -s -o /dev/stdout -w '\n%{http_code}' -X "$1" -H 'Authorization: Bearer secret' \
    -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$base$2")"
  echo "$(tail -n1 <<<"$out") $(sed '$d' <<<"$out")"
}
expect() { # DESCRIPTION EXPECTED-STATUS JQ-FILTER "STATUS BODY"
  local status="${4%% *}" body="${4#* }"
  [ "$status" = "$2" ] || fail "$1: status $status, expected $2: $body"
  jq -e "$3" >/dev/null <<<"$body" || fail "$1: $3 does not hold for $body"
  pass "$1"
}
wait_build() { # ID -> final status body
  local r
  for _ in $(seq 900); do
    r="$(api GET "/v0/builds/$1")"
    case "$(jq -r .state <<<"${r#* }")" in ready|failed) echo "$r"; return;; esac
    sleep 1
  done
  fail "build $1 did not finish"
}
request() { # COMMIT BRANCH CELLS DAGS
  jq -n --arg url "file://$repo" --arg commit "$1" --arg branch "$2" \
    --argjson cells "$3" --argjson dags "$4" \
    '{source: {url: $url, branch: $branch, commit: $commit, path: "lean"},
      cells: $cells, dags: $dags}'
}

cells='[
  {"name": "math.double", "module": "Fixture.Math", "function": "Fixture.double", "signature": "Nat → Eff [] Nat"},
  {"name": "add", "module": "Fixture.Math", "function": "Fixture.add", "signature": "Nat → Nat → Eff [Trace.Trace] Nat"},
  {"name": "seed", "module": "Fixture.Math", "function": "Fixture.seed", "signature": "Unit → Eff [] Nat"},
  {"name": "norm1", "module": "Fixture.Math", "function": "Fixture.norm1", "signature": "Fixture.Point → Eff [Error.Error String] Nat"},
  {"name": "succ", "module": "Fixture.Math", "function": "Fixture.succ", "signature": "Nat → Eff [] Nat"},
  {"name": "render", "module": "Fixture.Math", "function": "Fixture.render", "signature": "Nat → Eff [] String"}
]'
dags='[
  {"name": "main", "program": "do\n  let x ← input \"x\" Nat\n  let s ← seed\n  let d ← math.double x\n  let d2 ← math.double d\n  let a ← add d2 s\n  let n ← succ a\n  render n"}
]'

# ── Refusals before any build ───────────────────────────────────────────────
r="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/v0/builds" -d '{}')"
[ "$r" = 401 ] || fail "no token: $r"; pass "a request without the token is refused"
expect "a malformed request is refused" 400 '.error | test("source")' "$(api POST /v0/builds '{"cells": []}')"
expect "an abbreviated commit is refused" 400 '.error | test("commit")' \
  "$(api POST /v0/builds "$(request "${commit:0:12}" main "$cells" "$dags")")"

# ── A good build ────────────────────────────────────────────────────────────
r="$(api POST /v0/builds "$(request "$commit" main "$cells" "$dags")")"
expect "submitting a build" 202 '.state == "queued"' "$r"
id="$(jq -r .id <<<"${r#* }")"
r="$(wait_build "$id")"
expect "the build is ready" 200 '.state == "ready" and (.cells | length) == 6 and (.dags[0].sinks == [6])' "$r"
expect "resubmitting returns the ready build" 200 ".id == \"$id\" and .state == \"ready\"" \
  "$(api POST /v0/builds "$(request "$commit" main "$cells" "$dags")")"

expect "a cell, one input" 200 '.output == 42' "$(api POST "/v0/builds/$id/cells/math.double" '{"input": 21}')"
expect "a cell, several inputs, one bad" 200 '.outputs[0].output == 2 and (.outputs[1].error | test("decode")) and .outputs[2].output == 6' \
  "$(api POST "/v0/builds/$id/cells/math.double" '{"inputs": [1, "x", 3]}')"
expect "a cell of two arguments, with its trace" 200 '.output == 5 and (.log | test("adding 2 and 3"))' \
  "$(api POST "/v0/builds/$id/cells/add" '{"input": [2, 3]}')"
expect "a Unit cell needs no input" 200 '.output == 10' "$(api POST "/v0/builds/$id/cells/seed" '{}')"
expect "a structured argument, and an effect error" 200 '.outputs[0].output == 7 and .outputs[1].error == "x is zero"' \
  "$(api POST "/v0/builds/$id/cells/norm1" '{"inputs": [{"x": 3, "y": -4}, {"x": 0, "y": 1}]}')"
expect "an unknown cell" 404 '.error | test("no cell")' "$(api POST "/v0/builds/$id/cells/nope" '{}')"
expect "the DAG, every node" 200 '[.nodes[] | .output] == [5, 10, 10, 20, 30, 31, "#31"]' \
  "$(api POST "/v0/builds/$id/dags/main" '{"inputs": {"x": 5}}')"
expect "the DAG, a missing input only skips what depends on it" 200 \
  '.nodes[0].error != null and .nodes[1].output == 10 and .nodes[2].skipped == 0 and .nodes[6].skipped == 5' \
  "$(api POST "/v0/builds/$id/dags/main" '{"inputs": {}}')"
r="$(curl -s -H 'Authorization: Bearer secret' "$base/v0/builds/$id/log")"
grep -q "fetched file://" <<<"$r" || fail "the log: $r"; pass "the build log"

# ── Builds that must fail, and say why ──────────────────────────────────────
expect_failed() { # DESCRIPTION REQUEST JQ-FILTER
  local r id
  r="$(api POST /v0/builds "$2")"
  id="$(jq -r .id <<<"${r#* }")"
  [ "$id" != null ] || fail "$1: not accepted: $r"
  expect "$1" 200 "$3" "$(wait_build "$id")"
}
expect_failed "a commit that is not on the branch" "$(request "$unrelated" main "$cells" '[]')" \
  '.state == "failed" and (.error | test("not on branch"))'
expect_failed "a signature mismatch is attributed to its cell" \
  "$(request "$commit" main '[{"name": "bad", "module": "Fixture.Math", "function": "Fixture.double", "signature": "Int → Eff [] Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0] | .scope == "cell" and .name == "bad" and (.message | test("mismatch")))'
expect_failed "ambient IO is not a cell" \
  "$(request "$commit" main '[{"name": "io", "module": "Fixture.Rejected", "function": "Fixture.Rejected.ambient", "signature": "Nat → IO Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0].message | test("must return `Eff"))'
expect_failed "a project's own effect is not allowed" \
  "$(request "$commit" main '[{"name": "s", "module": "Fixture.Rejected", "function": "Fixture.Rejected.sneaky", "signature": "Nat → Eff [Fixture.Rejected.Anything] Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0].message | test("not allowed"))'
expect_failed "sorry is refused" \
  "$(request "$commit" main '[{"name": "u", "module": "Fixture.Rejected", "function": "Fixture.Rejected.unfinished", "signature": "Nat → Eff [] Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0].message | test("sorry"))'
expect_failed "an ill-typed DAG is attributed to its line in the program" \
  "$(request "$commit" main "$cells" '[{"name": "bad", "program": "do\n  let p ← input \"p\" Fixture.Point\n  math.double p"}]')" \
  '.state == "failed" and (.diagnostics[0] | .scope == "dag" and .name == "bad" and .line == 3)'
expect_failed "a DAG may not forge a cell" \
  "$(request "$commit" main "$cells" '[{"name": "forge", "program": "do\n  let x ← input \"x\" Nat\n  (⟨\"math.double\"⟩ : Control.Reactive.Cell [Nat] Nat) x"}]')" \
  '.state == "failed" and (.diagnostics[0].message | test("Cell.mk"))'
expect_failed "a DAG program is exactly one term" \
  "$(request "$commit" main "$cells" '[{"name": "inject", "program": "pure ())\n#eval IO.println \"hi\"\n(pure ()"}]')" \
  '.state == "failed" and (.diagnostics[0].message | test("cannot parse"))'

echo "all end-to-end checks passed ($work)"
