import LunDriver.Runtime

open Lean LunDriver Control.Monad.Effect

#guard (ExecutionContext.ofRequest (Json.mkObj [])).toOption.map (fun c => c.effects) == some (some [])
#guard (ExecutionContext.ofRequest (Json.mkObj [("policy", Json.null)])).toOption.isNone
#guard (ExecutionContext.ofRequest (Json.mkObj [("policy", Json.mkObj [("effects", Json.arr #[]), ("domains", Json.arr #[])]),
  ("binding", Json.mkObj [("org_id", "../escape"), ("user_id", "u")])])).toOption.isNone

#guard publicAddress "8.8.8.8"
#guard publicAddress "2001:4860:4860::8888"
#guard !publicAddress "127.0.0.1"
#guard !publicAddress "10.0.0.1"
#guard !publicAddress "100.64.0.1"
#guard !publicAddress "169.254.169.254"
#guard !publicAddress "172.31.0.1"
#guard !publicAddress "192.168.1.1"
#guard !publicAddress "198.18.0.1"
#guard !publicAddress "203.0.113.1"
#guard !publicAddress "224.0.0.1"
#guard !publicAddress "::1"
#guard !publicAddress "::ffff:127.0.0.1"
#guard !publicAddress "fc00::1"
#guard !publicAddress "fe80::1"
#guard !publicAddress "64:ff9b::a00:1"
#guard !publicAddress "2002:7f00:1::"
#guard !publicAddress "2001:db8::1"
#guard validHTTPHost ["example", "org"]
#guard !validHTTPHost ["example", "org\r\n"]
#guard !Connector.Resource.valid ["reports", "%2e%2e", "outside"]

example {ctx : ExecutionContext} {cap : PostgreSQL.Capability} (q : AuthorizedQuery ctx cap) :
    q.query.table.schema = ctx.schema := q.schema_confined

example {ctx : ExecutionContext} {cap : PostgreSQL.Capability} (q : AuthorizedQuery ctx cap) :
    q.native.authority.organization.permits (postgresOperation q.query.op) [q.query.table.schema, q.query.table.name] = true :=
  q.organization_permits

#guard ((InputContract.ofType Nat).validate (toJson (3 : Nat))).isOk
#guard ((InputContract.ofType Nat).validate (Json.str "wrong")).toOption.isNone
#guard ((InputContract.ofType (List Nat)).validate (Json.arr #[toJson (3 : Nat), Json.str "wrong"])).toOption.isNone
example {ctx : ExecutionContext} {cap : PostgreSQL.Capability} (target : BoundCompute ctx cap) :
    cap.user = ctx.schema := target.role_confined

example (call : NativeOperation ctx cap op resource) :
    call.live.organization.permits op resource = true := call.live_organization_permits
example (call : NativeOperation ctx cap op resource) :
    call.live.connection.permits op resource = true := call.live_connection_permits
example (call : NativeOperation ctx cap op resource) :
    call.live.cell.permits op resource = true := call.live_cell_permits
example (call : NativeOperation ctx cap op resource) :
    call.live.warrant.permits op resource = true := call.live_warrant_permits

-- Native cells S3: the consumer checks the actual argument/result dictionaries.
private def nativeDouble (value : Nat) : Eff [] Nat := pure (2 * value)
private def nativeChecked : FunctionImpl := FunctionImpl.ofFn "double" "Nat → Eff [] Nat" nativeDouble
#guard (nativeChecked.validateArgs [toJson (2 : Nat)]).isOk
#guard (nativeChecked.validateArgs [Json.str "wrong"]).toOption.isNone
#guard (nativeChecked.validateArgs [toJson (2 : Nat), toJson (3 : Nat)]).toOption.isNone
#guard (nativeChecked.validateValue (Json.str "wrong")).toOption.isNone
#guard match System.Cell.GitSource.check "https://github.com/o/r"
    ("".pushn 'a' 40) "." "P" "P.double" with
  | .error _ => false
  | .ok source => (nativeChecked.checkReply
      {name := "double", contract := {source, signature := "Nat → Eff [] Nat", arity := 1, producer := false},
       arguments := [2], context := Json.mkObj []}
      {outcome := Json.mkObj [("output", Json.str "wrong")], log := ""}).toOption.isNone

namespace NativeAlias
def sample (value : Nat) : Eff [] Nat := pure value
def generic {α : Type} [ToString α] (value : α) : Eff [] String := pure (toString value)
end NativeAlias
open NativeAlias in
lun_function "resolvedNative" := sample : r"Nat → Eff [] Nat"
#guard LunDriver.Impl.resolvedNative.declaration == "NativeAlias.sample"
lun_function "genericNative" := NativeAlias.generic : r"Nat → Eff [] String"
#guard LunDriver.Impl.genericNative.declaration == "NativeAlias.generic"

-- S4: the graph bound counts distinct cells, and unsigned closures cannot run.
private def graphWithCells (count : Nat) : Except String GraphImpl :=
  let functions := (List.range count).map fun i =>
    FunctionImpl.ofFn s!"cell{i}" "Eff [] Nat" (pure 1 : Eff [] Nat)
  GraphImpl.ofReactive functions do
    for c in functions do
      discard (applyFunction c Nat [])

#guard (graphWithCells 16).isOk
#guard (graphWithCells 17).toOption.isNone

#eval show IO Unit from do
  let graph ← IO.ofExcept ((graphWithCells 1).mapError IO.userError)
  match ← runGraph graph (Json.mkObj []) with
  | .error message =>
    unless (message.splitOn "no compiler-attested cells").length > 1 do
      throw (IO.userError message)
  | .ok _ => throw (IO.userError "an unsigned in-process graph closure executed")
