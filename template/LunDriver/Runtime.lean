/-
  LunDriver.Runtime — written by lun into every driver package; do not edit.

  A *driver* is the Lake package lun generates around a user project: one
  module per declared cell, one per declared DAG, and an executable serving
  them over a stdin/stdout JSON protocol. This module is everything those
  generated modules share:

  - `CellFn σ` — which function types can be cells, and how to call one on JSON
    arguments: `α₁ → … → αₙ → Eff effs β` with every `αᵢ` `Lean.FromJson`, `β`
    `Lean.ToJson`, and `effs` runnable in `IO` (`Handlers effs IO`). A `Unit`
    argument takes no input.
  - `lun_cell "name" := f : r"σ"` — the signature check, stricter than
    elaboration:
    `f` must *be* a function of type `σ` (no coercion), non-dependent, ending in
    `Eff`, whose effects are all linen's vetted ones — `Trace`, `Error`, `HTTP`,
    `FileSystem` — handled by linen's own `Handler _ IO` instances (a project's
    own instance for one of them is refused), and free of `sorry`; then the
    cell's implementation and typed reference.
  - `lun_dag "name" := r#"program"#` — the DAG check: the DAG's definition may
    construct cells, nodes and graphs only through the checked cells, `input`
    and cell application (it is walked through every non-library constant it
    uses), is free of `sorry`, and the graph it builds is well formed, applies
    only declared cells with their arity, and names each input once.
  - Request text (signatures, DAG programs) is embedded as raw string literals
    and parsed as exactly one term each (`parseEmbeddedTerm`), so it can never
    add commands to a generated module; messages still point into it.
  - `driverMain` — the executable's protocol (see its doc comment).
-/
import Lean
import Linen.Control.Reactive
import Linen.Control.Monad.Effect.Handler
import Linen.Control.Monad.Effect.Trace
import Linen.Control.Monad.Effect.Error
import Linen.Control.Monad.Effect.HTTP
import Linen.Control.Monad.Effect.FileSystem

namespace LunDriver

open Lean Control.Monad.Effect Control.Reactive

-- ── Which functions are cells ───────────────────────────────────────────────

/-- A function type a cell can have, and how to call such a function on JSON
    arguments. -/
class CellFn (σ : Type 1) where
  /-- The argument types that take an input (`Unit` arguments do not). -/
  Args : List Type
  /-- The value the cell produces. -/
  Out : Type
  /-- `Args.length`. -/
  arity : Nat
  /-- Call on exactly `arity` JSON arguments; throws on a decoding error, a
      wrong argument count, or the effect's own error. -/
  call : σ → List Json → IO Json

/-- A `Unit` argument takes no input. -/
instance (priority := high) instCellFnUnit {σ : Type 1} [CellFn σ] : CellFn (Unit → σ) where
  Args := CellFn.Args σ
  Out := CellFn.Out σ
  arity := CellFn.arity σ
  call f js := CellFn.call (f ()) js

/-- A JSON-decodable argument takes one input. -/
instance instCellFnArrow {α : Type} {σ : Type 1} [FromJson α] [CellFn σ] : CellFn (α → σ) where
  Args := α :: CellFn.Args σ
  Out := CellFn.Out σ
  arity := CellFn.arity σ + 1
  call f
    | j :: js => do
      match fromJson? j with
      | .ok a => CellFn.call (f a) js
      | .error e => throw (IO.userError s!"cannot decode argument {j.compress}: {e}")
    | [] => throw (IO.userError "missing argument")

/-- The result: an effectful computation over a row runnable in `IO`. -/
instance instCellFnEff {effs : List (Type → Type)} {β : Type} [Handlers effs IO] [ToJson β] :
    CellFn (Eff effs β) where
  Args := []
  Out := β
  arity := 0
  call m
    | [] => toJson <$> m.handle
    | _ => throw (IO.userError "too many arguments")

/-- A checked cell, ready to run: its name, declared signature and JSON entry
    point. -/
structure CellImpl where
  name : String
  signature : String
  arity : Nat
  call : List Json → IO Json

/-- Package a function as a cell. -/
def CellImpl.ofFn {σ : Type 1} [CellFn σ] (name signature : String) (f : σ) : CellImpl :=
  { name, signature, arity := CellFn.arity σ, call := CellFn.call f }

/-- The typed reference a DAG applies. -/
abbrev CellRef (σ : Type 1) [CellFn σ] : Type := Cell (CellFn.Args σ) (CellFn.Out σ)

-- ── The signature check ─────────────────────────────────────────────────────

open Elab Command Term Meta

/-- The effects a cell may use, each with the only `Handler _ IO` instance
    accepted for it (linen's). -/
def allowedEffects : List (Name × Name) :=
  [ (``Control.Monad.Effect.Trace.Trace, ``Control.Monad.Effect.Trace.instHandlerTraceIO)
  , (``Control.Monad.Effect.Error.Error, ``Control.Monad.Effect.Error.instHandlerErrorIO)
  , (``Control.Monad.Effect.HTTP.HTTP, ``Control.Monad.Effect.HTTP.instHandlerHTTPIO)
  , (``Control.Monad.Effect.FileSystem.FileSystem,
      ``Control.Monad.Effect.FileSystem.instHandlerFileSystemIO) ]

/-- The `Handler`/`Handlers` instances a cell's runner may be built from. -/
def allowedInstances : List Name :=
  [``instHandlersNil, ``instHandlersCons] ++ allowedEffects.map Prod.snd

/-- The elements of a list literal, reducing it first if it is not one. -/
def listElems (e : Expr) : MetaM (List Expr) := do
  if let some (_, es) := e.listLit? then return es
  let e' ← Meta.reduce e (skipTypes := false)
  match e'.listLit? with
  | some (_, es) => return es
  | none => throwError "the effect row{indentExpr e}\nis not a list of effects"

/-- Refuse a runner assembled from a `Handler`/`Handlers` instance other than
    the allowed ones. -/
def checkInstance (inst : Expr) : MetaM Unit := do
  for c in (← instantiateMVars inst).getUsedConstants do
    let some info := (← getEnv).find? c | continue
    let concl ← forallTelescope info.type fun _ b => pure b.getAppFn.constName?
    if (concl == some ``Handler || concl == some ``Handlers) && !allowedInstances.contains c then
      throwError "the effect handler `{c}` is not one of linen's; a cell's effects must run \
        with linen's own handlers"

/-- The effect row and result a cell's signature ends in:
    `α₁ → … → αₙ → Eff effs β`, non-dependent. -/
def cellRow (sig : Expr) : MetaM (Expr × Expr) :=
  forallTelescopeReducing sig fun xs body => do
    for h : i in [0:xs.size] do
      let x := xs[i].fvarId!
      let later ← (xs.extract (i + 1) xs.size).mapM inferType
      if body.containsFVar x || later.any (·.containsFVar x) then
        throwError "a cell's signature cannot be a dependent function type"
    unless body.isAppOfArity ``Eff 2 do
      throwError "a cell must return `Eff effs β`, not{indentExpr body}"
    return (body.getArg! 0, body.getArg! 1)

/-- The signature check: `fn` is a cell of signature `sig`. -/
def checkCell (fn : Ident) (sig : Term) : TermElabM Unit := do
  let expected ← elabType sig
  synthesizeSyntheticMVarsNoPostponing
  let expected ← instantiateMVars expected
  if expected.hasMVar then
    throwError "the signature{indentExpr expected}\nis not fully determined"
  let const ← realizeGlobalConstNoOverloadWithInfo fn
  let info ← getConstInfo const
  if info.isUnsafe then throwError "`{const}` is unsafe"
  -- Elaborate the reference against the signature: implicit arguments (a
  -- polymorphic effect row, say) are instantiated by it.
  let e ← elabTermEnsuringType fn expected
  synthesizeSyntheticMVarsNoPostponing
  let e ← instantiateMVars e
  unless ← isDefEq (← inferType e) expected do
    throwError "`{const}` has type{indentExpr info.type}\nwhich is not the declared signature{indentExpr expected}"
  -- …and nothing else: elaboration may not have wrapped it in a coercion.
  let head ← lambdaTelescope e fun _ b => pure b.getAppFn
  unless head.isConstOf const do
    throwError "`{const}` has type{indentExpr info.type}\nwhich only matches the declared signature \
      through a coercion{indentExpr e}"
  let (row, _) ← cellRow expected
  for eff in ← listElems row do
    let some effName := eff.getAppFn.constName?
      | throwError "the effect{indentExpr eff}\nis not a named effect"
    let some (_, instName) := allowedEffects.find? (·.1 == effName)
      | throwError "the effect `{effName}` is not allowed in a cell; allowed: \
          {allowedEffects.map (·.1)}"
    let inst ← synthInstance (mkApp2 (mkConst ``Handler) eff (mkConst ``IO))
    unless inst.getAppFn.isConstOf instName do
      throwError "the effect `{effName}` resolves to the handler{indentExpr inst}\nnot linen's \
        `{instName}`"
  checkInstance (← synthInstance (mkApp2 (mkConst ``Handlers) row (mkConst ``IO)))
  if (← collectAxioms const).contains ``sorryAx then
    throwError "`{const}` depends on `sorry`"

-- ── Embedded source text ────────────────────────────────────────────────────

/-- Relocate syntax parsed from a string to where that string's content starts
    in the current file, so messages point into the embedded text. -/
def relocate (offset : Nat) (stx : Syntax) : Syntax :=
  let shift (i : SourceInfo) : SourceInfo :=
    match i.getPos?, i.getTailPos? with
    | some p, some q => .synthetic ⟨p.byteIdx + offset⟩ ⟨q.byteIdx + offset⟩
    | _, _ => i
  stx.rewriteBottomUp fun
    | .atom i v => .atom (shift i) v
    | .ident i r v p => .ident (shift i) r v p
    | .node i k as => .node (shift i) k as
    | .missing => .missing

/-- Parse a raw string literal's content as exactly one term, positioned in the
    current file. Request text is embedded this way so it can never be anything
    but the one term it stands for. -/
def parseEmbeddedTerm (lit : StrLit) : CommandElabM Term := do
  let text := lit.getString
  -- The content starts after the opening delimiter (`r#…#"`).
  let delim := match lit.raw with
    | .node _ _ #[.atom _ v] => (v.takeWhile (· != '"')).toString.length + 1
    | _ => 0
  let offset := (lit.raw.getPos?.map (·.byteIdx)).getD 0 + delim
  match Parser.runParserCategory (← getEnv) `term text with
  | .ok stx => pure ⟨relocate offset stx⟩
  | .error e => throwErrorAt lit "cannot parse: {e}"

/-- A dotted name, as a Lean name. -/
def dottedName (s : String) : Name :=
  (s.splitOn ".").foldl Name.mkStr .anonymous

/-- `lun_cell "name" := f : r"σ"` — check that `f` is a cell of signature `σ`
    (see the module documentation), then define its implementation
    `LunDriver.Impl.name` and its typed reference `LunDriver.Cells.name`. -/
elab "lun_cell " name:str " := " fn:ident " : " sig:str : command => do
  let sigStx ← parseEmbeddedTerm sig
  liftTermElabM (checkCell fn sigStx)
  let n := dottedName name.getString
  let sigId := mkIdent (`LunDriver.Sig ++ n)
  let implId := mkIdent (`LunDriver.Impl ++ n)
  let cellId := mkIdent (`LunDriver.Cells ++ n)
  let sigText := Syntax.mkStrLit sig.getString
  elabCommand (← `(abbrev $sigId : Type 1 := $sigStx))
  elabCommand (← `(def $implId : LunDriver.CellImpl :=
    LunDriver.CellImpl.ofFn $name $sigText ($fn : $sigId)))
  elabCommand (← `(def $cellId : LunDriver.CellRef $sigId := ⟨$name⟩))

-- ── The DAG check ───────────────────────────────────────────────────────────

/-- Constructors a DAG may only reach through `input`, cell application and
    the checked cells. -/
def bannedInDag : List Name :=
  [ ``Cell.mk, ``Graph.mk, ``Node.input, ``Node.apply, ``Reactive.applyNode, ``Cell.applyAux
  , ``Signal.mk ]

/-- Library modules, whose constants are trusted and not walked. -/
def trustedModule (m : Name) : Bool :=
  [`Init, `Std, `Lean, `Linen].contains m.getRoot || m == `LunDriver.Runtime

/-- What is wrong with a graph as a DAG of the declared cells, if anything:
    it must be well formed, apply only declared cells with their arity, and
    name each input once. `cells` maps each declared cell to its arity. -/
def validateGraph (cells : List (String × Nat)) (g : Graph) : Except String Unit := do
  unless decide g.WellFormed do throw "the graph reads a node before it is defined"
  let mut seen : List String := []
  for h : i in [0:g.nodes.size] do
    match g.nodes[i] with
    | .input name =>
      if seen.contains name then throw s!"the input '{name}' is declared twice"
      seen := name :: seen
    | .apply cell args =>
      match cells.lookup cell with
      | none => throw s!"node {i} applies '{cell}', which is not a declared cell"
      | some n =>
        unless args.length == n do
          throw s!"node {i} applies '{cell}' to {args.length} arguments; it takes {n}"

unsafe def evalGraphUnsafe (n : Name) : TermElabM Graph := evalConst Graph n
@[implemented_by evalGraphUnsafe] opaque evalGraph (n : Name) : TermElabM Graph

unsafe def evalCellsUnsafe (n : Name) : TermElabM (List (String × Nat)) :=
  evalConst (List (String × Nat)) n
@[implemented_by evalCellsUnsafe] opaque evalCells (n : Name) : TermElabM (List (String × Nat))

/-- The cell references the driver generated: a `CellRef` in `LunDriver.Cells`,
    defined by one of the generated `LunDriver.Cells.*` modules. -/
def isCellRef (env : Environment) (c : Name) : Bool :=
  let generated := match env.getModuleIdxFor? c with
    | some idx => (`LunDriver.Cells).isPrefixOf (env.header.moduleNames[idx.toNat]!)
    | none => false
  generated && (`LunDriver.Cells).isPrefixOf c &&
    ((env.find? c).map (·.type.getAppFn.isConstOf ``CellRef)).getD false

/-- The DAG check: the definition `dagName` builds only with checked cells
    (see the module documentation), and the graph `graphName` it builds is
    valid for the declared cells' arities `cells`. -/
def checkDag (dagName graphName cellsName : Name) : TermElabM Unit := do
  let env ← getEnv
  if (← collectAxioms dagName).contains ``sorryAx then throwError "the DAG depends on `sorry`"
  -- Walk every constant the definition reaches, through everything that is
  -- not library code, stopping at the generated cell references.
  let trusted (c : Name) : Bool := match env.getModuleIdxFor? c with
    | some idx => trustedModule (env.header.moduleNames[idx.toNat]!)
    | none => false
  let mut todo : List Name := [dagName]
  let mut seen : NameSet := {}
  -- A bound, not fuel: no DAG definition reaches a million constants.
  for _ in [0:1000000] do
    match todo with
    | [] => break
    | c :: rest =>
      todo := rest
      if seen.contains c then continue
      seen := seen.insert c
      let some info := env.find? c | continue
      if info.isUnsafe then throwError "the DAG uses the unsafe `{c}`"
      let some v := info.value? (allowOpaque := true) | continue
      for u in v.getUsedConstants ++ info.type.getUsedConstants do
        if bannedInDag.contains u then
          throwError "the DAG uses `{u}` (in `{c}`); a DAG may build nodes only with `input` \
            and the declared cells"
        unless trusted u || isCellRef env u || seen.contains u do
          todo := u :: todo
  unless todo.isEmpty do throwError "the DAG is too large to check"
  match validateGraph (← evalCells cellsName) (← evalGraph graphName) with
  | .ok () => pure ()
  | .error e => throwError "invalid DAG: {e}"

/-- `lun_dag "name" := r#"program"#` — define the DAG `LunDriver.Dags.name`
    from a `Reactive` program over the declared cells (and its graph,
    `LunDriver.Graphs.name`), then check it. -/
elab "lun_dag " name:str " := " prog:str : command => do
  let t ← parseEmbeddedTerm prog
  let n := dottedName name.getString
  let dagName := `LunDriver.Dags ++ n
  let graphName := `LunDriver.Graphs ++ n
  let dagId := mkIdent dagName
  let graphId := mkIdent graphName
  let before := (← get).messages.toList.length
  elabCommand (← `(def $dagId : Control.Reactive.Reactive Unit := Functor.discard ($t)))
  -- An ill-typed program is already reported; checking its error-recovery
  -- stand-in would only add a spurious `sorry`.
  if (← get).messages.toList.drop before |>.any (·.severity == .error) then return
  elabCommand (← `(def $graphId : Control.Reactive.Graph := Control.Reactive.Reactive.graph $dagId))
  withRef prog <| liftTermElabM (checkDag dagName graphName `LunDriver.cellArities)

-- ── The protocol ────────────────────────────────────────────────────────────

/-- The arguments of one call, from its input: nothing for a cell of no
    inputs, the value itself for one input, a JSON array of `arity` values
    otherwise. -/
def argsOf (arity : Nat) (input : Option Json) : Except String (List Json) :=
  match arity, input with
  | 0, _ => .ok []
  | 1, some j => .ok [j]
  | n, some (.arr js) =>
    if js.size == n then .ok js.toList else .error s!"expected an array of {n} arguments"
  | 1, none => .error "missing input"
  | n, _ => .error s!"expected an array of {n} arguments"

/-- `{"output": v}` or `{"error": message}`. -/
def outcomeJson (r : Except String Json) : Json :=
  match r with
  | .ok v => Json.mkObj [("output", v)]
  | .error e => Json.mkObj [("error", e)]

/-- Run a cell, turning every failure into an `Except`. -/
def CellImpl.run (c : CellImpl) (input : Option Json) : IO (Except String Json) := do
  match argsOf c.arity input with
  | .error e => pure (.error e)
  | .ok args =>
    try pure (.ok (← c.call args)) catch e => pure (.error (toString e))

/-- A cell request: `{"input": x}` (one call; omitted for a cell of no
    inputs) or `{"inputs": [x₁, x₂, …]}` (one call per element). -/
def runCell (c : CellImpl) (req : Json) : IO (Except String Json) := do
  match req.getObjVal? "inputs" with
  | .ok (.arr xs) =>
    let outs ← xs.mapM fun x => outcomeJson <$> c.run (some x)
    pure (.ok (Json.mkObj [("outputs", Json.arr outs)]))
  | .ok _ => pure (.error "\"inputs\" must be an array")
  | .error _ =>
    let input := (req.getObjVal? "input").toOption
    pure (.ok (outcomeJson (← c.run input)))

/-- One node, for `describe` and DAG results. -/
def nodeJson (i : Nat) : Node → List (String × Json)
  | .input name => [("id", i), ("input", name)]
  | .apply cell args => [("id", i), ("cell", cell), ("args", toJson args)]

/-- A DAG request: `{"inputs": {"name": value, …}}`. The result has one entry
    per node, in order, with its `output`, its own `error`, or the node it was
    `skipped` because of. -/
def runDag (cells : List CellImpl) (g : Graph) (req : Json) : IO (Except String Json) := do
  let inputs := (req.getObjVal? "inputs").toOption.getD (Json.mkObj [])
  let outcomes ← g.evalM (fun name => (inputs.getObjVal? name).toOption) fun cell vs => do
    match cells.find? (·.name == cell) with
    | none => pure (.error s!"unknown cell '{cell}'")
    | some c => try pure (.ok (← c.call vs)) catch e => pure (.error (toString e))
  let nodes := (List.range g.size).map fun i =>
    let node := (g.node? i).getD default
    let result : List (String × Json) := match outcomes[i]? with
      | some (.value v) => [("output", v)]
      | some (.failed e) => [("error", e)]
      | some (.skipped j) => [("skipped", j)]
      | none => []
    Json.mkObj (nodeJson i node ++ result)
  pure (.ok (Json.mkObj [("nodes", Json.arr nodes.toArray)]))

/-- The build's cells and DAGs, with each DAG's structure. -/
def describe (cells : List CellImpl) (dags : List (String × Graph)) : Json :=
  Json.mkObj
    [ ("cells", Json.arr (cells.map fun c => Json.mkObj
        [("name", c.name), ("signature", c.signature), ("arity", c.arity)]).toArray)
    , ("dags", Json.arr (dags.map fun (name, g) => Json.mkObj
        [ ("name", name)
        , ("nodes", Json.arr ((List.range g.size).map fun i =>
            Json.mkObj (nodeJson i ((g.node? i).getD default))).toArray)
        , ("sources", toJson g.sources)
        , ("sinks", toJson g.sinks) ]).toArray) ]

/-- The driver's protocol. One JSON request on stdin, one JSON response on
    stdout; cells' traces go to stderr.

    - `describe` — the cells and DAGs (no stdin).
    - `cell NAME` — a cell request (`runCell`).
    - `dag NAME` — a DAG request (`runDag`).

    Exit code `0` for a response (which may report per-call errors), `1` for a
    request that could not be served (`{"error": …}` on stdout), `2` for a bad
    command line. -/
def driverMain (cells : List CellImpl) (dags : List (String × Graph)) (args : List String) :
    IO UInt32 := do
  let respond (r : Except String Json) : IO UInt32 := do
    match r with
    | .ok j => IO.println j.compress; pure 0
    | .error e => IO.println (Json.mkObj [("error", e)]).compress; pure 1
  let request : IO (Except String Json) := do
    let text ← (← IO.getStdin).readToEnd
    pure (if text.trimAscii.isEmpty then .ok (Json.mkObj []) else Json.parse text)
  match args with
  | ["describe"] => respond (.ok (describe cells dags))
  | ["cell", name] =>
    match cells.find? (·.name == name) with
    | none => respond (.error s!"no cell named '{name}'")
    | some c => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runCell c req)
  | ["dag", name] =>
    match dags.lookup name with
    | none => respond (.error s!"no DAG named '{name}'")
    | some g => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runDag cells g req)
  | _ =>
    IO.eprintln "usage: lun-driver (describe | cell NAME | dag NAME)"
    pure 2

end LunDriver
