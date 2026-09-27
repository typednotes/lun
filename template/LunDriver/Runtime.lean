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
  - `lun_dag "name" := r#"program"#` — a DAG: a program in linen's
    `Reactive IO Json` monad (`Control.Reactive`) over `input`s and the cells,
    each cell applying like a function of observables (a `combineLatest` over
    the cell). The check: the program is free of `sorry` and of the builder's
    primitives (it is walked through every non-library constant it uses), and
    the graph it builds consists of inputs and applications of declared cells
    with their arity, nothing else (`Dag.ofGraph`). Every function of the
    graph is then replaced by the declared cell its label names, so what runs
    is only ever a declared, checked cell.
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

/-- The cell as a function linen's reactive graphs can call: its arguments
    are the node's sources, in order (a cell of no inputs reads one start
    source, whose value it ignores). A failure is the node's `error`. -/
def CellImpl.impl (c : CellImpl) : Impl IO Json := fun vs => do
  try pure (.ok (some (← c.call (if c.arity == 0 then [] else vs))))
  catch e => pure (.error (toString e))

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

-- ── DAGs: inputs and cells as operators ─────────────────────────────────────

/-- The monad a DAG is written in: linen's reactive graphs, over JSON values,
    running cells in `IO`. -/
abbrev DagM : Type → Type := Reactive IO Json

/-- The first component of every input's label. Not a valid identifier, so
    no cell or input name can be mistaken for it. -/
def inputMarker : String := "#input"

/-- The first component of the scope every cell application is built in. -/
def cellMarker : String := "#cell"

/-- The label of input `name`: `«#input».«name»` (after any enclosing
    `scope`). -/
def inputLabel (name : String) : Name := .str (.str .anonymous inputMarker) name

/-- The scope an application of cell `name` is built in. -/
def cellScope (name : String) : Name := .str (.str .anonymous cellMarker) name

/-- The input a subject's label names, if it is an input's. -/
def inputOfLabel : Name → Option String
  | .str (.str _ m) n => if m == inputMarker then some n else none
  | _ => none

/-- The cell a generated label belongs to, if it was generated inside a cell
    application: `…«#cell».«name».kind.k`, `kind` being `fn` for the cell's
    function and `subject` for the start source of a cell of no inputs. -/
def cellOfLabel (kind : String) : Name → Option String
  | .num (.str (.str (.str _ m) c) k) _ => if m == cellMarker && k == kind then some c else none
  | _ => none

/-- A new input: a subject named `name`, fed by the DAG request's
    `inputs.name`. (In `LunDriver.Dsl`, which DAG modules open.) -/
def Dsl.input (name : String) (α : Type) : DagM (Observable α) :=
  Subject.toObservable <$> Reactive.label (inputLabel name) (subject α)

/-- Apply cell `c` to the nodes `ids`: a `combineLatest` over the cell's
    function, labelled after the cell. A cell of no inputs gets a start
    source of its own instead, which the run feeds once. -/
def applyCell (c : CellImpl) (β : Type) (ids : List NodeId) : DagM (Observable β) :=
  Reactive.scope (cellScope c.name) do
    let ids ← if c.arity == 0 then (fun s => [s.toObservable.id]) <$> subject Unit else pure ids
    let f ← Reactive.register c.impl
    Reactive.addNode (.combineLatest f) ids β

/-- The operator a DAG applies for a cell of signature `σ`: one observable
    per input, then the cell's output (`Observable α₁ → … → DagM (Observable β)`,
    or `DagM (Observable β)` for a cell of no inputs). -/
abbrev CellRef (σ : Type 1) [CellFn σ] : Type := Combine IO Json (CellFn.Args σ) (CellFn.Out σ)

/-- The operator of the cell `c`, of signature `σ`. -/
def cellRef {σ : Type 1} [CellFn σ] (c : CellImpl) : CellRef σ :=
  Combine.collect (applyCell c (CellFn.Out σ)) [] (CellFn.Args σ)

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
    `LunDriver.Impl.name` and the operator DAGs apply, `LunDriver.Cells.name`
    (`cellRef`). -/
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
  elabCommand (← `(def $cellId : LunDriver.CellRef $sigId := LunDriver.cellRef $implId))

-- ── The DAG check ───────────────────────────────────────────────────────────

/-- What a node of a DAG is. -/
inductive NodeKind where
  /-- An input, by name. -/
  | input (name : String)
  /-- The start source of the cell of no inputs that reads it (not shown). -/
  | start
  /-- An application of a declared cell to the nodes `args` (graph indices). -/
  | cell (name : String) (args : List Nat)
  deriving Inhabited, BEq, Repr

/-- A checked DAG, ready to run: its graph, whose every function is a
    declared cell's, and what each node is. -/
structure Dag where
  graph : Graph IO Json
  kinds : Array NodeKind

/-- The builder's primitives, which a DAG may reach only through `input` and
    the cells. (`Reactive.fnImpl` is linen ≥ 1.4.0, so it is named, not
    resolved: the runtime still compiles against linen 1.3.0.) -/
def bannedInDag : List Name :=
  [ ``Reactive.register, ``Reactive.addNode, `Control.Reactive.Reactive.fnImpl, ``Reactive.fn
  , ``Builder.mk, ``Graph.mk, ``Graph.rebind, ``Operator.mk, ``Operator.splice ]

/-- Library modules, whose constants are trusted and not walked. -/
def trustedModule (m : Name) : Bool :=
  [`Init, `Std, `Lean, `Linen].contains m.getRoot || m == `LunDriver.Runtime

/-- `g` as a DAG of the declared `cells`, or what is wrong with it: every node
    is an input or an application of a declared cell (by its function's label)
    to as many nodes as the cell has inputs, and every function is a declared
    cell's — which then replaces it, whatever the graph held. Input names are
    distinct because labels are. -/
def Dag.ofGraph (cells : List CellImpl) (g : Graph IO Json) : Except String Dag := do
  let cellOf (name : String) : Option CellImpl := cells.find? (·.name == name)
  let fnCells ← g.fnLabels.toList.mapM fun l => match cellOfLabel "fn" l >>= cellOf with
    | some c => pure c
    | none => throw s!"the function `{l}` is not a declared cell; a DAG may apply only the \
        declared cells"
  let describe (i : Nat) : String := s!"node {i} (`{g.label ⟨i⟩}`)"
  let mut kinds : Array NodeKind := #[]
  let mut startsRead : List Nat := []
  for h : i in [0:g.nodes.size] do
    let n := g.nodes[i]
    match n.op with
    | .subject =>
      if let some name := inputOfLabel (g.label ⟨i⟩) then kinds := kinds.push (.input name)
      else if (cellOfLabel "subject" (g.label ⟨i⟩)).isSome then kinds := kinds.push .start
      else throw s!"{describe i} is a subject that is not an `input`"
    | .combineLatest f =>
      let some c := fnCells[f.idx]? | throw s!"{describe i} applies an unknown function"
      let args := n.args.map (·.idx)
      let isStart (j : Nat) : Bool := kinds[j]? == some .start
      if c.arity == 0 then
        match args with
        | [j] =>
          unless isStart j && !startsRead.contains j do
            throw s!"{describe i} applies '{c.name}', which takes no input, to a node"
          startsRead := j :: startsRead
          kinds := kinds.push (.cell c.name [])
        | _ => throw s!"{describe i} applies '{c.name}', which takes no input, to {args.length} nodes"
      else
        unless args.length == c.arity do
          throw s!"{describe i} applies '{c.name}' to {args.length} arguments; it takes {c.arity}"
        if args.any isStart then throw s!"{describe i} applies '{c.name}' to a start source"
        kinds := kinds.push (.cell c.name args)
    | op => throw s!"{describe i} uses the `{op.name}` operator; a DAG may only apply the \
        declared cells to inputs and to each other"
  for h : i in [0:kinds.size] do
    if kinds[i] == .start && !startsRead.contains i then throw s!"{describe i} is not read"
  let fns : Array (Impl IO Json) := Array.ofFn (n := g.fns.size) fun k =>
    ((fnCells[k.val]?).map CellImpl.impl).getD fun _ => pure (.error "unknown function")
  let graph : Graph IO Json :=
    ⟨g.nodes, fns, g.labels, g.fnLabels,
      by rw [Array.size_ofFn]; exact g.wellFormed, by rw [Array.size_ofFn]; exact g.labelled⟩
  return { graph, kinds }

/-- Build a DAG program and check it (`Dag.ofGraph`). -/
def Dag.ofReactive (cells : List CellImpl) (r : DagM Unit) : Except String Dag := do
  let dup := s!"two nodes are labelled `{inputMarker}."
  let (_, g) ← r.build.mapError fun e =>
    if e.startsWith dup then s!"the input '{((e.drop dup.length).takeWhile (· != '`')).toString}' \
      is declared twice" else e
  Dag.ofGraph cells g

/-- The error of a DAG, if it has one: what the check evaluates. -/
def Dag.error? (d : Except String Dag) : Option String :=
  match d with
  | .ok _ => none
  | .error e => some e

unsafe def evalErrorUnsafe (n : Name) : TermElabM (Option String) := evalConst (Option String) n
@[implemented_by evalErrorUnsafe] opaque evalError (n : Name) : TermElabM (Option String)

/-- The cell operators the driver generated: in `LunDriver.Cells`, defined by
    one of the generated `LunDriver.Cells.*` modules. -/
def isCellRef (env : Environment) (c : Name) : Bool :=
  let generated := match env.getModuleIdxFor? c with
    | some idx => (`LunDriver.Cells).isPrefixOf (env.header.moduleNames[idx.toNat]!)
    | none => false
  generated && (`LunDriver.Cells).isPrefixOf c &&
    ((env.find? c).map (·.type.getAppFn.isConstOf ``CellRef)).getD false

/-- The DAG check: the definition `dagName` uses none of the builder's
    primitives and no `sorry` (see the module documentation), and the error
    `errorName` evaluates to — its graph checked by `Dag.ofGraph` — is none. -/
def checkDag (dagName errorName : Name) : TermElabM Unit := do
  let env ← getEnv
  if (← collectAxioms dagName).contains ``sorryAx then throwError "the DAG depends on `sorry`"
  -- Walk every constant the definition reaches, through everything that is
  -- not library code, stopping at the generated cell operators.
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
  if let some e ← evalError errorName then throwError "invalid DAG: {e}"

/-- `lun_dag "name" := r#"program"#` — define the DAG `LunDriver.Dags.name`
    from a `Reactive` program over the declared cells (and, checked,
    `LunDriver.Graphs.name`), then check it. -/
elab "lun_dag " name:str " := " prog:str : command => do
  let t ← parseEmbeddedTerm prog
  let n := dottedName name.getString
  let dagName := `LunDriver.Dags ++ n
  let graphName := `LunDriver.Graphs ++ n
  let errorName := `LunDriver.DagErrors ++ n
  let dagId := mkIdent dagName
  let graphId := mkIdent graphName
  let errorId := mkIdent errorName
  let before := (← get).messages.toList.length
  elabCommand (← `(def $dagId : LunDriver.DagM Unit := Functor.discard ($t)))
  -- An ill-typed program is already reported; checking its error-recovery
  -- stand-in would only add a spurious `sorry`.
  if (← get).messages.toList.drop before |>.any (·.severity == .error) then return
  elabCommand (← `(def $graphId : Except String LunDriver.Dag :=
    LunDriver.Dag.ofReactive $(mkIdent `LunDriver.cellImpls) $dagId))
  elabCommand (← `(def $errorId : Option String := LunDriver.Dag.error? $graphId))
  withRef prog <| liftTermElabM (checkDag dagName errorName)

-- ── Running a DAG ───────────────────────────────────────────────────────────

/-- The nodes shown: inputs and cell applications, not start sources. Their
    positions in this list are the ids a DAG's nodes are known by. -/
def Dag.shown (d : Dag) : List Nat :=
  (List.range d.kinds.size).filter fun i => d.kinds[i]? != some .start

/-- The id of graph node `i` among the shown nodes. -/
def Dag.idOf (d : Dag) (i : Nat) : Nat := (d.shown.idxOf? i).getD i

/-- One node, for `describe` and DAG results. -/
def Dag.nodeJson (d : Dag) (i : Nat) : List (String × Json) :=
  match d.kinds[i]? with
  | some (.input name) => [("id", d.idOf i), ("input", name)]
  | some (.cell c args) => [("id", d.idOf i), ("cell", c), ("args", toJson (args.map d.idOf))]
  | _ => [("id", d.idOf i)]

/-- The shown nodes a shown node reads. -/
def Dag.argsOf (d : Dag) (i : Nat) : List Nat :=
  match d.kinds[i]? with
  | some (.cell _ args) => args
  | _ => []

/-- What happened to a node in a run. -/
inductive Outcome where
  | value (v : Json)
  | failed (message : String)
  /-- It did not run: its argument (a graph index) has no value. -/
  | skipped (arg : Nat)

/-- A DAG request: `{"inputs": {"name": value, …}}`. Every input and every
    cell of no inputs is fed once, at time 0 (a missing input is fed an
    `error`), and the graph runs to the end (linen's `Graph.runM`). The result
    has one entry per shown node, in order, with its `output`, its own
    `error`, or the node it was `skipped` because of: its first argument
    without a value. -/
def runDag (d : Dag) (req : Json) : IO (Except String Json) := do
  let inputs := (req.getObjVal? "inputs").toOption.getD (Json.mkObj [])
  let occurrences : List (Occurrence Json) := (List.range d.kinds.size).filterMap fun i =>
    match (d.kinds[i]? : Option NodeKind) with
    | some (.input name) => some ⟨0, ⟨i⟩, match inputs.getObjVal? name with
        | .ok v => .next v
        | .error _ => .error s!"missing input '{name}'"⟩
    | some .start => some ⟨0, ⟨i⟩, .next Json.null⟩
    | _ => none
  let trace ← d.graph.runM occurrences
  let emitted (i : Nat) : Outcome :=
    let events := (trace.events ⟨i⟩).map (·.2)
    match events.reverse.findSome? (fun | .next v => some v | _ => none) with
    | some v => .value v
    | none => match events.findSome? (fun | .error e => some e | _ => none) with
      | some e => .failed e
      | none => .failed "no value"
  let mut outcomes : Array Outcome := #[]
  for i in [0:d.kinds.size] do
    let blocked := (d.argsOf i).find? fun j => match outcomes[j]? with
      | some (.value _) => false
      | _ => true
    outcomes := outcomes.push (match blocked with
      | some j => .skipped j
      | none => emitted i)
  let nodes := d.shown.map fun i =>
    let result : List (String × Json) := match (outcomes[i]? : Option Outcome) with
      | some (.value v) => [("output", v)]
      | some (.failed e) => [("error", e)]
      | some (.skipped j) => [("skipped", d.idOf j)]
      | none => []
    Json.mkObj (d.nodeJson i ++ result)
  pure (.ok (Json.mkObj [("nodes", Json.arr nodes.toArray)]))

/-- The build's cells and DAGs, with each DAG's structure: its nodes, its
    sources (nodes reading none) and its sinks (nodes none reads). -/
def describe (cells : List CellImpl) (dags : List (String × Dag)) : Json :=
  Json.mkObj
    [ ("cells", Json.arr (cells.map fun c => Json.mkObj
        [("name", c.name), ("signature", c.signature), ("arity", c.arity)]).toArray)
    , ("dags", Json.arr (dags.map fun (name, d) =>
        let read := d.shown.flatMap d.argsOf
        Json.mkObj
          [ ("name", name)
          , ("nodes", Json.arr (d.shown.map fun i => Json.mkObj (d.nodeJson i)).toArray)
          , ("sources", toJson ((d.shown.filter fun i => (d.argsOf i).isEmpty).map d.idOf))
          , ("sinks", toJson ((d.shown.filter fun i => !read.contains i).map d.idOf)) ]).toArray) ]

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

/-- The driver's protocol. One JSON request on stdin, one JSON response on
    stdout; cells' traces go to stderr.

    - `describe` — the cells and DAGs (no stdin).
    - `cell NAME` — a cell request (`runCell`).
    - `dag NAME` — a DAG request (`runDag`).

    Exit code `0` for a response (which may report per-call errors), `1` for a
    request that could not be served (`{"error": …}` on stdout), `2` for a bad
    command line. -/
def driverMain (cells : List CellImpl) (dags : List (String × Except String Dag))
    (args : List String) :
    IO UInt32 := do
  let respond (r : Except String Json) : IO UInt32 := do
    match r with
    | .ok j => IO.println j.compress; pure 0
    | .error e => IO.println (Json.mkObj [("error", e)]).compress; pure 1
  let request : IO (Except String Json) := do
    let text ← (← IO.getStdin).readToEnd
    pure (if text.trimAscii.isEmpty then .ok (Json.mkObj []) else Json.parse text)
  match args with
  | ["describe"] =>
    match dags.findSome? fun (name, d) => (Dag.error? d).map (name, ·) with
    | some (name, e) => respond (.error s!"DAG '{name}': {e}")
    | none => respond (.ok (describe cells (dags.filterMap fun (n, d) => d.toOption.map (n, ·))))
  | ["cell", name] =>
    match cells.find? (·.name == name) with
    | none => respond (.error s!"no cell named '{name}'")
    | some c => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runCell c req)
  | ["dag", name] =>
    match dags.lookup name with
    | none => respond (.error s!"no DAG named '{name}'")
    | some (.error e) => respond (.error s!"DAG '{name}': {e}")
    | some (.ok d) => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runDag d req)
  | _ =>
    IO.eprintln "usage: lun-driver (describe | cell NAME | dag NAME)"
    pure 2

end LunDriver
