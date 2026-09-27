#!/usr/bin/env bash
# End-to-end test of lun, locally: fetch (git, file://), manifest check,
# signature and graph checks, compilation, function and graph services.
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
request() { # COMMIT BRANCH FUNCTIONS GRAPHS
  jq -n --arg url "file://$repo" --arg commit "$1" --arg branch "$2" \
    --argjson functions "$3" --argjson graphs "$4" \
    '{source: {url: $url, branch: $branch, commit: $commit, path: "lean"},
      functions: $functions, graphs: $graphs}'
}

functions='[
  {"name": "math.double", "module": "Fixture.Math", "function": "Fixture.double", "signature": "Nat → Eff [] Nat"},
  {"name": "add", "module": "Fixture.Math", "function": "Fixture.add", "signature": "Nat → Nat → Eff [Trace.Trace] Nat"},
  {"name": "seed", "module": "Fixture.Math", "function": "Fixture.seed", "signature": "Unit → Eff [] Nat"},
  {"name": "norm1", "module": "Fixture.Math", "function": "Fixture.norm1", "signature": "Fixture.Point → Eff [Error.Error String] Nat"},
  {"name": "succ", "module": "Fixture.Math", "function": "Fixture.succ", "signature": "Nat → Eff [] Nat"},
  {"name": "render", "module": "Fixture.Math", "function": "Fixture.render", "signature": "Nat → Eff [] String"}
]'
graphs='[
  {"name": "main", "program": "do\n  let x ← input \"x\" Nat\n  let s ← seed\n  let d ← math.double x\n  let d2 ← math.double d\n  let a ← add d2 s\n  let n ← succ a\n  render n"},
  {"name": "points", "program": "do\n  let p ← input \"p\" Fixture.Point\n  let y ← input \"y\" Nat\n  let n ← norm1 p\n  let a ← add n y\n  let m ← math.double y\n  render a"}
]'

# ── Refusals before any build ───────────────────────────────────────────────
r="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/v0/builds" -d '{}')"
[ "$r" = 401 ] || fail "no token: $r"; pass "a request without the token is refused"
expect "a malformed request is refused" 400 '.error | test("source")' "$(api POST /v0/builds '{"functions": []}')"
expect "an abbreviated commit is refused" 400 '.error | test("commit")' \
  "$(api POST /v0/builds "$(request "${commit:0:12}" main "$functions" "$graphs")")"

# ── A good build ────────────────────────────────────────────────────────────
r="$(api POST /v0/builds "$(request "$commit" main "$functions" "$graphs")")"
expect "submitting a build" 202 '.state == "queued"' "$r"
id="$(jq -r .id <<<"${r#* }")"
r="$(wait_build "$id")"
expect "the build is ready" 200 '.state == "ready" and (.functions | length) == 6 and (.graphs[0].sinks == [6])' "$r"
expect "resubmitting returns the ready build" 200 ".id == \"$id\" and .state == \"ready\"" \
  "$(api POST /v0/builds "$(request "$commit" main "$functions" "$graphs")")"

expect "a function, one input" 200 '.output == 42' "$(api POST "/v0/builds/$id/functions/math.double" '{"input": 21}')"
expect "a function, several inputs, one bad" 200 '.outputs[0].output == 2 and (.outputs[1].error | test("decode")) and .outputs[2].output == 6' \
  "$(api POST "/v0/builds/$id/functions/math.double" '{"inputs": [1, "x", 3]}')"
expect "a function of two arguments, with its trace" 200 '.output == 5 and (.log | test("adding 2 and 3"))' \
  "$(api POST "/v0/builds/$id/functions/add" '{"input": [2, 3]}')"
expect "a Unit function needs no input" 200 '.output == 10' "$(api POST "/v0/builds/$id/functions/seed" '{}')"
expect "a structured argument, and an effect error" 200 '.outputs[0].output == 7 and .outputs[1].error == "x is zero"' \
  "$(api POST "/v0/builds/$id/functions/norm1" '{"inputs": [{"x": 3, "y": -4}, {"x": 0, "y": 1}]}')"
expect "an unknown function" 404 '.error | test("no function")' "$(api POST "/v0/builds/$id/functions/nope" '{}')"
expect "the graph, every node" 200 '[.nodes[] | .output] == [5, 10, 10, 20, 30, 31, "#31"]' \
  "$(api POST "/v0/builds/$id/graphs/main" '{"inputs": {"x": 5}}')"
expect "the graph, a missing input only skips what depends on it" 200 \
  '.nodes[0].error != null and .nodes[1].output == 10 and .nodes[2].skipped == 0 and .nodes[6].skipped == 5' \
  "$(api POST "/v0/builds/$id/graphs/main" '{"inputs": {}}')"

# ── Sessions: a live graph, updated input by input ────────────────────────────
r="$(api POST "/v0/builds/$id/graphs/main/sessions" '{"inputs": {"x": 5}}')"
expect "a session starts with its inputs" 201 '(.session | length) == 64 and [.nodes[] | .output] == [5, 10, 10, 20, 30, 31, "#31"] and (has("state") | not)' "$r"
sid="$(jq -r .session <<<"${r#* }")"
expect "an update returns only the nodes that changed" 200 \
  '[.changed[] | .id] == [0, 2, 3, 4, 5, 6] and [.changed[] | .output] == [6, 12, 24, 34, 35, "#35"] and .updates == 1' \
  "$(api POST "/v0/sessions/$sid" '{"inputs": {"x": 6}}')"
expect "an input set to its value changes nothing (and runs nothing)" 200 '.changed == [] and ((.log // "") | test("adding") | not)' \
  "$(api POST "/v0/sessions/$sid" '{"inputs": {"x": 6}}')"
expect "a session keeps its values" 200 '.updates == 2 and .nodes[6].output == "#35"' "$(api GET "/v0/sessions/$sid")"
expect "an unknown input is refused, and the session is untouched" 400 '.error | test("no input named .z.")' \
  "$(api POST "/v0/sessions/$sid" '{"inputs": {"z": 1}}')"
expect "a session ends" 200 '.ended' "$(api DELETE "/v0/sessions/$sid")"
expect "an ended session is gone" 404 '.error | test("no such session")' "$(api GET "/v0/sessions/$sid")"

r="$(api POST "/v0/builds/$id/graphs/points/sessions" '{"inputs": {"y": 2}}')"
expect "inputs not given have no outcome yet" 201 '.nodes[0] | has("output") or has("error") | not' "$r"
sid="$(jq -r .session <<<"${r#* }")"
expect "a function's error is an outcome that changes" 200 \
  '[.changed[] | .id] == [0, 2, 3, 5] and .changed[1].error == "x is zero" and .changed[2].skipped == 2' \
  "$(api POST "/v0/sessions/$sid" '{"inputs": {"p": {"x": 0, "y": 1}}}')"
expect "a failed node recovers when its input changes" 200 \
  '[.changed[] | .id] == [0, 2, 3, 5] and .changed[2].output == 3 and .changed[3].output == "#3"' \
  "$(api POST "/v0/sessions/$sid" '{"inputs": {"p": {"x": 1, "y": 0}}}')"
expect "several inputs at once" 200 '[.changed[] | .id] == [0, 1, 2, 3, 4, 5] and .changed[4].output == 20' \
  "$(api POST "/v0/sessions/$sid" '{"inputs": {"p": {"x": 2, "y": 2}, "y": 10}}')"
expect "a session of an unknown graph" 404 '.error | test("no graph")' \
  "$(api POST "/v0/builds/$id/graphs/nope/sessions" '{}')"

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
expect_failed "a commit that is not on the branch" "$(request "$unrelated" main "$functions" '[]')" \
  '.state == "failed" and (.error | test("not on branch"))'
expect_failed "a signature mismatch is attributed to its function" \
  "$(request "$commit" main '[{"name": "bad", "module": "Fixture.Math", "function": "Fixture.double", "signature": "Int → Eff [] Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0] | .scope == "function" and .name == "bad" and (.message | test("mismatch")))'
expect_failed "ambient IO is not a function" \
  "$(request "$commit" main '[{"name": "io", "module": "Fixture.Rejected", "function": "Fixture.Rejected.ambient", "signature": "Nat → IO Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0].message | test("must return `Eff"))'
expect_failed "a project's own effect is not allowed" \
  "$(request "$commit" main '[{"name": "s", "module": "Fixture.Rejected", "function": "Fixture.Rejected.sneaky", "signature": "Nat → Eff [Fixture.Rejected.Anything] Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0].message | test("not allowed"))'
expect_failed "sorry is refused" \
  "$(request "$commit" main '[{"name": "u", "module": "Fixture.Rejected", "function": "Fixture.Rejected.unfinished", "signature": "Nat → Eff [] Nat"}]' '[]')" \
  '.state == "failed" and (.diagnostics[0].message | test("sorry"))'
expect_failed "an ill-typed graph is attributed to its line in the program" \
  "$(request "$commit" main "$functions" '[{"name": "bad", "program": "do\n  let p ← input \"p\" Fixture.Point\n  math.double p"}]')" \
  '.state == "failed" and (.diagnostics[0] | .scope == "graph" and .name == "bad" and .line == 3)'
expect_failed "a graph may not forge a node" \
  "$(request "$commit" main "$functions" '[{"name": "forge", "program": "do\n  let x ← input \"x\" Nat\n  Control.Reactive.Reactive.addNode (.combineLatest ⟨0⟩) [x.id] Nat"}]')" \
  '.state == "failed" and (.diagnostics[0].message | test("addNode"))'
expect_failed "a graph may apply only the declared functions" \
  "$(request "$commit" main "$functions" '[{"name": "lambda", "program": "do\n  let x ← input \"x\" Nat\n  combineLatest (fun (a : Nat) => a + 1) x"}]')" \
  '.state == "failed" and (.diagnostics[0] | .scope == "graph" and .name == "lambda" and (.message | test("not a declared function")))'
expect_failed "a graph program is exactly one term" \
  "$(request "$commit" main "$functions" '[{"name": "inject", "program": "pure ())\n#eval IO.println \"hi\"\n(pure ()"}]')" \
  '.state == "failed" and (.diagnostics[0].message | test("cannot parse"))'

echo "all end-to-end checks passed ($work)"
