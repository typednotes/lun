#!/usr/bin/env python3
"""Compiled lun drivers + actual liaison/HMAC/ledger + private SCRAM Postgres.

The vault/provider HTTP fixtures are disposable protocol peers, not substitutes
for the runtime/broker. No paid endpoint or personal credential is used.
"""
import argparse
import copy
import hashlib
import hmac
import http.server
import importlib.util
import json
import os
from pathlib import Path
import secrets
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("broker_checks", ROOT.parent / "liaison/LiaisonTest/integration/connectors.py")
broker_checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker_checks)
port, run, lp = broker_checks.port, broker_checks.run, broker_checks.lp


def exchange(url, value=None):
    data = None if value is None else json.dumps(value).encode()
    req = urllib.request.Request(url, data, {"Content-Type": "application/json", "Authorization": "Bearer fixture-lun"})
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as response:
        return response.code, json.loads(response.read())


class Peer(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, body, content_type="application/json"):
        body = json.dumps(body).encode() if not isinstance(body, bytes) else body
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", content_type)
        self.send_header("ETag", '"fixture"')
        self.end_headers()
        self.wfile.write(body)

    def handle_call(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        state = self.server.state
        state["calls"].append((self.command, self.path, body))
        if state["vault"]:
            assert self.headers["Authorization"] == "Bearer fixture-vault"
            if self.command == "POST" and "/data/graph/" in self.path:
                state["documents"][self.path] = json.loads(body)
                self.reply(200, {})
            elif self.path in state["documents"]:
                self.reply(200, {"data": state["documents"][self.path]})
            elif "/metadata/graph/" in self.path:
                root = self.path.replace("/metadata/", "/data/")
                keys = [p.removeprefix("/v1/secret/data/") for p in state["documents"] if p.startswith(root)]
                self.reply(200, {"keys": keys})
            else:
                self.reply(404, {})
            return
        broker_checks.verify_sigv4(self.command, self.path, self.headers, body)
        parsed = urllib.parse.urlsplit(self.path)
        if self.command == "GET" and parsed.query:
            self.reply(200, b"<ListBucketResult><Contents><Key>reports/file</Key><Size>7</Size></Contents></ListBucketResult>", "application/xml")
        elif self.command == "GET":
            self.reply(200, state["object"], "application/octet-stream")
        elif self.command == "PUT":
            state["object"] = body
            self.reply(200, b"")
        elif self.command == "DELETE":
            state["object"] = b""
            self.reply(204, b"")
        else:
            self.reply(400, {})

    do_GET = do_POST = do_PUT = do_DELETE = handle_call


def serve(vault):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Peer)
    server.state = {"vault": vault, "calls": [], "documents": {}, "object": b"fixture"}
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def wait_health(base, process, logfile):
    for _ in range(200):
        try:
            with urllib.request.urlopen(base + "/_health", timeout=1):
                return
        except (OSError, urllib.error.URLError):
            if process.poll() is not None:
                raise AssertionError(logfile.read_text())
            time.sleep(0.05)
    raise AssertionError("service did not become healthy")


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--temp-root", type=Path, required=True)
    args.add_argument("--public-http", action="store_true", help="verify credential-free TLS GET to example.org")
    options = args.parse_args()
    vault, upstream = serve(True), serve(False)
    processes = []
    pg_started = False
    checks = 0
    with tempfile.TemporaryDirectory(prefix="lun-runtime-", dir=options.temp_root) as temp:
        directory = Path(temp)
        pg = directory / "postgres"
        pg_port, broker_port, lun_port = port(), port(), port()
        org, user, graph, run_id = str(uuid.uuid4()), "fixture-user", "fixture-graph", str(uuid.uuid4())
        key, password = secrets.token_bytes(32), secrets.token_hex(24)
        try:
            run("initdb", "-D", str(pg), "-A", "trust", "--no-locale", "-U", "fixture")
            hba = pg / "pg_hba.conf"
            hba.write_text("host all compute_owner 127.0.0.1/32 scram-sha-256\n" + hba.read_text())
            run("pg_ctl", "-D", str(pg), "-l", str(directory / "postgres.log"), "-o", f"-h 127.0.0.1 -p {pg_port} -c unix_socket_directories=", "-w", "start")
            pg_started = True
            db = f"postgresql://fixture@127.0.0.1:{pg_port}/postgres"
            def sql(statement):
                return run("psql", db, "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", statement).strip()
            sql(f"set password_encryption='scram-sha-256'; create role compute_owner login password '{password}'; create schema authorization compute_owner; create schema other_user; create table compute_owner.notes(value text); alter table compute_owner.notes owner to compute_owner; create table other_user.notes(value text); insert into other_user.notes values ('private'); revoke all on schema public from public;")
            sql("create table credit_holds(id uuid primary key default gen_random_uuid(),org_id uuid,run_id uuid,amount bigint,state text,expires_at timestamptz); create table credit_ledger(id uuid default gen_random_uuid(),org_id uuid,run_id uuid,delta bigint,reason text);" + (ROOT.parent / "liaison/sql/0001_audit_log.sql").read_text())
            sql(f"insert into credit_ledger(org_id,run_id,delta,reason) values ('{org}','{run_id}',10000,'fixture')")
            assert sql("select rolpassword like 'SCRAM-SHA-256%' from pg_authid where rolname='compute_owner'") == "t"
            env = {k: v for k, v in os.environ.items() if not k.startswith(("SECRETS_", "LUN_", "LIAISON_"))}
            env.update(SECRETS_HOST="127.0.0.1", SECRETS_PORT=str(vault.server_port), SECRETS_INSECURE="1", SECRETS_TOKEN="fixture-vault", LEAN_NUM_THREADS="2")
            for binary, settings, name in (
                (ROOT.parent / "liaison/.lake/build/bin/liaison", dict(LIAISON_ROOT_KEY=key.hex(), DATABASE_URL=db, LIAISON_PORT=str(broker_port)), "broker"),
                (ROOT / ".lake/build/bin/lun", dict(LUN_PORT=str(lun_port), LUN_TOKEN="fixture-lun", LUN_WORKDIR=str(directory / "lun"), LUN_ALLOW_LOCAL="1", LUN_BUILD_TIMEOUT="240", LUN_LIAISON_SDK_PATH=str(ROOT.parent / "liaison"), LUN_LIAISON_URL=f"http://127.0.0.1:{broker_port}", LUN_TEMP_ROOT=str(directory / "temporary")), "lun")):
                logfile = directory / f"{name}.log"
                log = logfile.open("w")
                proc = subprocess.Popen([str(binary)], env=dict(env, **settings), stdout=log, stderr=log)
                processes.append((proc, log))
                wait_health(f"http://127.0.0.1:{settings.get('LUN_PORT', broker_port)}", proc, logfile)
            base = f"http://127.0.0.1:{lun_port}"
            repo = directory / "repo"
            repo.mkdir()
            (repo / "lean-toolchain").write_text((ROOT / "lean-toolchain").read_text())
            (repo / "lakefile.toml").write_text(f'name="runtime_fixture"\n[[require]]\nname="linen"\npath="{ROOT.parent / "linen"}"\n[[lean_lib]]\nname="RuntimeFixture"\n')
            (repo / "RuntimeFixture.lean").write_text((ROOT / "test/runtime_fixture.lean").read_text().replace("TEST_POSTGRES_PORT", str(pg_port)))
            run("lake", "update", cwd=repo, env=env)
            run("git", "init", "-q", "-b", "main", cwd=repo)
            run("git", "add", "-A", cwd=repo)
            run("git", "-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture", cwd=repo)
            commit = run("git", "rev-parse", "HEAD", cwd=repo).strip()
            functions = []
            signatures = {}
            for names, effect, result in ((["rows", "insert", "update", "delete", "foreign", "truncated"], "PostgreSQL.PostgreSQL RuntimeFixture.compute", "Nat"),
                (["readSecret", "escapeSecret"], "SecretStore.SecretStore RuntimeFixture.secrets", "String"),
                (["putSecret", "describeSecret"], "SecretStore.SecretStore RuntimeFixture.secrets", "Bool"),
                (["listSecrets"], "SecretStore.SecretStore RuntimeFixture.secrets", "Nat"),
                (["getObject"], "ObjectStore.ObjectStore RuntimeFixture.objects", "String"),
                (["putObject", "headObject", "deleteObject"], "ObjectStore.ObjectStore RuntimeFixture.objects", "Bool"),
                (["listObjects"], "ObjectStore.ObjectStore RuntimeFixture.objects", "Nat"),
                (["relay", "relayAt", "overriddenPayload"], "Connector.Connector RuntimeFixture.connector", "Lean.Json"),
                (["fetch", "privateFetch", "encodedFetch"], "HTTP.HTTP HTTP.readOnlyWeb", "Nat"), (["traced"], "Trace.Trace", "Nat")):
                for name in names:
                    argument = "String → " if name in ("insert", "update", "putSecret", "putObject") else "Nat → " if name == "traced" else ""
                    if name == "relayAt":
                        argument = "List String → "
                    signature = f"{argument}Eff [Control.Monad.Effect.{effect}] {result}"
                    if name in ("fetch", "privateFetch", "encodedFetch"):
                        signature = "Eff [Control.Monad.Effect.HTTP.HTTP Control.Monad.Effect.HTTP.readOnlyWeb] Nat"
                    functions.append(dict(name=name, module="RuntimeFixture", function=f"RuntimeFixture.{name}", signature=signature))
                    signatures[name] = signature
            request = dict(source=dict(url=f"file://{repo}", branch="main", commit=commit), functions=functions,
                graphs=[dict(name="typed", program='do\n let x ← input "x" Nat\n traced x', inputTypes={"x": "Nat"}, dependencies={"traced": ["x"]}),
                    dict(name="connected", program='do\n let s ← input "selector" (List String)\n relayAt s', inputTypes={"selector": "List String"}, dependencies={"relayAt": ["selector"]})])
            status, submitted = exchange(base + "/v0/builds", request)
            assert status == 202, submitted
            build = submitted["id"]
            for _ in range(1500):
                _, description = exchange(base + f"/v0/builds/{build}")
                if description["state"] in ("ready", "failed"):
                    break
                time.sleep(0.2)
            assert description["state"] == "ready", (description, (directory / f"lun/builds/{build}/build.log").read_text())
            def binding():
                # Exact current app shape: schema is resolved from the bound
                # vault credential; it is not selected by execution metadata.
                return dict(org_id=org, user_id=user, graph_id=graph)
            def capability(provider, connection, operations, root):
                return dict(provider=provider, connection=connection, scopes=[dict(operation=op, root=root, descendants=True) for op in operations], maxRequestBytes=1048576, maxResponseBytes=16777216)
            def grant(provider, connection, operations, root):
                cap = capability(provider, connection, operations, root)
                tokens = []
                for operation in operations:
                    ident, expiry = str(uuid.uuid4()), int(time.time()) + 300
                    caves = [(dict(kind="expiresAt", value=str(expiry)), b"\0" + struct.pack(">Q", expiry)),
                        (dict(kind="capability", provider=provider, action=operation), b"\1" + lp(provider) + lp(operation)),
                        (dict(kind="resource", value=connection), b"\2" + lp(connection)),
                        (dict(kind="budget", value="0"), b"\3" + struct.pack(">Q", 0)),
                        (dict(kind="runId", value=run_id), b"\4" + lp(run_id))]
                    tag = hmac.new(key, lp(ident) + lp(org), hashlib.sha256).digest()
                    for _, encoded in caves:
                        tag = hmac.new(tag, encoded, hashlib.sha256).digest()
                    warrant = dict(id=ident, orgId=org, tag=tag.hex(), caveats=[c for c, _ in reversed(caves)])
                    tokens.append(dict(operation=operation, warrant=warrant, cost=0))
                    vault.state["documents"][f"/v1/secret/data/connector-authority/{org}/{run_id}/{ident}"] = dict(account=f"{user}/{connection}", cell=copy.deepcopy(cap), warrant=copy.deepcopy(cap))
                permissions = {k: copy.deepcopy(v) for k, v in cap.items() if k not in ("provider", "connection")}
                vault.state["documents"][f"/v1/secret/data/connector-policy/{org}/{provider}/{connection}"] = copy.deepcopy(permissions)
                vault.state["documents"][f"/v1/secret/data/thirdparty/{provider}/{user}/{connection}/permissions"] = copy.deepcopy(permissions)
                return dict(provider=provider, connection=connection, account=f"{user}/{connection}", organization=copy.deepcopy(cap), connectionPermissions=copy.deepcopy(cap), cell=copy.deepcopy(cap), warrants=tokens)
            database_grant = grant("postgres", "compute", ["rows.select", "rows.insert", "rows.update", "rows.delete"], ["compute_owner"])
            secret_grant = grant("vault", graph, ["secrets.read", "secrets.write", "secrets.describe", "secrets.list"], [])
            object_grant = grant("s3", "connection", ["objects.read", "objects.write", "objects.delete", "objects.list"], ["reports"])
            object_grant["bucket"] = "bucket"
            vault.state["documents"][f"/v1/secret/data/compute/{org}/{user}"] = dict(kind="postgres", base_url=f"127.0.0.1:{pg_port}", database="postgres", schema="compute_owner", token=password)
            secret_path = f"/v1/secret/data/graph/{org}/{graph}/token"
            vault.state["documents"][secret_path] = dict(kind="secret", value="graph-value")
            vault.state["documents"][f"/v1/secret/data/thirdparty/s3/{user}/connection"] = dict(kind="s3", base_url=f"http://127.0.0.1:{upstream.server_port}/bucket", region="us-east-1", access_key_id="fixture-key", secret_access_key="fixture-secret")
            def call(name, effect, grant=None, value=None, mutate=None, expected=None, error=None):
                nonlocal checks
                body = dict(policy=dict(effects=[effect], domains=[]), binding=binding(), connectors={name: [] if grant is None else [copy.deepcopy(grant)]})
                if value is not None:
                    body["input"] = value
                if mutate:
                    mutate(body)
                status, reply = exchange(base + f"/v0/builds/{build}/functions/{name}", body)
                assert status == 200, (name, status, reply)
                if error:
                    assert error in reply.get("error", ""), (name, reply)
                else:
                    assert reply.get("output") == expected, (name, reply, expected)
                checks += 1
                return reply
            call("insert", "PostgreSQL", database_grant, "quoted'; drop schema other_user cascade; --", expected=1)
            assert sql("select value from compute_owner.notes") == "quoted'; drop schema other_user cascade; --"
            call("rows", "PostgreSQL", database_grant, expected=1)
            call("update", "PostgreSQL", database_grant, "updated", expected=1)
            call("delete", "PostgreSQL", database_grant, expected=1)
            assert sql("select count(*) from compute_owner.notes") == "0"
            before = len(vault.state["calls"])
            call("foreign", "PostgreSQL", database_grant, error="query leaves")
            assert len(vault.state["calls"]) == before
            call("truncated", "PostgreSQL", database_grant, error="truncated by the server")
            assert len(vault.state["calls"]) == before
            assert sql("select value from other_user.notes") == "private"
            # The actual SCRAM role also refuses the foreign schema independently.
            denied = subprocess.run(["psql", f"postgresql://compute_owner:{password}@127.0.0.1:{pg_port}/postgres", "-X", "-c", "select * from other_user.notes"], capture_output=True, text=True)
            assert denied.returncode != 0 and "permission denied" in denied.stderr
            call("readSecret", "SecretStore", secret_grant, expected="graph-value")
            call("putSecret", "SecretStore", secret_grant, "new-value", expected=True)
            assert vault.state["documents"][secret_path]["value"] == "new-value"
            call("describeSecret", "SecretStore", secret_grant, expected=True)
            call("listSecrets", "SecretStore", secret_grant, expected=1)
            before = len(vault.state["calls"])
            call("escapeSecret", "SecretStore", secret_grant, error="invalid graph-secret")
            assert len(vault.state["calls"]) == before
            call("putObject", "ObjectStore", object_grant, "written", expected=True)
            call("getObject", "ObjectStore", object_grant, expected="written")
            call("headObject", "ObjectStore", object_grant, expected=True)
            call("listObjects", "ObjectStore", object_grant, expected=1)
            call("deleteObject", "ObjectStore", object_grant, expected=True)
            upstream.state["object"] = b'{"native":true}'
            relay_grant = copy.deepcopy(object_grant)
            relay_grant["cell"] = capability("s3", "connection", ["objects.read"], ["reports"])
            call("relay", "Connector", relay_grant, expected=dict(status=200, body=dict(native=True)))
            # Organization-shared providers bind the credential owner separately
            # from the actor. Compute and temporary user bindings stay immutable.
            shared_owner = "connection-owner"
            for suffix in ("", "/permissions"):
                vault.state["documents"][f"/v1/secret/data/thirdparty/s3/{shared_owner}/connection{suffix}"] = copy.deepcopy(
                    vault.state["documents"][f"/v1/secret/data/thirdparty/s3/{user}/connection{suffix}"])
            shared_relay, shared_object = copy.deepcopy(relay_grant), copy.deepcopy(object_grant)
            shared_relay["account"] = shared_object["account"] = f"{shared_owner}/connection"
            for token in object_grant["warrants"]:
                vault.state["documents"][f"/v1/secret/data/connector-authority/{org}/{run_id}/{token['warrant']['id']}"]["account"] = shared_relay["account"]
            call("relay", "Connector", shared_relay, expected=dict(status=200, body=dict(native=True)))
            call("getObject", "ObjectStore", shared_object, expected='{"native":true}')
            for token in object_grant["warrants"]:
                vault.state["documents"][f"/v1/secret/data/connector-authority/{org}/{run_id}/{token['warrant']['id']}"]["account"] = object_grant["account"]
            before = len(upstream.state["calls"])
            call("relay", "Connector", shared_relay, error="credential broker denied")
            assert len(upstream.state["calls"]) == before
            # Actual broker checks HMAC and its fourth ceiling, even if lun's
            # request metadata lies. No provider call is made on either denial.
            before = len(upstream.state["calls"])
            call("relay", "Connector", relay_grant, mutate=lambda b: b["connectors"]["relay"][0]["warrants"][0]["warrant"].update(tag="00" * 32), error="credential broker denied")
            assert len(upstream.state["calls"]) == before
            call("relayAt", "Connector", relay_grant, ["reports-private", "file"], expected=dict(refused=True))
            call("relayAt", "Connector", relay_grant, ["reports", "..", "file"], error="authority denied")
            call("overriddenPayload", "Connector", relay_grant, error="credential broker denied")
            assert len(upstream.state["calls"]) == before
            # Independently deny each live local ceiling before credential use.
            for ceiling in ("organization", "connection", "cell", "warrant"):
                token = database_grant["warrants"][0]["warrant"]
                path = (f"/v1/secret/data/connector-policy/{org}/postgres/compute" if ceiling == "organization" else
                    f"/v1/secret/data/thirdparty/postgres/{user}/compute/permissions" if ceiling == "connection" else
                    f"/v1/secret/data/connector-authority/{org}/{run_id}/{token['id']}")
                saved = copy.deepcopy(vault.state["documents"][path])
                doc = vault.state["documents"][path] if ceiling in ("organization", "connection") else vault.state["documents"][path][ceiling]
                doc["scopes"] = []
                before = len(vault.state["calls"])
                call("rows", "PostgreSQL", database_grant, error="live stored authority")
                assert all(not p.startswith("/v1/secret/data/compute/") for _, p, _ in vault.state["calls"][before:])
                vault.state["documents"][path] = saved
            call("rows", "PostgreSQL", None, error="no native connection grant")
            for ceiling in ("organization", "connectionPermissions", "cell", "warrantPermissions"):
                call("insert", "PostgreSQL", database_grant, "must-not-write",
                    mutate=lambda b, ceiling=ceiling: b["connectors"]["insert"][0].update({ceiling: dict(copy.deepcopy(database_grant["cell"]), scopes=[])}),
                    error="capability ceiling")
                assert sql("select count(*) from compute_owner.notes") == "0"
            call("rows", "PostgreSQL", database_grant, mutate=lambda b: b["binding"].update(user_id="another-user"), error="user binding")
            call("rows", "PostgreSQL", database_grant, mutate=lambda b: b["binding"].update(schema="other_user"), error="compute role binding")
            call("rows", "PostgreSQL", database_grant, mutate=lambda b: b["policy"].update(effects=[]), error="permission denied")
            before = len(vault.state["calls"])
            def omit_expiry(body):
                token = body["connectors"]["rows"][0]["warrants"][0]["warrant"]
                token["caveats"] = [c for c in token["caveats"] if c["kind"] != "expiresAt"]
            call("rows", "PostgreSQL", database_grant, mutate=omit_expiry, error="requires expiry")
            def oversized_budget(body):
                for caveat in body["connectors"]["rows"][0]["warrants"][0]["warrant"]["caveats"]:
                    if caveat["kind"] == "budget":
                        caveat["value"] = str(2 ** 64)
            call("rows", "PostgreSQL", database_grant, mutate=oversized_budget, error="bounded u64 budget")
            call("rows", "PostgreSQL", database_grant, mutate=lambda b: b["connectors"]["rows"][0]["warrants"][0].update(cost=1), error="caveats or binding")
            assert len(vault.state["calls"]) == before
            call("rows", "PostgreSQL", database_grant, mutate=lambda b: b["connectors"]["rows"][0]["cell"].pop("maxRequestBytes"), error="no native operation grant")
            call("readSecret", "SecretStore", secret_grant, mutate=lambda b: b["binding"].update(graph_id="other-graph"), error="no native connection grant")
            # A valid-looking credential at the actor's path still cannot select
            # a different role, database, host, or unquoted libpq parameter.
            compute_path = f"/v1/secret/data/compute/{org}/{user}"
            original_compute = copy.deepcopy(vault.state["documents"][compute_path])
            for field, value, error in (("schema", "other_user", "bound schema"),
                    ("database", "other_database", "compiled target"),
                    ("base_url", "other-host:5432", "compiled target"),
                    ("token", "password dbname=other_database", "credential fields")):
                vault.state["documents"][compute_path] = dict(original_compute, **{field: value})
                call("rows", "PostgreSQL", database_grant, error=error)
                assert sql("select value from other_user.notes") == "private"
            vault.state["documents"][compute_path] = original_compute
            # Missing/malformed live documents never become provider defaults.
            policy_path = f"/v1/secret/data/connector-policy/{org}/postgres/compute"
            original_policy = vault.state["documents"].pop(policy_path)
            call("rows", "PostgreSQL", database_grant, error="vault operation was refused")
            vault.state["documents"][policy_path] = dict(original_policy, scopes=[{"operation": "rows.select", "root": ["compute_owner"]}])
            call("rows", "PostgreSQL", database_grant, error="Bool expected")
            vault.state["documents"][policy_path] = original_policy
            # Request and disclosed-response limits intersect independently.
            call("rows", "PostgreSQL", database_grant,
                mutate=lambda b: b["connectors"]["rows"][0]["cell"].update(maxRequestBytes=1), error="capability ceiling")
            call("rows", "PostgreSQL", database_grant,
                mutate=lambda b: b["connectors"]["rows"][0]["cell"].update(maxResponseBytes=1), error="response exceeds")
            call("readSecret", "SecretStore", secret_grant,
                mutate=lambda b: b["connectors"]["readSecret"][0]["cell"].update(maxResponseBytes=1), error="response exceeds")
            narrow_secret = copy.deepcopy(secret_grant)
            narrow_secret["cell"]["scopes"] = [dict(operation="secrets.read", root=["other-token"], descendants=False)]
            before = len(vault.state["calls"])
            call("readSecret", "SecretStore", narrow_secret, error="capability ceiling")
            assert all(p != secret_path for _, p, _ in vault.state["calls"][before:])
            call("getObject", "ObjectStore", object_grant,
                mutate=lambda b: b["connectors"]["getObject"][0].update(bucket="other-bucket"), error="exactly one connection")
            call("fetch", "HTTP", error="HTTP domain or port")
            call("privateFetch", "HTTP", mutate=lambda b: b["policy"].update(domains=["localhost"]), error="non-public address")
            call("encodedFetch", "HTTP", mutate=lambda b: b["policy"].update(domains=["example.org"]), error="noncanonical host or path")
            if options.public_http:
                call("fetch", "HTTP", mutate=lambda b: b["policy"].update(domains=["example.org"]), expected=200)
            typed = dict(inputs={"x": 3}, policy=dict(effects=["Trace"], domains=[]), binding=binding())
            status, session = exchange(base + f"/v0/builds/{build}/graphs/typed/sessions", typed)
            assert status == 201 and session["nodes"][-1]["output"] == 4, session
            endpoint = base + "/v0/sessions/" + session["session"]
            status, refused = exchange(endpoint, dict(inputs={"x": "bad"}))
            assert status == 400 and "configured type" in refused["error"]
            _, unchanged = exchange(endpoint)
            assert unchanged["updates"] == 0 and unchanged["nodes"][-1]["output"] == 4
            status, narrowed = exchange(endpoint, dict(inputs={"x": 4}, policy=dict(effects=[], domains=[])))
            assert status == 200 and "permission denied" in narrowed["changed"][-1]["error"]
            status, refused = exchange(endpoint, dict(inputs={"x": 5}, policy=dict(effects=["Trace"], domains=[])))
            assert status == 403
            checks += 5
            status, recovered = exchange(base + f"/v0/builds/{build}/graphs/typed/sessions",
                dict(typed, inputs={"x": "historic incompatible value"}, recoverInputs=True))
            assert status == 201 and "configured type" in recovered["nodes"][0]["error"] and "skipped" in recovered["nodes"][1]
            assert "typed source evaluated" not in recovered.get("log", "")
            status, fixed = exchange(base + "/v0/sessions/" + recovered["session"], dict(inputs={"x": 8}))
            assert status == 200 and fixed["nodes"][-1]["output"] == 9
            checks += 2
            # Session refresh consumes the current public ceilings, with the
            # current app's absent warrantPermissions field and fresh tokens.
            connected = dict(inputs={"selector": ["reports", "file"]}, policy=dict(effects=["Connector"], domains=[]),
                binding=binding(), connectors={"relayAt": [relay_grant]})
            status, session = exchange(base + f"/v0/builds/{build}/graphs/connected/sessions", connected)
            assert status == 201 and session["nodes"][-1]["output"]["body"] == dict(native=True), session
            persisted = (directory / f"lun/sessions/{session['session']}.json").read_text()
            assert '"tag"' not in persisted and '"warrants"' not in persisted and "fixture-vault" not in persisted
            endpoint = base + "/v0/sessions/" + session["session"]
            narrow_relay = copy.deepcopy(relay_grant)
            for ceiling in ("organization", "connectionPermissions", "cell"):
                narrow_relay[ceiling].update(scopes=[dict(operation="objects.read", root=["reports", "nested"], descendants=True)],
                    maxRequestBytes=1024, maxResponseBytes=1024)
            status, reply = exchange(endpoint, dict(inputs={"selector": ["reports", "nested", "file"]}, connectors={"relayAt": [narrow_relay]}))
            assert status == 200 and reply["nodes"][-1]["output"]["body"] == dict(native=True), reply
            before = len(upstream.state["calls"])
            status, refused = exchange(endpoint, dict(inputs={"selector": ["reports", "file"]}, connectors={"relayAt": [relay_grant]}))
            assert status == 403 and len(upstream.state["calls"]) == before, refused
            status, denied = exchange(endpoint, dict(inputs={"selector": ["reports", "nested", "other-file"]}))
            assert status == 200 and "grant" in denied["nodes"][-1]["error"], denied
            assert len(upstream.state["calls"]) == before
            status, refused = exchange(endpoint, dict(inputs={"selector": ["reports", "nested", "file"]}, connectors={"relayAt": [narrow_relay]}))
            assert status == 403 and len(upstream.state["calls"]) == before, refused
            checks += 5
            # Legacy ready artifacts cannot bypass the new interpreter via cache.
            status_file = directory / f"lun/builds/{build}/status.json"
            saved_status = status_file.read_text()
            legacy = json.loads(saved_status)
            legacy.pop("runtimeContract")
            status_file.write_text(json.dumps(legacy))
            before = len(vault.state["calls"])
            refused_status, refused = exchange(base + f"/v0/builds/{build}/functions/rows", dict(policy=dict(effects=["PostgreSQL"], domains=[]), binding=binding(), connectors={"rows": [database_grant]}))
            assert refused_status == 409 and "older runtime" in refused["error"]
            assert len(vault.state["calls"]) == before
            status_file.write_text(saved_status)
            checks += 1
            assert sql("select count(*) from credit_holds where state='held'") == "0"
            print(f"PASS: {checks} compiled-driver runtime cases; actual SCRAM queries, vault effects, native HMAC broker, typed inputs and attenuation")
        finally:
            for proc, log in reversed(processes):
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                log.close()
            if pg_started:
                run("pg_ctl", "-D", str(pg), "-m", "immediate", "-w", "stop")
            vault.shutdown()
            upstream.shutdown()


if __name__ == "__main__":
    main()
