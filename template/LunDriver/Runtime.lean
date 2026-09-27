/-
  LunDriver.Runtime — written by lun into every driver package; do not edit.

  A *driver* is the Lake package lun generates around a user project: one
  module per declared function, one per declared graph, and an executable serving
  them over a stdin/stdout JSON protocol. This module is everything those
  generated modules share:

  - `FunctionType σ` — which types a served function can have, and how to call one on JSON
    arguments: `α₁ → … → αₙ → Eff effs β` with every `αᵢ` `Lean.FromJson`, `β`
    `Lean.ToJson`, and `effs` runnable in `IO` (`Handlers effs IO`). A `Unit`
    argument takes no input.
  - `lun_function "name" := f : r"σ"` — the signature check, stricter than
    elaboration:
    `f` must *be* a function of type `σ` (no coercion), non-dependent, ending in
    `Eff`, whose effects are all linen's vetted ones — `Trace`, `Error`, `HTTP`,
    `FileSystem` — handled by linen's own `Handler _ IO` instances (a project's
    own instance for one of them is refused), and free of `sorry`; then the
    function's implementation and typed reference.
  - `lun_graph "name" := r#"program"#` — a graph: a program in linen's
    `Reactive IO Json` monad (`Control.Reactive`) over `input`s and the functions,
    each function applying to observables (a `combineLatest` over
    the function). The check: the program is free of `sorry` and of the builder's
    primitives (it is walked through every non-library constant it uses), and
    the graph it builds consists of inputs and applications of declared functions
    with their arity, nothing else (`GraphImpl.ofGraph`). Every function of the
    graph is then replaced by the declared function its label names, so what runs
    is only ever a declared, checked function.
  - Request text (signatures, graph programs) is embedded as raw string literals
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

-- ── Which Lean functions lun serves ─────────────────────────────────────────

/-- A type a served function can have, and how to call such a function on JSON
    arguments. -/
class FunctionType (σ : Type 1) where
  /-- The argument types that take an input (`Unit` arguments do not). -/
  Args : List Type
  /-- The value the function produces. -/
  Out : Type
  /-- `Args.length`. -/
  arity : Nat
  /-- Call on exactly `arity` JSON arguments; throws on a decoding error, a
      wrong argument count, or the effect's own error. -/
  call : σ → List Json → IO Json

/-- A `Unit` argument takes no input. -/
instance (priority := high) instFunctionTypeUnit {σ : Type 1} [FunctionType σ] : FunctionType (Unit → σ) where
  Args := FunctionType.Args σ
  Out := FunctionType.Out σ
  arity := FunctionType.arity σ
  call f js := FunctionType.call (f ()) js

/-- A JSON-decodable argument takes one input. -/
instance instFunctionTypeArrow {α : Type} {σ : Type 1} [FromJson α] [FunctionType σ] : FunctionType (α → σ) where
  Args := α :: FunctionType.Args σ
  Out := FunctionType.Out σ
  arity := FunctionType.arity σ + 1
  call f
    | j :: js => do
      match fromJson? j with
      | .ok a => FunctionType.call (f a) js
      | .error e => throw (IO.userError s!"cannot decode argument {j.compress}: {e}")
    | [] => throw (IO.userError "missing argument")

/-- The result: an effectful computation over a row runnable in `IO`. -/
instance instFunctionTypeEff {effs : List (Type → Type)} {β : Type} [Handlers effs IO] [ToJson β] :
    FunctionType (Eff effs β) where
  Args := []
  Out := β
  arity := 0
  call m
    | [] => toJson <$> m.handle
    | _ => throw (IO.userError "too many arguments")

/-- A checked function, ready to run: its name, declared signature and JSON entry
    point. -/
structure FunctionImpl where
  name : String
  signature : String
  arity : Nat
  call : List Json → IO Json

/-- Package a Lean function as a served one. -/
def FunctionImpl.ofFn {σ : Type 1} [FunctionType σ] (name signature : String) (f : σ) : FunctionImpl :=
  { name, signature, arity := FunctionType.arity σ, call := FunctionType.call f }

/-- Values travel through a graph wrapped: `{"ok": v}` for a value,
    `{"error": e}` for a function that failed, `{"blocked": true}` for a function not
    called because an argument has no value. Never as linen's `error`
    notification, which would end the node's stream for good: in a session a
    node that failed recovers when its inputs change. -/
def okValue (v : Json) : Json := Json.mkObj [("ok", v)]

/-- A function's failure, as a value (see `okValue`). -/
def failedValue (e : String) : Json := Json.mkObj [("error", e)]

/-- A function not called (see `okValue`). -/
def blockedValue : Json := Json.mkObj [("blocked", true)]

/-- The function as linen's reactive graphs call it: its arguments
    are the node's sources, in order (a function of no inputs reads one start
    source, whose value it ignores). It runs only if every argument is a
    value; it never fails as far as linen is concerned (see `okValue`). -/
def FunctionImpl.impl (c : FunctionImpl) : Impl IO Json := fun vs => do
  let args := vs.filterMap fun v => (v.getObjVal? "ok").toOption
  if args.length != vs.length then return .ok (some blockedValue)
  try pure (.ok (some (okValue (← c.call (if c.arity == 0 then [] else args)))))
  catch e => pure (.ok (some (failedValue (toString e))))

-- ── The signature check ─────────────────────────────────────────────────────

open Elab Command Term Meta

/-- The effects a function may use, each with the only `Handler _ IO` instance
    accepted for it (linen's). -/
def allowedEffects : List (Name × Name) :=
  [ (``Control.Monad.Effect.Trace.Trace, ``Control.Monad.Effect.Trace.instHandlerTraceIO)
  , (``Control.Monad.Effect.Error.Error, ``Control.Monad.Effect.Error.instHandlerErrorIO)
  , (``Control.Monad.Effect.HTTP.HTTP, ``Control.Monad.Effect.HTTP.instHandlerHTTPIO)
  , (``Control.Monad.Effect.FileSystem.FileSystem,
      ``Control.Monad.Effect.FileSystem.instHandlerFileSystemIO) ]

/-- The `Handler`/`Handlers` instances a function's runner may be built from. -/
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
      throwError "the effect handler `{c}` is not one of linen's; a function's effects must run \
        with linen's own handlers"

/-- The effect row and result a function's signature ends in:
    `α₁ → … → αₙ → Eff effs β`, non-dependent. -/
def functionRow (sig : Expr) : MetaM (Expr × Expr) :=
  forallTelescopeReducing sig fun xs body => do
    for h : i in [0:xs.size] do
      let x := xs[i].fvarId!
      let later ← (xs.extract (i + 1) xs.size).mapM inferType
      if body.containsFVar x || later.any (·.containsFVar x) then
        throwError "a function's signature cannot be a dependent function type"
    unless body.isAppOfArity ``Eff 2 do
      throwError "a function must return `Eff effs β`, not{indentExpr body}"
    return (body.getArg! 0, body.getArg! 1)

/-- The signature check: `fn` is a function of signature `sig`. -/
def checkFunction (fn : Ident) (sig : Term) : TermElabM Unit := do
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
  let (row, _) ← functionRow expected
  for eff in ← listElems row do
    let some effName := eff.getAppFn.constName?
      | throwError "the effect{indentExpr eff}\nis not a named effect"
    let some (_, instName) := allowedEffects.find? (·.1 == effName)
      | throwError "the effect `{effName}` is not allowed in a function; allowed: \
          {allowedEffects.map (·.1)}"
    let inst ← synthInstance (mkApp2 (mkConst ``Handler) eff (mkConst ``IO))
    unless inst.getAppFn.isConstOf instName do
      throwError "the effect `{effName}` resolves to the handler{indentExpr inst}\nnot linen's \
        `{instName}`"
  checkInstance (← synthInstance (mkApp2 (mkConst ``Handlers) row (mkConst ``IO)))
  if (← collectAxioms const).contains ``sorryAx then
    throwError "`{const}` depends on `sorry`"

-- ── Graphs: inputs and functions as operators ─────────────────────────────────────

/-- The monad a graph is written in: linen's reactive graphs, over JSON values,
    running functions in `IO`. -/
abbrev GraphM : Type → Type := Reactive IO Json

/-- The first component of every input's label. Not a valid identifier, so
    no function or input name can be mistaken for it. -/
def inputMarker : String := "#input"

/-- The first component of the scope every function application is built in. -/
def functionMarker : String := "#function"

/-- The label of input `name`: `«#input».«name»` (after any enclosing
    `scope`). -/
def inputLabel (name : String) : Name := .str (.str .anonymous inputMarker) name

/-- The scope an application of function `name` is built in. -/
def functionScope (name : String) : Name := .str (.str .anonymous functionMarker) name

/-- The input a subject's label names, if it is an input's. -/
def inputOfLabel : Name → Option String
  | .str (.str _ m) n => if m == inputMarker then some n else none
  | _ => none

/-- The function a generated label belongs to, if it was generated inside a function
    application: `…«#function».«name».kind.k`, `kind` being `fn` for the function
    itself and `subject` for the start source of a function of no inputs. -/
def functionOfLabel (kind : String) : Name → Option String
  | .num (.str (.str (.str _ m) c) k) _ => if m == functionMarker && k == kind then some c else none
  | _ => none

/-- A new input: a subject named `name`, fed by the graph request's
    `inputs.name`. (In `LunDriver.Dsl`, which graph modules open.) -/
def Dsl.input (name : String) (α : Type) : GraphM (Observable α) :=
  Subject.toObservable <$> Reactive.label (inputLabel name) (subject α)

/-- Apply function `c` to the nodes `ids`: a `combineLatest` over the function's
    implementation, labelled after it. A function of no inputs gets a start
    source of its own instead, which the run feeds once. -/
def applyFunction (c : FunctionImpl) (β : Type) (ids : List NodeId) : GraphM (Observable β) :=
  Reactive.scope (functionScope c.name) do
    let ids ← if c.arity == 0 then (fun s => [s.toObservable.id]) <$> subject Unit else pure ids
    let f ← Reactive.register c.impl
    Reactive.addNode (.combineLatest f) ids β

/-- The operator a graph applies for a function of signature `σ`: one observable
    per input, then the function's output (`Observable α₁ → … → GraphM (Observable β)`,
    or `GraphM (Observable β)` for a function of no inputs). -/
abbrev FunctionRef (σ : Type 1) [FunctionType σ] : Type := Combine IO Json (FunctionType.Args σ) (FunctionType.Out σ)

/-- The operator of the function `c`, of signature `σ`. -/
def functionRef {σ : Type 1} [FunctionType σ] (c : FunctionImpl) : FunctionRef σ :=
  Combine.collect (applyFunction c (FunctionType.Out σ)) [] (FunctionType.Args σ)

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

/-- `lun_function "name" := f : r"σ"` — check that `f` is a function of signature `σ`
    (see the module documentation), then define its implementation
    `LunDriver.Impl.name` and the operator graphs apply, `LunDriver.Functions.name`
    (`functionRef`). -/
elab "lun_function " name:str " := " fn:ident " : " sig:str : command => do
  let sigStx ← parseEmbeddedTerm sig
  liftTermElabM (checkFunction fn sigStx)
  let n := dottedName name.getString
  let sigId := mkIdent (`LunDriver.Sig ++ n)
  let implId := mkIdent (`LunDriver.Impl ++ n)
  let functionId := mkIdent (`LunDriver.Functions ++ n)
  let sigText := Syntax.mkStrLit sig.getString
  elabCommand (← `(abbrev $sigId : Type 1 := $sigStx))
  elabCommand (← `(def $implId : LunDriver.FunctionImpl :=
    LunDriver.FunctionImpl.ofFn $name $sigText ($fn : $sigId)))
  elabCommand (← `(def $functionId : LunDriver.FunctionRef $sigId := LunDriver.functionRef $implId))

-- ── The graph check ───────────────────────────────────────────────────────────

/-- What a node of a graph is. -/
inductive NodeKind where
  /-- An input, by name. -/
  | input (name : String)
  /-- The start source of the function of no inputs that reads it (not shown). -/
  | start
  /-- An application of a declared function to the nodes `args` (graph indices). -/
  | apply (name : String) (args : List Nat)
  deriving Inhabited, BEq, Repr

/-- A checked graph, ready to run: its graph, whose every function is a
    declared function's, and what each node is. -/
structure GraphImpl where
  graph : Graph IO Json
  kinds : Array NodeKind

/-- The builder's primitives, which a graph may reach only through `input` and
    the functions. (`Reactive.fnImpl` is linen ≥ 1.4.0, so it is named, not
    resolved: the runtime still compiles against linen 1.3.0.) -/
def bannedInGraph : List Name :=
  [ ``Reactive.register, ``Reactive.addNode, `Control.Reactive.Reactive.fnImpl, ``Reactive.fn
  , ``Builder.mk, ``Graph.mk, ``Graph.rebind, ``Operator.mk, ``Operator.splice ]

/-- Library modules, whose constants are trusted and not walked. -/
def trustedModule (m : Name) : Bool :=
  [`Init, `Std, `Lean, `Linen].contains m.getRoot || m == `LunDriver.Runtime

/-- `g` as a graph of the declared `functions`, or what is wrong with it: every node
    is an input or an application of a declared function (by its function's label)
    to as many nodes as the function has inputs, and every function is a declared
    function's — which then replaces it, whatever the graph held. Input names are
    distinct because labels are. -/
def GraphImpl.ofGraph (functions : List FunctionImpl) (g : Graph IO Json) : Except String GraphImpl := do
  let functionOf (name : String) : Option FunctionImpl := functions.find? (·.name == name)
  let fnImpls ← g.fnLabels.toList.mapM fun l => match functionOfLabel "fn" l >>= functionOf with
    | some c => pure c
    | none => throw s!"the function `{l}` is not a declared function; a graph may apply only the \
        declared functions"
  let describe (i : Nat) : String := s!"node {i} (`{g.label ⟨i⟩}`)"
  let mut kinds : Array NodeKind := #[]
  let mut startsRead : List Nat := []
  for h : i in [0:g.nodes.size] do
    let n := g.nodes[i]
    match n.op with
    | .subject =>
      if let some name := inputOfLabel (g.label ⟨i⟩) then kinds := kinds.push (.input name)
      else if (functionOfLabel "subject" (g.label ⟨i⟩)).isSome then kinds := kinds.push .start
      else throw s!"{describe i} is a subject that is not an `input`"
    | .combineLatest f =>
      let some c := fnImpls[f.idx]? | throw s!"{describe i} applies an unknown function"
      let args := n.args.map (·.idx)
      let isStart (j : Nat) : Bool := kinds[j]? == some .start
      if c.arity == 0 then
        match args with
        | [j] =>
          unless isStart j && !startsRead.contains j do
            throw s!"{describe i} applies '{c.name}', which takes no input, to a node"
          startsRead := j :: startsRead
          kinds := kinds.push (.apply c.name [])
        | _ => throw s!"{describe i} applies '{c.name}', which takes no input, to {args.length} nodes"
      else
        unless args.length == c.arity do
          throw s!"{describe i} applies '{c.name}' to {args.length} arguments; it takes {c.arity}"
        if args.any isStart then throw s!"{describe i} applies '{c.name}' to a start source"
        kinds := kinds.push (.apply c.name args)
    | op => throw s!"{describe i} uses the `{op.name}` operator; a graph may only apply the \
        declared functions to inputs and to each other"
  for h : i in [0:kinds.size] do
    if kinds[i] == .start && !startsRead.contains i then throw s!"{describe i} is not read"
  let fns : Array (Impl IO Json) := Array.ofFn (n := g.fns.size) fun k =>
    ((fnImpls[k.val]?).map FunctionImpl.impl).getD fun _ => pure (.error "unknown function")
  let graph : Graph IO Json :=
    ⟨g.nodes, fns, g.labels, g.fnLabels,
      by rw [Array.size_ofFn]; exact g.wellFormed, by rw [Array.size_ofFn]; exact g.labelled⟩
  return { graph, kinds }

/-- Build a graph program and check it (`GraphImpl.ofGraph`). -/
def GraphImpl.ofReactive (functions : List FunctionImpl) (r : GraphM Unit) : Except String GraphImpl := do
  let dup := s!"two nodes are labelled `{inputMarker}."
  let (_, g) ← r.build.mapError fun e =>
    if e.startsWith dup then s!"the input '{((e.drop dup.length).takeWhile (· != '`')).toString}' \
      is declared twice" else e
  GraphImpl.ofGraph functions g

/-- The error of a graph, if it has one: what the check evaluates. -/
def GraphImpl.error? (d : Except String GraphImpl) : Option String :=
  match d with
  | .ok _ => none
  | .error e => some e

unsafe def evalErrorUnsafe (n : Name) : TermElabM (Option String) := evalConst (Option String) n
@[implemented_by evalErrorUnsafe] opaque evalError (n : Name) : TermElabM (Option String)

/-- The function operators the driver generated: in `LunDriver.Functions`, defined by
    one of the generated `LunDriver.Functions.*` modules. -/
def isFunctionRef (env : Environment) (c : Name) : Bool :=
  let generated := match env.getModuleIdxFor? c with
    | some idx => (`LunDriver.Functions).isPrefixOf (env.header.moduleNames[idx.toNat]!)
    | none => false
  generated && (`LunDriver.Functions).isPrefixOf c &&
    ((env.find? c).map (·.type.getAppFn.isConstOf ``FunctionRef)).getD false

/-- The graph check: the definition `programName` uses none of the builder's
    primitives and no `sorry` (see the module documentation), and the error
    `errorName` evaluates to — its graph checked by `GraphImpl.ofGraph` — is none. -/
def checkGraph (programName errorName : Name) : TermElabM Unit := do
  let env ← getEnv
  if (← collectAxioms programName).contains ``sorryAx then throwError "the graph depends on `sorry`"
  -- Walk every constant the definition reaches, through everything that is
  -- not library code, stopping at the generated function operators.
  let trusted (c : Name) : Bool := match env.getModuleIdxFor? c with
    | some idx => trustedModule (env.header.moduleNames[idx.toNat]!)
    | none => false
  let mut todo : List Name := [programName]
  let mut seen : NameSet := {}
  -- A bound, not fuel: no graph definition reaches a million constants.
  for _ in [0:1000000] do
    match todo with
    | [] => break
    | c :: rest =>
      todo := rest
      if seen.contains c then continue
      seen := seen.insert c
      let some info := env.find? c | continue
      if info.isUnsafe then throwError "the graph uses the unsafe `{c}`"
      let some v := info.value? (allowOpaque := true) | continue
      for u in v.getUsedConstants ++ info.type.getUsedConstants do
        if bannedInGraph.contains u then
          throwError "the graph uses `{u}` (in `{c}`); a graph may build nodes only with `input` \
            and the declared functions"
        unless trusted u || isFunctionRef env u || seen.contains u do
          todo := u :: todo
  unless todo.isEmpty do throwError "the graph is too large to check"
  if let some e ← evalError errorName then throwError "invalid graph: {e}"

/-- `lun_graph "name" := r#"program"#` — define the graph `LunDriver.Programs.name`
    from a `Reactive` program over the declared functions (and, checked,
    `LunDriver.Graphs.name`), then check it. -/
elab "lun_graph " name:str " := " prog:str : command => do
  let t ← parseEmbeddedTerm prog
  let n := dottedName name.getString
  let programName := `LunDriver.Programs ++ n
  let graphName := `LunDriver.Graphs ++ n
  let errorName := `LunDriver.GraphErrors ++ n
  let programId := mkIdent programName
  let graphId := mkIdent graphName
  let errorId := mkIdent errorName
  let before := (← get).messages.toList.length
  elabCommand (← `(def $programId : LunDriver.GraphM Unit := Functor.discard ($t)))
  -- An ill-typed program is already reported; checking its error-recovery
  -- stand-in would only add a spurious `sorry`.
  if (← get).messages.toList.drop before |>.any (·.severity == .error) then return
  elabCommand (← `(def $graphId : Except String LunDriver.GraphImpl :=
    LunDriver.GraphImpl.ofReactive $(mkIdent `LunDriver.functionImpls) $programId))
  elabCommand (← `(def $errorId : Option String := LunDriver.GraphImpl.error? $graphId))
  withRef prog <| liftTermElabM (checkGraph programName errorName)

-- ── Running a graph: sessions ─────────────────────────────────────────────────

/-- The nodes shown: inputs and function applications, not start sources. Their
    positions in this list are the ids a graph's nodes are known by. -/
def GraphImpl.shown (d : GraphImpl) : List Nat :=
  (List.range d.kinds.size).filter fun i => d.kinds[i]? != some .start

/-- The id of graph node `i` among the shown nodes. -/
def GraphImpl.idOf (d : GraphImpl) (i : Nat) : Nat := (d.shown.idxOf? i).getD i

/-- One node, for `describe` and graph results. -/
def GraphImpl.nodeJson (d : GraphImpl) (i : Nat) : List (String × Json) :=
  match (d.kinds[i]? : Option NodeKind) with
  | some (.input name) => [("id", d.idOf i), ("input", name)]
  | some (.apply c args) => [("id", d.idOf i), ("function", c), ("args", toJson (args.map d.idOf))]
  | _ => [("id", d.idOf i)]

/-- The nodes a node reads (graph indices). -/
def GraphImpl.argsOf (d : GraphImpl) (i : Nat) : List Nat :=
  match (d.kinds[i]? : Option NodeKind) with
  | some (.apply _ args) => args
  | _ => []

/-- The graph index of input `name`. -/
def GraphImpl.inputIndex? (d : GraphImpl) (name : String) : Option Nat :=
  (List.range d.kinds.size).find? fun i => d.kinds[i]? == some (.input name)

/-- The graph's inputs, by name. -/
def GraphImpl.inputNames (d : GraphImpl) : List String :=
  d.kinds.toList.filterMap fun | .input n => some n | _ => none

/-- A session's state between calls: linen's clock and every node's operator
    state, and every node's outcome so far (`Outcome.toJson`, or `null` for a
    node not computed yet). Plain JSON: lun stores it and hands it back. -/
structure SessionState where
  now : Nat
  cells : Array (Control.Reactive.Cell Json)
  outcomes : Array Json

deriving instance ToJson, FromJson for Control.Reactive.Cell

instance : ToJson SessionState where
  toJson s := Json.mkObj
    [("now", s.now), ("cells", toJson s.cells), ("outcomes", Json.arr s.outcomes)]

/-- Read a session's state back, checking it is one of this graph's. -/
def SessionState.ofJson (d : GraphImpl) (j : Json) : Except String SessionState := do
  let s : SessionState :=
    { now := ← j.getObjValAs? Nat "now", cells := ← j.getObjValAs? (Array (Control.Reactive.Cell Json)) "cells"
      outcomes := ← j.getObjValAs? (Array Json) "outcomes" }
  unless s.cells.size == d.graph.size && s.outcomes.size == d.graph.size do
    throw "the session's state is not one of this graph's"
  return s

/-- A node's outcome, from the value it last emitted: `{"output": v}`, its
    function's `{"error": e}`, or `{"skipped": j}` (`j` its first argument without
    a value); `outcomes` holds the outcomes of the nodes before it. -/
def GraphImpl.outcomeOf (d : GraphImpl) (outcomes : Array Json) (i : Nat) (v : Json) : Json :=
  match v.getObjVal? "ok", v.getObjValAs? String "error" with
  | .ok out, _ => Json.mkObj [("output", out)]
  | _, .ok e => Json.mkObj [("error", e)]
  | _, _ =>
    let hasValue (j : Nat) : Bool := ((outcomes[j]?).bind (·.getObjVal? "output" |>.toOption)).isSome
    match (d.argsOf i).find? (!hasValue ·) with
    | some j => Json.mkObj [("skipped", d.idOf j)]
    | none => Json.mkObj [("error", "no value")]

/-- The value an input is fed: its value, or (`none`) a missing input's error. -/
def inputValue (v : Option Json) (name : String) : Json :=
  match v with
  | some v => okValue v
  | none => failedValue s!"missing input '{name}'"

/-- Feed occurrences — `(graph index, value)`, all at one new instant of the
    session's clock, in order — and return the new state and the shown nodes
    whose outcome changed. Only nodes downstream of what is fed run: linen's
    `Session`, restored from the state, with the operators' state kept. -/
def GraphImpl.feed (d : GraphImpl) (st : SessionState) (occurrences : List (Nat × Json)) :
    IO (SessionState × List Nat) := do
  let t := st.now + 1
  let s : Session Json := { d.graph.start with now := st.now, cells := st.cells }
  let s ← d.graph.pushAll s (occurrences.map fun (i, v) => ⟨t, ⟨i⟩, .next v⟩)
  let last (i : Nat) : Option Json :=
    ((s.streams[i]?).map (·.toList.reverse)).bind fun es =>
      es.findSome? fun (_, n) => match n with | .next v => some v | _ => none
  let mut outcomes := st.outcomes
  for i in [0:d.kinds.size] do
    if let some v := last i then outcomes := outcomes.set! i (d.outcomeOf outcomes i v)
  let changed := d.shown.filter fun i => outcomes[i]? != st.outcomes[i]?
  return ({ now := t, cells := s.cells, outcomes }, changed)

/-- A new session: the state of a graph no value has reached yet. -/
def GraphImpl.initial (d : GraphImpl) : SessionState :=
  { now := 0, cells := (d.graph.start (V := Json)).cells
    outcomes := Array.replicate d.graph.size Json.null }

/-- The start sources, each fed once when a session starts. -/
def GraphImpl.starts (d : GraphImpl) : List (Nat × Json) :=
  (List.range d.kinds.size).filterMap fun i =>
    if d.kinds[i]? == some .start then some (i, okValue Json.null) else none

/-- The occurrences for `{"name": value, …}`: every name must be an input. -/
def GraphImpl.occurrencesOf (d : GraphImpl) (inputs : Json) : Except String (List (Nat × Json)) := do
  let kvs ← match inputs with
    | .obj kvs => pure kvs.toList
    | .null => pure []
    | _ => throw "\"inputs\" must be an object"
  kvs.mapM fun (name, v) => match d.inputIndex? name with
    | some i => pure (i, okValue v)
    | none => throw s!"the graph has no input named '{name}'; its inputs: {d.inputNames}"

/-- The shown nodes `is`, each with its outcome. -/
def GraphImpl.nodesJson (d : GraphImpl) (st : SessionState) (is : List Nat) : Json :=
  Json.arr <| is.toArray.map fun i =>
    let result := match st.outcomes[i]? with
      | some (.obj kvs) => kvs.toList
      | _ => []
    Json.mkObj (d.nodeJson i ++ result)

/-- A graph request, stateless: `{"inputs": {"name": value, …}}`. A session
    started with every input (a missing one fed an error) and its every node,
    in order, with its `output`, its own `error`, or the node it was `skipped`
    because of: its first argument without a value. -/
def runGraph (d : GraphImpl) (req : Json) : IO (Except String Json) := do
  let inputs := (req.getObjVal? "inputs").toOption.getD (Json.mkObj [])
  let fed := d.inputNames.map fun name =>
    ((d.inputIndex? name).getD 0, inputValue (inputs.getObjVal? name).toOption name)
  let (st, _) ← d.feed d.initial (d.starts ++ fed)
  pure (.ok (Json.mkObj [("nodes", d.nodesJson st d.shown)]))

/-- Start a session: `{"inputs": {…}}` (optional; inputs not given are not fed,
    so what depends on them has no outcome yet). The answer: the state, and
    every node. -/
def sessionStart (d : GraphImpl) (req : Json) : IO (Except String Json) := do
  match d.occurrencesOf ((req.getObjVal? "inputs").toOption.getD .null) with
  | .error e => pure (.error e)
  | .ok occ =>
    let (st, _) ← d.feed d.initial (d.starts ++ occ)
    pure (.ok (Json.mkObj [("state", toJson st), ("nodes", d.nodesJson st d.shown)]))

/-- Update a session: `{"state": …, "inputs": {…}}`. The answer: the new state,
    every node, and the nodes whose outcome changed (`changed`), in order.
    Several inputs are fed in order, at one instant of the session's clock: a
    function reading two of them may run for the intermediate state too; only the
    final outcomes are reported. -/
def sessionUpdate (d : GraphImpl) (req : Json) : IO (Except String Json) := do
  match (req.getObjVal? "state" >>= SessionState.ofJson d),
      d.occurrencesOf ((req.getObjVal? "inputs").toOption.getD .null) with
  | .error e, _ | _, .error e => pure (.error e)
  | .ok st, .ok occ =>
    -- An input given the value it already has changes nothing: not fed, so
    -- no function downstream of it runs again.
    let occ := occ.filter fun (i, v) =>
      match st.outcomes[i]?, v.getObjVal? "ok" with
      | some o, .ok x => o != Json.mkObj [("output", x)]
      | _, _ => true
    let (st, changed) ← d.feed st occ
    pure (.ok (Json.mkObj [("state", toJson st), ("nodes", d.nodesJson st d.shown)
                         , ("changed", d.nodesJson st changed)]))

/-- The build's functions and graphs, with each graph's structure: its nodes, its
    sources (nodes reading none) and its sinks (nodes none reads). -/
def describe (functions : List FunctionImpl) (graphs : List (String × GraphImpl)) : Json :=
  Json.mkObj
    [ ("functions", Json.arr (functions.map fun c => Json.mkObj
        [("name", c.name), ("signature", c.signature), ("arity", c.arity)]).toArray)
    , ("graphs", Json.arr (graphs.map fun (name, d) =>
        let read := d.shown.flatMap d.argsOf
        Json.mkObj
          [ ("name", name)
          , ("inputs", toJson d.inputNames)
          , ("nodes", Json.arr (d.shown.map fun i => Json.mkObj (d.nodeJson i)).toArray)
          , ("sources", toJson ((d.shown.filter fun i => (d.argsOf i).isEmpty).map d.idOf))
          , ("sinks", toJson ((d.shown.filter fun i => !read.contains i).map d.idOf)) ]).toArray) ]

-- ── The protocol ────────────────────────────────────────────────────────────

/-- The arguments of one call, from its input: nothing for a function of no
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

/-- Run a function, turning every failure into an `Except`. -/
def FunctionImpl.run (c : FunctionImpl) (input : Option Json) : IO (Except String Json) := do
  match argsOf c.arity input with
  | .error e => pure (.error e)
  | .ok args =>
    try pure (.ok (← c.call args)) catch e => pure (.error (toString e))

/-- A function request: `{"input": x}` (one call; omitted for a function of no
    inputs) or `{"inputs": [x₁, x₂, …]}` (one call per element). -/
def runFunction (c : FunctionImpl) (req : Json) : IO (Except String Json) := do
  match req.getObjVal? "inputs" with
  | .ok (.arr xs) =>
    let outs ← xs.mapM fun x => outcomeJson <$> c.run (some x)
    pure (.ok (Json.mkObj [("outputs", Json.arr outs)]))
  | .ok _ => pure (.error "\"inputs\" must be an array")
  | .error _ =>
    let input := (req.getObjVal? "input").toOption
    pure (.ok (outcomeJson (← c.run input)))

/-- The driver's protocol. One JSON request on stdin, one JSON response on
    stdout; functions' traces go to stderr.

    - `describe` — the functions and graphs (no stdin).
    - `function NAME` — a function request (`runFunction`).
    - `graph NAME` — a graph request (`runGraph`), stateless.
    - `session-start NAME` / `session-update NAME` — a session of a graph
      (`sessionStart`, `sessionUpdate`): its state travels in the request and
      the response, and lun keeps it between calls.

    Exit code `0` for a response (which may report per-call errors), `1` for a
    request that could not be served (`{"error": …}` on stdout), `2` for a bad
    command line. -/
def driverMain (functions : List FunctionImpl) (graphs : List (String × Except String GraphImpl))
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
    match graphs.findSome? fun (name, d) => (GraphImpl.error? d).map (name, ·) with
    | some (name, e) => respond (.error s!"graph '{name}': {e}")
    | none => respond (.ok (describe functions (graphs.filterMap fun (n, d) => d.toOption.map (n, ·))))
  | ["function", name] =>
    match functions.find? (·.name == name) with
    | none => respond (.error s!"no function named '{name}'")
    | some c => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runFunction c req)
  | ["graph", name] =>
    match graphs.lookup name with
    | none => respond (.error s!"no graph named '{name}'")
    | some (.error e) => respond (.error s!"graph '{name}': {e}")
    | some (.ok d) => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runGraph d req)
  | [command, name] =>
    let run? : Option (GraphImpl → Json → IO (Except String Json)) := match command with
      | "session-start" => some sessionStart
      | "session-update" => some sessionUpdate
      | _ => none
    match run?, graphs.lookup name with
    | none, _ => IO.eprintln s!"unknown command '{command}'"; pure 2
    | some _, none => respond (.error s!"no graph named '{name}'")
    | some _, some (.error e) => respond (.error s!"graph '{name}': {e}")
    | some run, some (.ok d) => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← run d req)
  | _ =>
    IO.eprintln "usage: lun-driver (describe | function NAME | graph NAME | session-start NAME | session-update NAME)"
    pure 2

end LunDriver
