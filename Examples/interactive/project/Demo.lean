import Linen.Control.Monad.Effect

namespace Demo

open Control.Monad.Effect

/-- A typed function to call directly or apply to a graph input. -/
def double (n : Nat) : Eff [] Nat := pure (2 * n)

/-- A second independent branch of the live graph. -/
def greet (name : String) : Eff [] String := pure s!"Hello, {name}!"

end Demo
