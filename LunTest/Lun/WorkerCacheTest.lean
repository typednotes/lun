import Lun.WorkerCache
open Lean Lun.WorkerCache

#guard (Capacity.check 0).toOption.isNone
#guard (Capacity.check 17).toOption.isNone
#guard (Capacity.check 16).isOk
example (capacity : Capacity) : capacity.count ≤ 16 := capacity.bounded
example (request : Request) : request.key = keyOf request.build request.kind request.name request.body := request_binding request
example (response : Response n) : (response.value.getObjValAs? Nat "id").toOption = some n := response.correlated

def body (org user graph : String) : Json := Json.mkObj [("binding", Json.mkObj
  [("org_id", Json.str org), ("user_id", Json.str user), ("graph_id", Json.str graph)])]
#guard keyOf "build" "graph" "main" (body "org" "a" "g") != keyOf "build" "graph" "main" (body "org" "b" "g")
#guard keyOf "build" "graph" "main" (body "org" "a" "g") != keyOf "build" "graph" "main" (body "other" "a" "g")
#guard keyOf "build" "graph" "main" (body "org" "a" "g") != keyOf "build" "graph" "main" (body "org" "a" "other")
#guard keyOf "build" "graph" "main" Json.null != keyOf "other" "graph" "main" Json.null
#guard keyOf "build" "function" "main" Json.null != keyOf "build" "graph" "main" Json.null
#guard keyOf "build" "graph" "main" Json.null == keyOf "build" "graph" "main" (Json.mkObj [("state", Json.null)])
#guard keyOf "build" "graph" "main" ((body "org" "a" "g").setObjVal! "_runtime" (Json.mkObj [("SECRETS_TOKEN", "private")])) == keyOf "build" "graph" "main" (body "org" "a" "g")
#guard (Response.check 7 "{\"id\":7,\"status\":200,\"body\":{}}").isOk
#guard (Response.check 8 "{\"id\":7,\"status\":200,\"body\":{}}").toOption.isNone
#guard (Response.check 7 "{\"id\":7,\"status\":503,\"body\":{}}").toOption.isNone
#guard (Response.check 7 "{\"id\":7,\"status\":200,\"body\":[]}").toOption.isNone

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

-- Real processes exercise reuse, actor isolation, fresh payloads, eviction,
-- malformed-response retirement and deadline recovery through the actual cache.
#eval show IO Unit from do
  let (handle, path) ← IO.FS.createTempFile
  let directory := path.withExtension "workers"
  handle.putStr r#"#!/usr/bin/env python3
import json,os,sys,time
for text in sys.stdin:
 frame=json.loads(text);call=frame['call'];body=call['request']
 if body.get('sleep'):time.sleep(30)
 ident=frame['id']+int(body.get('wrong_id',False))
 print(json.dumps({'id':ident,'status':200,'body':{'pid':os.getpid(),'payload':body}}),flush=True)
"#
  handle.flush
  let permissions ← System.Process.run "chmod" #["700", path.toString] 10000
  check permissions.ok "cannot make fixture worker executable"
  let capacity ← IO.ofExcept ((Capacity.check 1).mapError IO.userError)
  let cache ← Cache.new directory capacity
  let call (value : Json) (deadline : Nat := 10000) : IO Json := do
    let request ← IO.ofExcept ((Request.check "build" "graph" "main" value).mapError IO.userError)
    return ← cache.call request path.toString #[] deadline
  let pid (reply : Json) : Nat := (reply.getObjVal? "body" >>= (·.getObjValAs? Nat "pid")).toOption.getD 0
  try
    let preloaded ← cache.preload "build" path.toString #[] 10000
    check preloaded.isSome "compiled worker was not preloaded"
    let a ← call (body "org" "a" "g")
    check (preloaded.map (·.toNat) == some (pid a)) "first actor did not acquire the already-loaded process"
    let b ← call ((body "org" "a" "g").setObjVal! "policy" (Json.mkObj [("effects", toJson ([] : List String))]))
    check (pid a > 0 && pid a == pid b) "same binding did not reuse the compiled process"
    check ((b.getObjVal? "body" >>= (·.getObjVal? "payload") >>= (·.getObjVal? "policy")).isOk) "fresh payload was lost"
    let other ← call (body "org" "b" "g")
    check (pid other != pid a) "another actor reused a private worker"
    let invalid ← (call ((body "org" "b" "g").setObjVal! "wrong_id" (toJson true))).toBaseIO
    check invalid.toOption.isNone "uncorrelated reply was accepted"
    let recovered ← call (body "org" "b" "g")
    check (pid recovered != pid other) "malformed worker survived"
    let hung ← (call ((body "org" "b" "g").setObjVal! "sleep" (toJson true)) 100).toBaseIO
    check hung.toOption.isNone "hung worker did not time out"
    let restarted ← call (body "org" "b" "g")
    check (pid restarted != pid recovered) "timed-out worker was reused"
  finally
    cache.close
    IO.FS.removeFile path
    IO.FS.removeDirAll directory
