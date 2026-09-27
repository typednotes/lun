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

end Fixture
