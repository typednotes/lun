/-
  Examples.Client — lun, end to end, from a client's side:
  `lake exe lun-example --repo URL --commit SHA [options]`.

  It asks a running lun to build the pricing project (`Examples/pricing`),
  registers its `invoice` graph as a **session**, then updates one input at a
  time and prints what each update changed — and, from the functions' traces,
  which functions ran: only those downstream of the input that changed.

  ```
  lines ──► subtotal ──► discounted ──┬──► shipping ──┐
                                code ─┘ ├──► vat ─────┤
                             country ───┴─────────────┴──► total ──► euros
  ```

  Options:

  - `--lun URL` — lun's base URL (default `http://127.0.0.1:8080`);
  - `--token T` — lun's bearer token (default `$LUN_TOKEN`);
  - `--repo URL`, `--commit SHA` — the repository holding the project, and
    the commit (full hash) to build;
  - `--branch B` (default `main`), `--path P` (default `Examples/pricing`);
  - `--dot FILE` — also write the graph, after the last update, as Graphviz
    (inputs as ellipses, functions as boxes, what the update changed filled).

  `Examples/run.sh` starts a local lun and runs this against a local copy of
  the project; against a deployed lun, point `--repo` at the pushed
  repository (`https://github.com/typednotes/lun`, path `Examples/pricing`).
-/
import Lean.Data.Json
import Linen.Network.HTTP.Simple

namespace Examples.Client

open Lean (Json toJson)
open Network.HTTP.Client (Request)
open Network.HTTP.Types

-- ── The request ─────────────────────────────────────────────────────────────

/-- The functions of the pricing project, under the names the graph uses. -/
def functions : Json := Json.arr <| #[
    ("subtotal", "List Pricing.Line → Eff [Trace.Trace] Nat"),
    ("discounted", "Nat → String → Eff [Trace.Trace, Error.Error String] Nat"),
    ("shipping", "Nat → String → Eff [Trace.Trace, Error.Error String] Nat"),
    ("vat", "Nat → String → Eff [Trace.Trace, Error.Error String] Nat"),
    ("total", "Nat → Nat → Nat → Eff [Trace.Trace] Nat"),
    ("euros", "Nat → Eff [] String")].map fun (name, signature) =>
  Json.mkObj [ ("name", toJson name), ("module", "Pricing.Invoice")
             , ("function", toJson s!"Pricing.{name}"), ("signature", toJson signature) ]

/-- The invoice graph: a program in linen's `Reactive` monad over the
    functions, each applying to observables. -/
def invoice : String := "do
  let lines ← input \"lines\" (List Pricing.Line)
  let code ← input \"code\" String
  let country ← input \"country\" String
  let sub ← subtotal lines
  let net ← discounted sub code
  let ship ← shipping net country
  let tax ← vat net country
  let due ← total net ship tax
  euros due"

/-- The build request. -/
def buildRequest (repo branch commit path : String) : Json :=
  Json.mkObj
    [ ("source", Json.mkObj [ ("url", toJson repo), ("branch", toJson branch)
                            , ("commit", toJson commit), ("path", toJson path) ])
    , ("functions", functions)
    , ("graphs", Json.arr #[Json.mkObj [("name", "invoice"), ("program", toJson invoice)]]) ]

/-- A line of the invoice, as JSON. -/
def line (sku : String) (quantity unitPrice : Nat) : Json :=
  Json.mkObj [("sku", toJson sku), ("quantity", toJson quantity), ("unitPrice", toJson unitPrice)]

/-- The inputs a session starts with, then the updates, each with what it
    shows. -/
def start : Json := Json.mkObj
  [ ("lines", Json.arr #[line "notebook" 3 1200, line "pen" 10 250])
  , ("code", ""), ("country", "FR") ]

def updates : List (String × Json) :=
  [ ("ship to Germany instead", Json.mkObj [("country", "DE")])
  , ("a code that does not exist", Json.mkObj [("code", "SUMMER")])
  , ("a real one", Json.mkObj [("code", "VIP")])
  , ("the same country again: nothing to do", Json.mkObj [("country", "DE")])
  , ("a bigger order: free shipping", Json.mkObj
      [("lines", Json.arr #[line "notebook" 3 1200, line "pen" 10 250, line "lamp" 1 8900])]) ]

-- ── HTTP ────────────────────────────────────────────────────────────────────

/-- Where lun is, and how to talk to it. -/
structure Lun where
  base : String
  token : Option String

/-- Call lun: the status and the JSON body. -/
def Lun.call (l : Lun) (method : StdMethod) (path : String) (body : Option Json := none) :
    IO (Nat × Json) := do
  let req ← Network.HTTP.Simple.parseUrl! (l.base ++ path)
  let auth := (l.token.map fun t => [(Data.CI.mk' "Authorization", s!"Bearer {t}")]).getD []
  let req : Request := { req with
    method := .standard method
    headers := (Data.CI.mk' "Content-Type", "application/json") :: auth
    body := body.map (·.compress.toUTF8)
    timeoutMillis := 600000 }
  let resp ← Network.HTTP.Simple.httpBS req
  let text := (String.fromUTF8? resp.body).getD ""
  match Json.parse text with
  | .ok j => pure (resp.statusCode.statusCode, j)
  | .error _ => throw (IO.userError s!"lun answered {resp.statusCode.statusCode}: {text}")

/-- A call that must answer one of `ok`. -/
def Lun.expect (l : Lun) (ok : List Nat) (method : StdMethod) (path : String)
    (body : Option Json := none) : IO Json := do
  let (status, j) ← l.call method path body
  unless ok.contains status do
    throw (IO.userError s!"{path}: {status} {(j.getObjValAs? String "error").toOption.getD j.compress}")
  pure j

-- ── Printing ────────────────────────────────────────────────────────────────

/-- A node's name: its input's, or its function's. -/
def nodeName (n : Json) : String :=
  match n.getObjValAs? String "input", n.getObjValAs? String "function" with
  | .ok i, _ => i
  | _, .ok f => f
  | _, _ => "?"

/-- A node's outcome, briefly. -/
def outcome (nodes : Array Json) (n : Json) : String :=
  match n.getObjVal? "output", n.getObjValAs? String "error", n.getObjValAs? Nat "skipped" with
  | .ok v, _, _ => match v with
    | .arr xs => s!"{xs.size} lines"
    | v => v.compress
  | _, .ok e, _ => s!"error: {e}"
  | _, _, .ok j => s!"skipped ({(nodes[j]?.map nodeName).getD "?"} has no value)"
  | _, _, _ => "—"

/-- Print nodes, one per line. -/
def printNodes (nodes : Array Json) (shown : Array Json) : IO Unit := do
  if shown.isEmpty then IO.println "    (nothing changed)"
  for n in shown do
    IO.println s!"    {(nodeName n).pushn ' ' (12 - (nodeName n).length)}{outcome nodes n}"

/-- The functions that ran, from their traces (`name: …`). -/
def ran (answer : Json) : List String :=
  let log := (answer.getObjValAs? String "log").toOption.getD ""
  ((log.splitOn "\n").filterMap fun l => (l.splitOn ":").head?.map (·.trimAscii.toString)
    |>.filter (!·.isEmpty)).eraseDups

-- ── Graphviz ────────────────────────────────────────────────────────────────

/-- Lines as a DOT double-quoted string (`\n` between them). -/
def dotString (lines : List String) : String :=
  let esc (s : String) := (s.replace "\\" "\\\\").replace "\"" "\\\""
  "\"" ++ "\\n".intercalate (lines.map esc) ++ "\""

/-- The graph as Graphviz, titled `title`: every node with its outcome, the
    ids in `changed` filled. -/
def dot (title : String) (nodes : Array Json) (changed : List Nat) : String :=
  let decl (n : Json) : String :=
    let id := (n.getObjValAs? Nat "id").toOption.getD 0
    let isInput := (n.getObjVal? "input").toOption.isSome
    let fill := if changed.contains id then "#f5c451" else if isInput then "#e8e4f7" else "#ffffff"
    s!"  n{id} [label={dotString [nodeName n, outcome nodes n]}, shape={if isInput then "ellipse" else "box"}, fillcolor=\"{fill}\"];"
  let edges (n : Json) : List String :=
    let id := (n.getObjValAs? Nat "id").toOption.getD 0
    ((n.getObjValAs? (List Nat) "args").toOption.getD []).map fun a => s!"  n{a} -> n{id};"
  "\n".intercalate <|
    [ "digraph invoice {", "  rankdir=LR;", s!"  label={dotString [title]}; labelloc=b;"
    , "  fontname=\"Helvetica\"; fontsize=12; fontcolor=\"#3b2f7a\"; bgcolor=\"white\"; pad=0.3;"
    , "  node [style=\"rounded,filled\", fontname=\"Helvetica\", color=\"#3b2f7a\", fontcolor=\"#1e1840\"];"
    , "  edge [color=\"#3b2f7a\"];" ] ++
    nodes.toList.map decl ++ nodes.toList.flatMap edges ++ ["}", ""]

-- ── Main ────────────────────────────────────────────────────────────────────

/-- The value of `--flag`, if given. -/
def flag (args : List String) (name : String) : Option String :=
  match args.dropWhile (· != name) with
  | _ :: v :: _ => some v
  | _ => none

def main (args : List String) : IO UInt32 := do
  let some repo := flag args "--repo" | IO.eprintln "--repo URL is required"; return 2
  let some commit := flag args "--commit" | IO.eprintln "--commit SHA is required"; return 2
  let token ← match flag args "--token" with
    | some t => pure (some t)
    | none => IO.getEnv "LUN_TOKEN"
  let lun : Lun := { base := (flag args "--lun").getD "http://127.0.0.1:8080", token }
  let branch := (flag args "--branch").getD "main"
  let path := (flag args "--path").getD "Examples/pricing"

  -- 1. Build: fetch the project, check every function's signature and the
  --    graph, compile. Asking again for the same build returns it.
  IO.println s!"building {repo} at {commit.take 12} ({path})…"
  let mut status ← lun.expect [200, 202] .POST "/v0/builds" (buildRequest repo branch commit path)
  let id := (status.getObjValAs? String "id").toOption.getD ""
  repeat
    let state := (status.getObjValAs? String "state").toOption.getD ""
    if state == "ready" || state == "failed" then break
    IO.sleep 2000
    status ← lun.expect [200] .GET s!"/v0/builds/{id}"
  unless (status.getObjValAs? String "state").toOption == some "ready" do
    IO.eprintln s!"the build failed: {status.pretty}"
    return 1
  IO.println s!"ready: build {id.take 12}…\n"

  -- 2. Register the graph as a session, with its first inputs.
  let s ← lun.expect [201] .POST s!"/v0/builds/{id}/graphs/invoice/sessions"
    (Json.mkObj [("inputs", start)])
  let session := (s.getObjValAs? String "session").toOption.getD ""
  let mut nodes := (s.getObjValAs? (Array Json) "nodes").toOption.getD #[]
  IO.println s!"▸ start {start.compress}"
  printNodes nodes (nodes.filter fun n => (n.getObjVal? "function").toOption.isSome)
  IO.println s!"    ran: {", ".intercalate (ran s)}\n"

  -- 3. Update inputs, one change at a time: only what changed comes back.
  let mut lastChanged : List Nat := []
  for (what, inputs) in updates do
    let u ← lun.expect [200] .POST s!"/v0/sessions/{session}" (Json.mkObj [("inputs", inputs)])
    nodes := (u.getObjValAs? (Array Json) "nodes").toOption.getD nodes
    let changed := (u.getObjValAs? (Array Json) "changed").toOption.getD #[]
    lastChanged := changed.toList.filterMap fun n => (n.getObjValAs? Nat "id").toOption
    IO.println s!"▸ {what}: {inputs.compress}"
    printNodes nodes changed
    let r := ran u
    IO.println s!"    ran: {if r.isEmpty then "nothing" else ", ".intercalate r}\n"
    if let some file := flag args "--dot" then
      if what.startsWith "ship to Germany" then
        IO.FS.writeFile file (dot s!"after {inputs.compress}: what changed is filled" nodes lastChanged)

  -- 4. The session stays until it is ended.
  discard <| lun.expect [200] .DELETE s!"/v0/sessions/{session}"
  IO.println "session ended"
  return 0

end Examples.Client

def main (args : List String) : IO UInt32 := Examples.Client.main args
