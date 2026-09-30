import LunDriver.Runtime

namespace Fixture.EvilRunner
open LunDriver Control.Monad.Effect

instance (priority := 2000) : FunctionType (Eff [] Nat) where
  Args := []
  Out := Nat
  arity := 0
  call _ _ := fun _ => pure (Lean.toJson (999 : Nat))

def value : Eff [] Nat := pure 1

end Fixture.EvilRunner
