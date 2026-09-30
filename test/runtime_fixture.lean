import Linen.Control.Monad.Effect.PostgreSQL
import Linen.Control.Monad.Effect.SecretStore
import Linen.Control.Monad.Effect.ObjectStore
import Linen.Control.Monad.Effect.Connector
import Linen.Control.Monad.Effect.HTTP
import Linen.Control.Monad.Effect.Trace

namespace RuntimeFixture
open Control.Monad.Effect

abbrev compute : PostgreSQL.Capability :=
  { host := "127.0.0.1", port := TEST_POSTGRES_PORT, database := "postgres", user := "compute_owner",
    canSelect := true, canInsert := true, canUpdate := true, canDelete := true }

def rows : Eff [PostgreSQL.PostgreSQL compute] Nat := do
  return (← PostgreSQL.select { schema := "compute_owner", name := "notes" }).rows.size

def insert (value : String) : Eff [PostgreSQL.PostgreSQL compute] Nat :=
  PostgreSQL.insertInto { schema := "compute_owner", name := "notes" } ["value"] [.text value] (hs := by rfl)

def update (value : String) : Eff [PostgreSQL.PostgreSQL compute] Nat :=
  PostgreSQL.update { schema := "compute_owner", name := "notes" } [("value", .text value)] (hs := by rfl)

def delete : Eff [PostgreSQL.PostgreSQL compute] Nat :=
  PostgreSQL.deleteFrom { schema := "compute_owner", name := "notes" }

def foreign : Eff [PostgreSQL.PostgreSQL compute] Nat := do
  return (← PostgreSQL.select { schema := "other_user", name := "notes" }).rows.size

def truncated : Eff [PostgreSQL.PostgreSQL compute] Nat := do
  return (← PostgreSQL.select { schema := "compute_owner", name := String.ofList (List.replicate 64 'x') }).rows.size

abbrev secrets : SecretStore.Capability :=
  { canGetValue := true, canDescribe := true, canPut := true, canList := true,
    scopes := [{ namePrefix := [] }] }

def readSecret : Eff [SecretStore.SecretStore secrets] String := do
  return (← SecretStore.getString ["token"]).toOption.getD "backend refusal"

def putSecret (value : String) : Eff [SecretStore.SecretStore secrets] Bool := do
  return (← SecretStore.putString ["token"] value).isOk

def describeSecret : Eff [SecretStore.SecretStore secrets] Bool := do
  return (← SecretStore.exists? ["token"]).toOption.getD false

def listSecrets : Eff [SecretStore.SecretStore secrets] Nat := do
  return ((← SecretStore.list []).toOption.map (·.items.length)).getD 0

def escapeSecret : Eff [SecretStore.SecretStore secrets] String := do
  return (← SecretStore.getString ["..", "other", "token"]).toOption.getD "backend refusal"

abbrev objects : ObjectStore.Capability :=
  { canGet := true, canPut := true, canDelete := true, canList := true,
    scopes := [ObjectStore.under "bucket" ["reports"]] }

def getObject : Eff [ObjectStore.ObjectStore objects] String := do
  return (← ObjectStore.getString "bucket" ["reports", "file"]).toOption.getD "backend refusal"

def putObject (value : String) : Eff [ObjectStore.ObjectStore objects] Bool := do
  return (← ObjectStore.putString "bucket" ["reports", "file"] value (opts := {})).isOk

def headObject : Eff [ObjectStore.ObjectStore objects] Bool := do
  return ((← ObjectStore.head "bucket" ["reports", "file"]).toOption.bind id).isSome

def deleteObject : Eff [ObjectStore.ObjectStore objects] Bool := do
  return (← ObjectStore.delete "bucket" ["reports", "file"]).isOk

def listObjects : Eff [ObjectStore.ObjectStore objects] Nat := do
  return ((← ObjectStore.list "bucket" ["reports"]).toOption.map (·.items.length)).getD 0

abbrev connector : Connector.Capability :=
  { provider := "s3", connection := "connection",
    scopes := [{ operation := "objects.read", root := ["reports"] }] }

def relay : Eff [Connector.Connector connector] Lean.Json :=
  Connector.call "objects.read" ["reports", "file"]

def relayAt (resource : List String) : Eff [Connector.Connector connector] Lean.Json :=
  match Connector.ScopedResource.check? connector "objects.read" resource with
  | some target => Connector.callAt "objects.read" target
  | none => pure (Lean.Json.mkObj [("refused", Lean.Json.bool true)])

def overriddenPayload : Eff [Connector.Connector connector] Lean.Json :=
  Connector.call "objects.read" ["reports", "file"]
    (Lean.Json.mkObj [("url", Lean.Json.str "http://other-user.invalid/private")])

open HTTP in
def fetch : Eff [HTTP.HTTP HTTP.readOnlyWeb] Nat := do
  return (← HTTP.get u!"https://example.org/").statusCode.statusCode

open HTTP in
def privateFetch : Eff [HTTP.HTTP HTTP.readOnlyWeb] Nat := do
  return (← HTTP.get u!"http://localhost/").statusCode.statusCode

open HTTP in
def encodedFetch : Eff [HTTP.HTTP HTTP.readOnlyWeb] Nat := do
  return (← HTTP.get u!"https://example.org/reports/%2e%2e/outside").statusCode.statusCode

def traced (n : Nat) : Eff [Trace.Trace] Nat := do
  Trace.trace "typed source evaluated"
  return n + 1

end RuntimeFixture
