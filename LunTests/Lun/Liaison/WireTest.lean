/-
  Tests for `Lun.Liaison.Wire`: the grant is read off the warrant's caveats,
  the egress body is liaison's format, and liaison's answers and refusals are
  read back.
-/
import Lun.Liaison.Wire

open Lean (Json)
open Lun.Liaison

namespace LunTests.Liaison.Wire

/-- A warrant as the app mints it (caveats most recent first). -/
def warrant : Json := Json.mkObj
  [ ("id", "w-1"), ("orgId", "org-1"), ("tag", "00")
  , ("caveats", Json.arr #[
      Json.mkObj [("kind", "runId"), ("value", "run-1")],
      Json.mkObj [("kind", "budget"), ("value", "0")],
      Json.mkObj [("kind", "resource"), ("value", "conn-1")],
      Json.mkObj [("kind", "capability"), ("provider", "github"), ("action", "read")],
      Json.mkObj [("kind", "expiresAt"), ("value", "1790000000")]]) ]

def grant : Grant :=
  { orgId := "org-1", runId := "run-1", provider := "github", action := "read", resource := "conn-1" }

#guard (Grant.ofWarrant warrant).toOption == some grant
#guard (Grant.ofWarrant (Json.mkObj [("orgId", "o"), ("caveats", Json.arr #[])])).toOption.isNone
#guard (Grant.ofWarrant (Json.mkObj [("caveats", Json.arr #[])])).toOption.isNone

#guard validAccount "user-1/conn-1" grant
#guard !validAccount "user-1/conn-2" grant       -- not the warrant's resource
#guard !validAccount "conn-1" grant
#guard !validAccount "a/b/conn-1" grant
#guard !validAccount "u?x/conn-1" grant

-- The body carries the warrant verbatim and derives every other field from it.
def body : Json := egressBody warrant grant "user-1/conn-1" 1700000000
  "https://api.github.com/repos/o/r/tarball/abc" [("accept", "application/vnd.github+json")]

#guard (body.getObjValAs? String "now").toOption == some "1700000000"
#guard (body.getObjValAs? String "cost").toOption == some "0"
#guard (body.getObjValAs? String "provider").toOption == some "github"
#guard (body.getObjValAs? String "resource").toOption == some "conn-1"
#guard (body.getObjValAs? String "runId").toOption == some "run-1"
#guard (body.getObjValAs? String "orgId").toOption == some "org-1"
#guard (body.getObjVal? "warrant").toOption == some warrant
#guard ((body.getObjVal? "call").toOption.bind (·.getObjValAs? String "method" |>.toOption)) == some "GET"
#guard ((body.getObjVal? "call").toOption.bind (·.getObjValAs? String "account" |>.toOption)) ==
  some "user-1/conn-1"

-- ── Responses ───────────────────────────────────────────────────────────────

def relayed : String :=
  "{\"status\": 302, \"headers\": {\"Location\": \"https://codeload.github.com/x\"}, \"body\": \"6869\"}"

#guard (parseResponse 200 relayed).toOption.map (·.status) == some 302
#guard (parseResponse 200 relayed).toOption.bind (·.header? "location") ==
  some "https://codeload.github.com/x"
#guard (parseResponse 200 relayed).toOption.map (·.body.toList) == some [0x68, 0x69]
#guard (parseResponse 403 "{\"error\": \"tag_invalid\"}") matches .error _
#guard match parseResponse 403 "{\"error\": \"tag_invalid\"}" with
  | .error e => (e.splitOn "tag_invalid").length > 1
  | .ok _ => false
#guard (parseResponse 200 "not json") matches .error _
#guard (parseResponse 200 "{\"status\": 200, \"body\": \"zz\"}") matches .error _

end LunTests.Liaison.Wire
