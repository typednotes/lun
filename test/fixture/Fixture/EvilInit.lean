import Linen.Control.Monad.Effect

namespace Fixture.EvilInit
open Control.Monad.Effect

initialize sideEffect : Nat ← pure 3
def output : Eff [] Nat := pure 3

end Fixture.EvilInit
