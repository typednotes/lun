#!/usr/bin/env python3
"""Measure a real compiled two-Nat-input arithmetic graph, without external IO.

Creates only an isolated local Git project/runner beneath --temp-root. Reports
HTTP QPS and latency for graph calls and isolated reactive sessions. Compilation
and warm-up are excluded. No production service, credential or database is used.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--temp-root",type=Path,required=True)
    parser.add_argument("--requests",type=int,default=300)
    parser.add_argument("--concurrency",type=int,nargs="+",default=[1,4,8])
    parser.add_argument("--worker-count",type=int,default=4)
    args=parser.parse_args()
    assert args.temp_root.is_dir() and args.requests>0 and all(c>0 for c in args.concurrency) and 1<=args.worker_count<=16
    output=Path(tempfile.mkdtemp(prefix="lun-benchmark-",dir=args.temp_root))
    print("Artifacts:",output,flush=True)
    repo=output/"repo";repo.mkdir()
    (repo/"Benchmark.lean").write_text('import Linen.Control.Monad.Effect\nnamespace Benchmark\nopen Control.Monad.Effect\ndef add (a b : Nat) : Eff [] Nat := pure (a + b)\nend Benchmark\n')
    (repo/"lakefile.toml").write_text(f'name="lun_arithmetic_benchmark"\ndefaultTargets=["Benchmark"]\n[[require]]\nname="linen"\npath="{ROOT.parent / "linen"}"\n[[lean_lib]]\nname="Benchmark"\n')
    (repo/"lean-toolchain").write_text((ROOT/"lean-toolchain").read_text())
    def run(argv,where=repo):
        return subprocess.run(argv,cwd=where,check=True,capture_output=True,text=True).stdout.strip()
    run(["lake","update"])
    run(["git","init","-q","-b","main"]);run(["git","add","."])
    run(["git","-c","user.name=Benchmark fixture","-c","user.email=benchmark@example.invalid","-c","commit.gpgsign=false","commit","-qm","Arithmetic benchmark fixture"])
    commit=run(["git","rev-parse","HEAD"])
    with socket.socket() as s:s.bind(("127.0.0.1",0));port=s.getsockname()[1]
    env={**os.environ,"LUN_PORT":str(port),"LUN_TOKEN":"benchmark-fixture","LUN_ALLOW_LOCAL":"1","LUN_WORKDIR":str(output/"runner"),"LUN_ID_SALT":"arithmetic-benchmark","LUN_LIAISON_SDK_PATH":str(ROOT.parent/"liaison")}
    env["LUN_WORKERS"]=str(args.worker_count)
    for k in ["LUN_LIAISON_URL","SECRETS_HOST","SECRETS_PASSWORD","SECRETS_TOKEN","SECRETS_USERNAME","COMPUTE_DB_URL"]:env.pop(k,None)
    log=(output/"runner.log").open("w")
    process=subprocess.Popen([str(ROOT/".lake/build/bin/lun")],env=env,stdout=log,stderr=log)
    clients=[]
    def client():
        conn=http.client.HTTPConnection("127.0.0.1",port,timeout=30);clients.append(conn);return conn
    def api(conn,path,body=None,method=None):
        conn.request(method or ("POST" if body is not None else "GET"),path,json.dumps(body) if body is not None else None,{"Authorization":"Bearer benchmark-fixture","Content-Type":"application/json"})
        r=conn.getresponse();raw=r.read()
        value={} if path=="/_health" or not raw else json.loads(raw)
        assert r.status in (200,201,202),(r.status,value)
        return value
    try:
        control=client()
        for _ in range(100):
            try:api(control,"/_health");break
            except (OSError,http.client.HTTPException):control.close();time.sleep(.1)
        else:raise AssertionError("local runner failed to start")
        request={"source":{"url":repo.as_uri(),"branch":"main","commit":commit},"open":["Benchmark"],
            "functions":[{"name":"add","module":"Benchmark","function":"Benchmark.add","signature":"Nat → Nat → Eff [] Nat","outputType":"Nat"}],
            "graphs":[{"name":"main","program":"do\n let a ← input \"a\" Nat\n let b ← input \"b\" Nat\n add a b","inputTypes":{"a":"Nat","b":"Nat"},"dependencies":{"add":["a","b"]}}]}
        started=time.perf_counter();build=api(control,"/v0/builds",request)
        while build["state"] not in ("ready","failed"):
            assert time.perf_counter()-started<600,build
            time.sleep(.25);build=api(control,"/v0/builds/"+build["id"])
        assert build["state"]=="ready",build
        compile_seconds=time.perf_counter()-started
        body={"policy":{"effects":[],"domains":[]},"binding":{"org_id":"bench-org","user_id":"bench-user","graph_id":"bench-graph"},"connectors":{}}
        path=f"/v0/builds/{build['id']}/graphs/main"
        def valid(answer,a,b):
            assert next(n["output"] for n in answer["nodes"] if n.get("function")=="add")==a+b,answer
        for i in range(20):valid(api(control,path,{**body,"inputs":{"a":i,"b":11}}),i,11)
        rows=[]
        for mode in ("graph","session"):
            for concurrency in args.concurrency:
                def worker(index):
                    conn=client();sid=None
                    if mode=="session":sid=api(conn,path+"/sessions",{**body,"inputs":{"a":0,"b":11}})["session"]
                    try:
                        durations=[]
                        for i in range(index,args.requests,concurrency):
                            a=i+1;b=i+11
                            then=time.perf_counter_ns()
                            answer=api(conn,"/v0/sessions/"+sid if sid else path,{**body,"inputs":{"a":a,"b":b}})
                            durations.append((time.perf_counter_ns()-then)/1e6);valid(answer,a,b)
                        return durations
                    finally:
                        if sid:api(conn,"/v0/sessions/"+sid,method="DELETE")
                        conn.close()
                start=time.perf_counter()
                with ThreadPoolExecutor(max_workers=concurrency) as pool:durations=sum(pool.map(worker,range(concurrency)),[])
                seconds=time.perf_counter()-start;durations.sort()
                percentile=lambda p:durations[min(len(durations)-1,int((len(durations)-1)*p))]
                row={"mode":mode,"concurrency":concurrency,"requests":len(durations),"seconds":seconds,"qps":len(durations)/seconds,"p50_ms":percentile(.5),"p95_ms":percentile(.95),"p99_ms":percentile(.99),"errors":0}
                rows.append(row);print(json.dumps(row),flush=True)
        sources=[ROOT/"Lun/WorkerCache.lean",ROOT/"Lun/Build.lean",ROOT/"template/LunDriver/Runtime.lean",ROOT.parent/"linen/Linen/System/Worker.lean"]
        result={"timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat(),"host":platform.platform(),"cpu_count":os.cpu_count(),"runner_commit":run(["git","rev-parse","HEAD"],ROOT),"runner_dirty":bool(run(["git","status","--porcelain"],ROOT)),"source_sha256":{str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},"worker_count":args.worker_count,"runtime_contract":build["runtimeContract"],"compile_seconds_excluded":compile_seconds,"warmup_requests_excluded":20,"graph":"Nat + Nat -> Eff [] Nat","rows":rows,"method":"Local HTTP with per-worker HTTPConnection objects (automatic reconnect if server closes); modes run graph then session, concurrency 1/4/8 in order. Only 20 sequential graph requests are warmed; later worker cold starts remain in timings. Session rows include setup/teardown overhead in QPS denominator; latencies cover only evaluated requests; all results validated."}
        (output/"results.json").write_text(json.dumps(result,indent=2));print("Result:",output/"results.json",flush=True)
    finally:
        for conn in clients:conn.close()
        children=subprocess.run(["pgrep","-P",str(process.pid)],capture_output=True,text=True).stdout.split()
        process.terminate()
        try:process.wait(timeout=10)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        deadline=time.monotonic()+8
        def alive(pid):
            try:os.kill(int(pid),0);return True
            except ProcessLookupError:return False
        while any(alive(p) for p in children) and time.monotonic()<deadline:time.sleep(.1)
        assert not any(alive(p) for p in children),f"workers survived runner termination: {children}"
        log.close()

if __name__=="__main__":main()
