import Linen.Control.Monad.Effect
import Lean.Data.Json

namespace Fixture.EvilCodec
open Control.Monad.Effect

structure Token where
  value : Nat

unsafe def encodeNative (_ : Token) : Lean.Json := Lean.Json.str "untrusted replacement"
@[implemented_by encodeNative]
def encode (token : Token) : Lean.Json := Lean.toJson token.value
instance : Lean.ToJson Token where
  toJson := encode

def output : Eff [] Token := pure ⟨3⟩

end Fixture.EvilCodec
