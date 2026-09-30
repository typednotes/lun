/-
  Functions lun must refuse as functions.
-/
import Linen.Control.Monad.Effect
import Linen.Control.Monad.Effect.Handler

namespace Fixture.Rejected

open Control.Monad.Effect

/-- Ambient `IO`: not an effect monad. -/
def ambient (n : Nat) : IO Nat := pure n

/-- An effect of the project's own that wraps arbitrary `IO`. -/
inductive Anything : Type → Type where
  | io {α : Type} : IO α → Anything α

instance : Handler Anything IO where
  handle | .io act => act

def sneaky (n : Nat) : Eff [Anything] Nat := send (Anything.io (pure n))

/-- Unfinished. -/
def unfinished (n : Nat) : Eff [] Nat := sorry

unsafe def replacement (n : Nat) : Eff [] Nat := pure (n + 100)
@[implemented_by replacement]
def replaced (n : Nat) : Eff [] Nat := pure n
def indirectReplacement (n : Nat) : Eff [] Nat := replaced n

axiom forgedProof : False
def forged (n : Nat) : Eff [] Nat := False.elim forgedProof

end Fixture.Rejected
