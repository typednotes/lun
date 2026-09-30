import Linen.Control.Monad.Effect.Connector
import Linen.Control.Monad.Effect.FileSystem
import Linen.Control.Monad.Effect.HTTP
import Linen.Control.Monad.Effect.PostgreSQL

namespace Fixture.Scoped
open Control.Monad.Effect

abbrev storage : Connector.Capability :=
  { provider := "s3", connection := "conn-1",
    scopes := [{ operation := "objects.read", root := ["reports"] }] }

def report (path : List String) : Eff [Connector.Connector storage] Lean.Json :=
  match Connector.ScopedResource.check? storage "objects.read" path with
  | some resource => Connector.callAt "objects.read" resource
  | none => pure (Lean.Json.str "static scope refused")

abbrev files : FileSystem.Capability := { canRead := true, canWrite := true, canDelete := true }

def writeRead (contents : String) : Eff [FileSystem.FileSystem files] String := do
  FileSystem.writeFileString ["note.txt"] contents
  let value ← FileSystem.readFileString? ["note.txt"]
  return value.getD "invalid UTF-8"

def readPath (path : List String) : Eff [FileSystem.FileSystem files] String := do
  match FileSystem.ScopedPath.check? files .read path with
  | some path => return (String.fromUTF8? (← FileSystem.readFileAt path)).getD "invalid UTF-8"
  | none => pure "static scope refused"

abbrev http : HTTP.Capability := HTTP.readOnlyWeb
open HTTP in
def fetch : Eff [HTTP.HTTP http] Nat := do
  let response ← HTTP.get u!"https://example.org/"
  return response.statusCode.statusCode

abbrev compute : PostgreSQL.Capability :=
  { host := "127.0.0.1", port := 5432, database := "compute", user := "org_1_user_1", canSelect := true }

def foreignSchema : Eff [PostgreSQL.PostgreSQL compute] Nat := do
  let rows ← PostgreSQL.select { schema := "other_user", name := "private" }
  return rows.rows.size

end Fixture.Scoped
