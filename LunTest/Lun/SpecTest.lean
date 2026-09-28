/-
  Tests for `Lun.Spec`: a well-formed request parses; each malformed field is
  refused with a message naming it; credentials must match the host; the
  canonical form omits credentials.
-/
import Lun.Spec

open Lean (Json)
open Lun

namespace LunTests.Spec

def commit := "dc19b371d09f409810678d8b35dbb381afecf272"

def function (name : String := "math.double") (fn : String := "P.double") : Json := Json.mkObj
  [("name", name), ("module", "P.Math"), ("function", fn), ("signature", "Nat → Eff [] Nat")]

def request (source : List (String × Json) := []) (functions : List Json := [function])
    (graphs : List Json := []) (extra : List (String × Json) := []) : Json :=
  Json.mkObj <|
    [ ("source", Json.mkObj (([("url", "https://github.com/o/r"), ("branch", "main"),
        ("commit", commit)] : List (String × Json)) ++ source))
    , ("functions", Json.arr functions.toArray), ("graphs", Json.arr graphs.toArray) ] ++ extra

def err (j : Json) (allowLocal := false) : String :=
  match BuildSpec.parse j allowLocal with
  | .ok _ => "ok"
  | .error e => e

/-- The error mentions `s`. -/
def mentions (j : Json) (s : String) : Bool := ((err j).splitOn s).length > 1

#guard err (request) == "ok"
#guard ((BuildSpec.parse (request (graphs := [Json.mkObj [("name", "main"), ("program", "do\n  pure ()")]]))).toOption.map
  (·.graphs.length)) == some 1
#guard (BuildSpec.parse (request (extra := [("open", Json.arr #["P"])]))).toOption.map (·.opens) == some ["P"]
#guard (BuildSpec.parse (request (source := [("path", "lean")]))).toOption.map (·.source.path) == some "lean"

-- Each field is validated, and the message says which.
#guard mentions (Json.mkObj []) "source"
#guard mentions (request (source := [("commit", "abc")])) "source.commit"
#guard mentions (request (source := [("branch", "-x")])) "source.branch"
#guard mentions (request (source := [("path", "../x")])) "source.path"
#guard mentions (request (source := [("url", "ssh://github.com/o/r")])) "source.url"
#guard mentions (request (functions := [])) "at least one function"
#guard mentions (request (functions := [function "bad name"])) "functions[0].name"
#guard mentions (request (functions := [function (fn := "a b")])) "functions[0].function"
#guard mentions (request (functions := [function, function])) "declared twice"
#guard mentions (request (functions := [Json.mkObj [("name", "x"), ("module", "M"), ("function", "f"),
  ("signature", "Nat\n→ Nat")]])) "signature"
#guard mentions (request (graphs := [Json.mkObj [("name", "d"), ("program", 3)]])) "graphs[0].program"
#guard mentions (request (extra := [("open", Json.arr #["a b"])])) "open"
#guard mentions (request (source := [("url", "file:///tmp/r")])) "local mode"
#guard err (request (source := [("url", "file:///tmp/r")])) (allowLocal := true) == "ok"

-- ── Credentials ─────────────────────────────────────────────────────────────

/-- A warrant as the app mints it (caveats most recent first). -/
def warrant (provider : String := "github") : Json := Json.mkObj
  [ ("id", "w-1"), ("orgId", "org-1"), ("tag", "ab01"), ("caveats", Json.arr #[
      Json.mkObj [("kind", "runId"), ("value", "run-1")],
      Json.mkObj [("kind", "budget"), ("value", "0")],
      Json.mkObj [("kind", "resource"), ("value", "conn-1")],
      Json.mkObj [("kind", "capability"), ("provider", provider), ("action", "read")],
      Json.mkObj [("kind", "expiresAt"), ("value", "1790000000")]]) ]

/-- `warrant` with one field replaced. -/
def warrantWith (k : String) (v : Json) : Json := (warrant).setObjVal! k v

def creds (w : Json) (account : String := "user-1/conn-1") : Json :=
  Json.mkObj [("warrant", w), ("account", account)]

#guard err (request (source := [("credentials", creds (warrant))])) == "ok"
#guard mentions (request (source := [("credentials", creds (warrant "gitlab"))])) "the warrant is for 'gitlab'"
#guard mentions (request (source := [("credentials", creds (warrant) "user-1/other")])) "account"
#guard mentions (request (source := [("url", "https://example.org/o/r"), ("credentials", creds (warrant))]))
  "only usable for github.com and gitlab.com"
-- The warrant is decoded as liaison decodes it (`Liaison.Wire`): what liaison
-- would refuse as malformed is refused here, before any fetch.
#guard mentions (request (source := [("credentials", creds (warrantWith "tag" "xyz"))]))
  "source.credentials.warrant.tag"
#guard mentions (request (source := [("credentials", creds (warrantWith "id" 1))]))
  "source.credentials.warrant.id"
#guard mentions (request (source := [("credentials", creds (warrantWith "caveats" (Json.arr #[
    Json.mkObj [("kind", "sudo"), ("value", "x")]])))])) "unknown caveat kind"
#guard mentions (request (source := [("credentials", creds (warrantWith "caveats" (Json.arr #[
    Json.mkObj [("kind", "resource"), ("value", "conn-1")],
    Json.mkObj [("kind", "runId"), ("value", "run-1")]])))])) "no capability caveat"

-- What lun forwards to liaison is the warrant it was given.
#guard match BuildSpec.parse (request (source := [("credentials", creds (warrant))])) with
  | .ok { source := { credentials := some c, .. }, .. } =>
    (Json.parse (Data.Json.Encode.encode (Liaison.Wire.encodeWarrant c.warrant))).toOption == some (warrant)
  | _ => false

-- The canonical form never carries credentials, and is what an id is computed from.
#guard match BuildSpec.parse (request (source := [("credentials", creds (warrant))])) with
  | .ok s => ((s.canonical.getObjVal? "source").toOption.bind (·.getObjVal? "credentials" |>.toOption)).isNone
  | .error _ => false
#guard match BuildSpec.parse (request (source := [("credentials", creds (warrant))])), BuildSpec.parse (request) with
  | .ok a, .ok b => a.canonical.compress == b.canonical.compress
  | _, _ => false

#guard firstDuplicate ["a", "b", "a"] == some "a"
#guard firstDuplicate ["a", "b"] == none

end LunTests.Spec
