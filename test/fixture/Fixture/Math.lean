/-
  Functions the end-to-end test declares as functions.
-/
import Lean.Data.Json
import Linen.Control.Monad.Effect
import Linen.Control.Monad.Effect.Trace
import Linen.Control.Monad.Effect.Error

namespace Fixture

open Control.Monad.Effect

/-- A pure function of one argument. -/
def double (n : Nat) : Eff [] Nat := pure (2 * n)

/-- A function of two arguments that traces. -/
def add (a b : Nat) : Eff [Trace.Trace] Nat := do
  Trace.trace s!"adding {a} and {b}"
  pure (a + b)

/-- A source function: its argument is `Unit`, so it needs no input. -/
def seed : Unit → Eff [] Nat := fun _ => pure 10

/-- A structured argument, through `Lean.FromJson`/`ToJson`. -/
structure Point where
  x : Int
  y : Int
  deriving Lean.ToJson, Lean.FromJson

/-- A function that may fail. -/
def norm1 (p : Point) : Eff [Error.Error String] Nat :=
  if p.x == 0 then Error.throwError "x is zero" else pure (p.x.natAbs + p.y.natAbs)

/-- Polymorphic in its effect row: instantiated by the declared signature. -/
def succ {effs : List (Type → Type)} (n : Nat) : Eff effs Nat := pure (n + 1)

/-- Renders a number. -/
def render (n : Nat) : Eff [] String := pure s!"#{n}"

-- ── Resumable producers ─────────────────────────────────────────────────────

/-- Two immediate values, then another two minutes later, using fresh Trace
    permission at each invocation of the resumable step. -/
def delayed (n now : Nat) (state : Option Unit) : Eff [Trace.Trace] (List Nat × Unit × Option Nat) := do
  Trace.trace "producer step"
  match state with
  | none => pure ([n, n + 1], (), some (now + 120000))
  | some () => pure ([n + 2], (), none)

/-- A finite burst large enough to exercise bounded calls and pending state. -/
def burst (n _now : Nat) (_state : Option Unit) : Eff [] (List Nat × Unit × Option Nat) :=
  pure (List.range n, (), none)

/-- A producer source with no graph arguments and an unbounded logical lifetime. -/
def ticker (now : Nat) (state : Option Nat) : Eff [] (List Nat × Nat × Option Nat) :=
  let n := state.getD 0
  pure ([n], n + 1, some (now + 60000))

/-- Wait without emitting, then produce a value. -/
def later (n now : Nat) (state : Option Unit) : Eff [] (List Nat × Unit × Option Nat) :=
  match state with
  | none => pure ([], (), some (now + 120000))
  | some () => pure ([n], (), none)

/-- A bad schedule must become a local node error, not an executor busy loop. -/
def invalidWake (_n now : Nat) (_state : Option Unit) : Eff [] (List Nat × Unit × Option Nat) :=
  pure ([1], (), some now)

end Fixture
