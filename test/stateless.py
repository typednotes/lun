"""Compiled graph execution: caller-owned SQLite state and deterministic wake-ups."""
import copy
import json
import sqlite3
import sys
import urllib.error
import urllib.request

base, build, database = sys.argv[1:]
checks = 0
authority = {"policy": {"effects": ["Trace", "Error"], "domains": []},
             "binding": {"org_id": "org-1", "user_id": "user-1"}}


def call(graph, state=None, inputs=None, now: object = 1000, status=200, **fields):
    global checks
    body = dict(authority, state=state, inputs=inputs or {}, now=now, **fields)
    request = urllib.request.Request(base + f"/v0/builds/{build}/graphs/{graph}",
                                    json.dumps(body).encode(), method="POST",
                                    headers={"Authorization": "Bearer secret", "Content-Type": "application/json"})
    try:
        response = urllib.request.urlopen(request, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        result = json.load(response)
        assert response.code == status, result
    checks += 1
    return result


def outputs(reply, name):
    return [node["output"] for node in reply["changed"] if node.get("function") == name and "output" in node]


first = call("main", inputs={"x": 5})
second = call("main", first["state"], {"x": 6}, now=2000)
assert [node["id"] for node in second["changed"]] == [0, 2, 3, 4, 5, 6]
assert second["nodes"][-1]["output"] == "#35" and second["nextCallAt"] is None
assert all(node["timestamp"] == 2000 for node in second["changed"])
assert call("main", second["state"], {"x": 6}, now=2000)["changed"] == []
assert call("main", inputs={"x": 9})["nodes"][-1]["output"] == "#47"
assert call("main", first["state"], now=2000)["nodes"][-1]["output"] == "#31"
assert "no input" in call("main", first["state"], {"z": 1}, status=400)["error"]
assert "timestamp" in call("main", second["state"], now=1999, status=400)["error"]
call("main", first["state"], now="bad", status=400)
call("diamond", first["state"], status=400)
call("main", {}, status=400)

partial = call("points", inputs={"y": 2})
assert "output" not in partial["nodes"][0] and "error" not in partial["nodes"][0]
failed = call("points", partial["state"], {"p": {"x": 0, "y": 1}})
assert failed["nodes"][2]["error"] == "x is zero" and failed["nodes"][3]["skipped"] == 2
fixed = call("points", failed["state"], {"p": {"x": 1, "y": 0}})
assert fixed["nodes"][-1]["output"] == "#3"
multi = call("points", fixed["state"], {"p": {"x": 2, "y": 2}, "y": 10})
assert outputs(multi, "render") == ["#6", "#14"] and multi["nodes"][4]["output"] == 20

timed = call("timed", inputs={"x": 10})
assert outputs(timed, "delayed") == [10, 11] and outputs(timed, "render") == ["#10", "#11"]
assert timed["nextCallAt"] == 121000
# Persist exactly the returned JSON in the caller's database, close/reopen it,
# and resume via another HTTP connection. No server registration is involved.
with sqlite3.connect(database) as db:
    db.execute("CREATE TABLE executions (id INTEGER PRIMARY KEY, state TEXT, next_call_at INTEGER)")
    db.execute("INSERT INTO executions VALUES (1, ?, ?)", (json.dumps(timed["state"]), timed["nextCallAt"]))
with sqlite3.connect(database) as db:
    serialized, wake_at = db.execute("SELECT state, next_call_at FROM executions WHERE id=1").fetchone()
early = call("timed", json.loads(serialized), now=wake_at - 1)
assert early["changed"] == [] and "producer step" not in early.get("log", "")
due = call("timed", early["state"], now=wake_at)
assert outputs(due, "delayed") == [12] and outputs(due, "render") == ["#12"] and due["nextCallAt"] is None
assert call("timed", due["state"], now=200000)["changed"] == []
late = call("timed", timed["state"], now=500000)
assert outputs(late, "delayed") == [12] and late["changed"][0]["timestamp"] == 500000

restart = call("timed", timed["state"], {"x": 20}, now=2000)
assert outputs(restart, "delayed") == [20, 21] and restart["nextCallAt"] == 122000
assert call("timed", restart["state"], now=121000)["changed"] == []
assert outputs(call("timed", restart["state"], now=122000), "delayed") == [22]

silent = call("silent", inputs={"x": 7})
assert "output" not in silent["nodes"][1] and "output" not in silent["nodes"][2]
assert silent["nextCallAt"] == 121000
assert outputs(call("silent", silent["state"], now=121000), "render") == ["#7"]
tick = call("tick")
assert outputs(tick, "ticker") == [0] and tick["nextCallAt"] == 61000
tick2 = call("tick", tick["state"], now=61000)
assert outputs(tick2, "ticker") == [1] and tick2["nextCallAt"] == 121000
assert outputs(call("tick", tick2["state"], now=121000), "ticker") == [2]
both = call("twoProducers", inputs={"x": 5})
assert both["nextCallAt"] == 61000
both2 = call("twoProducers", both["state"], now=61000)
assert outputs(both2, "ticker") == [1] and outputs(both2, "delayed") == []
assert both2["nextCallAt"] == 121000
diamond = call("producerDiamond", inputs={"x": 10})
assert outputs(diamond, "add") == [31, 34] and outputs(diamond, "render") == ["#31", "#34"]
assert outputs(call("producerDiamond", diamond["state"], now=121000), "render") == ["#37"]
bad_wake = call("badSchedule", inputs={"x": 1})
assert "after now" in bad_wake["nodes"][1]["error"] and bad_wake["nodes"][2]["skipped"] == 1
assert bad_wake["nextCallAt"] is None

large = call("bursty", inputs={"x": 600})
assert large["nextCallAt"] == 1000 and large["state"]["pending"]
values, rendered = outputs(large, "burst"), outputs(large, "render")
while large["nextCallAt"] is not None:
    large = call("bursty", json.loads(json.dumps(large["state"])))
    values.extend(outputs(large, "burst"))
    rendered.extend(outputs(large, "render"))
assert values == list(range(600)) and rendered == [f"#{n}" for n in range(600)]
assert large["nodes"][-1]["output"] == "#599"
pending = call("bursty", inputs={"x": 600})
cancelled = call("bursty", pending["state"], {"x": 2})
assert outputs(cancelled, "burst") == [0, 1] and cancelled["nextCallAt"] is None

# Malformed state is validated before a producer can execute an effect.
malformed = copy.deepcopy(tick["state"])
malformed["continuations"][1]["value"] = "not a Nat"
call("tick", malformed, now=61000, status=400)
malformed = copy.deepcopy(pending["state"])
malformed["pending"][0][1] = "not a Nat"
call("bursty", malformed, status=400)
malformed = copy.deepcopy(timed["state"])
malformed["outcomes"][0] = {"output": "not a Nat"}
call("timed", malformed, status=400)
malformed = copy.deepcopy(timed["state"])
malformed["contract"] = "old-runtime"
call("timed", malformed, status=400)

# Permissions are supplied afresh; a prior successful call never grants the
# resumed producer authority. State fields cannot turn Trace on.
denied = call("timed", timed["state"], now=121000, policy={"effects": [], "domains": []})
assert "permission denied: Trace" in denied["nodes"][1]["error"] and denied["nextCallAt"] is None
injected = copy.deepcopy(timed["state"])
injected["policy"] = authority["policy"]
injected["_runtime"] = {"SECRETS_PASSWORD": "fake"}
denied_injected = call("timed", injected, now=121000, policy={"effects": [], "domains": []})
assert "permission denied" in denied_injected["nodes"][1]["error"]
print(f"ok - {checks} compiled stateless execution cases, SQLite persistence, bursts and minute-separated results")
