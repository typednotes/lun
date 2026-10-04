import Lean.Data.Json
import Linen.Control.Monad.Effect
import Linen.Control.Monad.Effect.Trace
import Linen.Control.Monad.Effect.Error
import Linen.Control.Monad.Effect.FileSystem
import Linen.Control.Monad.Effect.HTTP
import Linen.Control.Monad.Effect.Connector

namespace Tutorial

open Control.Monad.Effect

-- ── JSON arguments and results ──────────────────────────────────────────────

/-- A pure computation with one argument. -/
def double (n : Nat) : Eff [] Nat := pure (2 * n)

/-- Two arguments and a request-local trace. -/
def add (a b : Nat) : Eff [Trace.Trace] Nat := do
  Trace.trace s!"adding {a} and {b}"
  pure (a + b)

/-- A source function with no JSON argument. -/
def seed : Unit → Eff [] Nat := fun _ => pure 10

/-- A polymorphic function whose row is fixed by the build declaration. -/
def succ {effs : List (Type → Type)} (n : Nat) : Eff effs Nat := pure (n + 1)

/-- A JSON string result. -/
def render (n : Nat) : Eff [] String := pure s!"#{n}"

/-- An independent string-processing branch. -/
def greet (name : String) : Eff [] String := pure s!"Hello, {name}!"

/-- A list is one argument, rather than a batch of calls. -/
def sum (values : List Nat) : Eff [] Nat := pure (values.foldl (· + ·) 0)

/-- A record with generated JSON dictionaries. -/
structure Point where
  x : Int
  y : Int
  deriving Lean.FromJson, Lean.ToJson

/-- An error is a node outcome; a later input can recover it. -/
def norm1 (p : Point) : Eff [Error.Error String] Nat :=
  if p.x == 0 then Error.throwError "x is zero"
  else pure (p.x.natAbs + p.y.natAbs)

/-- Re-evaluation does not necessarily produce a changed output. -/
def cap (n : Nat) : Eff [Trace.Trace] Nat := do
  Trace.trace s!"clamping {n}"
  pure (min n 5)

/-- Emit two values immediately, then a third two minutes later. -/
def delayed (n now : Nat) (state : Option Unit) :
    Eff [] (List Nat × Unit × Option Nat) :=
  match state with
  | none => pure ([n, n + 1], (), some (now + 120000))
  | some () => pure ([n + 2], (), none)

-- ── Scoped effects ──────────────────────────────────────────────────────────

/-- The static file-operation ceiling; runtime binding supplies the directory. -/
abbrev files : FileSystem.Capability :=
  { canRead := true, canWrite := true, canDelete := true }

/-- Write and read a file beneath the bound organization/user temporary root. -/
def writeRead (contents : String) : Eff [FileSystem.FileSystem files] String := do
  FileSystem.writeFileString ["note.txt"] contents
  let value ← FileSystem.readFileString? ["note.txt"]
  pure (value.getD "invalid UTF-8")

/-- Read the same relative file using the current request's user binding. -/
def readNote : Unit → Eff [FileSystem.FileSystem files] String := fun _ => do
  let value ← FileSystem.readFileString? ["note.txt"]
  pure (value.getD "invalid UTF-8")

/-- An anonymous HTTPS capability, separate from credentialed connectors. -/
abbrev web : HTTP.Capability := HTTP.readOnlyWeb

open HTTP in
/-- An optional real public HTTPS request; the cookbook tests denial only. -/
def fetch : Unit → Eff [HTTP.HTTP web] Nat := fun _ => do
  let response ← HTTP.get u!"https://example.org/"
  pure response.statusCode.statusCode

/-- A static native operation/resource ceiling; it contains no credential. -/
abbrev storage : Connector.Capability :=
  { provider := "s3", connection := "conn-1",
    scopes := [{ operation := "objects.read", root := ["reports"] }] }

/-- Brokered native storage needs a matching fresh runtime grant. -/
def report (path : List String) : Eff [Connector.Connector storage] Lean.Json :=
  match Connector.ScopedResource.check? storage "objects.read" path with
  | some resource => Connector.callAt "objects.read" resource
  | none => pure (Lean.Json.str "static scope refused")

end Tutorial
