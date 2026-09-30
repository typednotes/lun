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
