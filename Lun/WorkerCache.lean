/- Bounded compiled-process cache. A lease consumes evidence that its immutable
   build/entry point/actor binding matches the current request. No context, grants,
   results or session state are stored in the cache. -/
import Lean.Data.Json
import Linen.System.Worker
import Linen.Crypto.SecureRandom
import Linen.Data.Hex

namespace Lun.WorkerCache
open Lean (Json)

/-- Resource ceilings are validated once and carried by the cache's type. -/
structure Capacity where
  private mk ::
  count : Nat
  positive : 0 < count
  bounded : count ≤ 16

def Capacity.check (count : Nat) : Except String Capacity :=
  if hp : 0 < count then
    if hb : count ≤ 16 then .ok ⟨count, hp, hb⟩
    else .error "LUN_WORKERS must be at most 16"
  else .error "LUN_WORKERS must be positive"

def defaultCapacity : Capacity := ⟨4, by decide, by decide⟩

/-- Exact immutable artifact, entry point and complete actor/resource binding.
    Permissions and private credentials are intentionally not retained. -/
def keyOf (build kind name : String) (body : Json) : String :=
  let binding := (body.getObjVal? "binding").toOption.getD Json.null
  (Json.arr #[Json.str build, Json.str (if kind == "function" then kind else "graph"), Json.str name,
    Json.arr ((["org_id", "user_id", "graph_id", "schema"].map fun field =>
      ((binding.getObjValAs? String field).toOption.map Json.str).getD Json.null).toArray)]).compress

/-- The transport payload cannot be substituted after selecting an actor-bound
    worker. Its key equality is consumed by acquisition, not merely documented. -/
structure Request where
  private mk ::
  build : String
  kind : String
  name : String
  body : Json
  key : String
  bound : key = keyOf build kind name body
  line : System.Worker.Line
  framed : line.value = (Json.mkObj [("kind", Json.str kind), ("name", Json.str name), ("request", body)]).compress

def Request.check (build kind name : String) (body : Json) : Except String Request := do
  let value := (Json.mkObj [("kind", Json.str kind), ("name", Json.str name), ("request", body)]).compress
  let line ← System.Worker.Line.check value
  if h : line.value = value then
    return ⟨build, kind, name, body, keyOf build kind name body, rfl, line, h⟩
  else throw "invalid worker request framing"

private structure Entry where
  key : String
  worker : System.Worker.Worker
  busy : Bool

/-- Finite slots make exceeding the process ceiling unrepresentable. -/
structure Cache where
  private mk ::
  capacity : Capacity
  private slots : Std.Mutex (Vector (Option Entry) capacity.count)
  private stopped : IO.Ref Bool
  private leaseFile : System.FilePath
  private nextRequest : IO.Ref Nat
  private heartbeat : Task (Except IO.Error Unit)

private structure Lease (cache : Cache) (request : Request) where
  slot : Fin cache.capacity.count
  entry : Entry
  sameKey : entry.key = request.key

theorem request_binding (request : Request) :
    request.key = keyOf request.build request.kind request.name request.body := request.bound

/-- The storage has exactly one possible process per bounded index. -/
theorem slots_bounded (cache : Cache) :
    (List.ofFn (fun i : Fin cache.capacity.count => i)).length ≤ 16 := by
  simpa using cache.capacity.bounded

def Cache.new (workdir : System.FilePath) (capacity : Capacity := defaultCapacity) : IO Cache := do
  IO.FS.createDirAll workdir
  let nonce := Data.Hex.encode (← Crypto.SecureRandom.randomBytes 16)
  let leaseFile := workdir / s!"worker-lease-{nonce}"
  IO.FS.writeFile leaseFile (toString (← IO.monoMsNow))
  let stopped ← IO.mkRef false
  -- A parent crash (including SIGKILL) leaves no persistent orphan: generated
  -- drivers supervise this private heartbeat independently of blocked requests.
  let heartbeat ← IO.asTask (prio := .dedicated) do
    repeat
      IO.sleep 1000
      if ← stopped.get then break
      try
        let tmp := leaseFile.withExtension "tmp"
        IO.FS.writeFile tmp (toString (← IO.monoMsNow))
        IO.FS.rename tmp leaseFile
      catch _ => stopped.set true; break
  return ⟨capacity, ← Std.Mutex.new (Vector.replicate capacity.count none), stopped, leaseFile, ← IO.mkRef 0, heartbeat⟩

/-- Response correlation is checked before a worker's result can be consumed. -/
structure Response (expected : Nat) where
  private mk ::
  value : Json
  correlated : (value.getObjValAs? Nat "id").toOption = some expected

def Response.check (expected : Nat) (text : String) : Except String (Response expected) := do
  let value ← Json.parse text
  let status ← value.getObjValAs? Nat "status"
  unless status == 200 || status == 400 do throw "invalid worker response status"
  match ← value.getObjVal? "body" with
  | .obj _ => pure ()
  | _ => throw "worker response body is not an object"
  if h : (value.getObjValAs? Nat "id").toOption = some expected then return ⟨value, h⟩
  else throw "worker answered a different request"

private def Cache.acquire (cache : Cache) (request : Request) (exe : String)
    (env : Array (String × Option String)) : IO (Option (Lease cache request)) :=
  cache.slots.atomically (m := IO) do
    if ← cache.stopped.get then throw (IO.userError "worker cache is closed")
    let slots ← get
    let indices := List.ofFn (fun i : Fin cache.capacity.count => i)
    for i in indices do
      if let some entry := slots.get i then
        if h : entry.key = request.key then
          if !entry.busy && (← entry.worker.isAlive) then
            let entry := {entry with busy := true}
            set (slots.set i.val (some entry) i.isLt)
            return some ⟨i, entry, h⟩
    -- Use a vacant slot first. Only idle workers may be evicted; never replay
    -- or interrupt a different request to make room for this one.
    let vacant := indices.find? fun i => (slots.get i).isNone
    let idle := indices.find? fun i => ((slots.get i).map fun e => !e.busy).getD false
    let some i := vacant.or idle | return none
    if let some entry := slots.get i then entry.worker.stop
    let worker ← System.Worker.spawn exe #["worker", cache.leaseFile.toString] env
    let entry : Entry := {key := request.key, worker, busy := true}
    set (slots.set i.val (some entry) i.isLt)
    return some ⟨i, entry, rfl⟩

private def Lease.release {cache : Cache} {request : Request} (lease : Lease cache request) : IO Unit :=
  cache.slots.atomically (m := IO) do
    let slots ← get
    let alive ← lease.entry.worker.isAlive
    set (slots.set lease.slot.val
      (if alive then some {lease.entry with busy := false} else none) lease.slot.isLt)

/-- Queue time is part of the deadline. A failed worker is destroyed and removed;
    the request is never retried (it may already have performed an effect). -/
def Cache.call (cache : Cache) (request : Request) (exe : String)
    (env : Array (String × Option String)) (timeoutMs : Nat) : IO Json := do
  let deadline := (← IO.monoMsNow) + timeoutMs
  repeat
    if (← IO.monoMsNow) ≥ deadline then throw (IO.userError "worker request timed out")
    if let some lease ← cache.acquire request exe env then
      try
        let id ← cache.nextRequest.modifyGet (fun n => (n, n + 1))
        let call ← IO.ofExcept ((Json.parse request.line.value).mapError IO.userError)
        let frame ← IO.ofExcept ((System.Worker.Line.check
          (Json.mkObj [("id", Lean.toJson id), ("call", call)]).compress).mapError IO.userError)
        let text ← lease.entry.worker.call frame (deadline - (← IO.monoMsNow))
        let response ← IO.ofExcept ((Response.check id text).mapError IO.userError)
        return response.value
      catch e => lease.entry.worker.stop; throw e
      finally lease.release
    IO.sleep 1

/-- Graceful shutdown closes every process group and removes the heartbeat. -/
def Cache.close (cache : Cache) : IO Unit := do
  cache.stopped.set true
  let _ ← IO.wait cache.heartbeat
  cache.slots.atomically (m := IO) do
    let slots ← get
    for i in List.ofFn (fun i : Fin cache.capacity.count => i) do
      if let some entry := slots.get i then entry.worker.stop
    set (Vector.replicate cache.capacity.count (none : Option Entry))
  if ← cache.leaseFile.pathExists then IO.FS.removeFile cache.leaseFile

end Lun.WorkerCache
