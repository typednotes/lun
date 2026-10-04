import Linen.Control.Monad.Effect.Producer

namespace Fixture

open Control.Monad.Effect

/-- A sequential block whose branch and loop-local accumulator survive waits. -/
def paced (xs : List Nat) := Producer.run do
  Producer.yieldAll (xs.take 2)
  Producer.wait 2000
  let mut total := 0
  for x in xs.drop 2 do
    total := total + x
    if x % 2 == 0 then
      Producer.yield total
      Producer.wait 1000
  Producer.yield (total + 100)

/-- A repeating pure source written without manual continuation management. -/
def every5s := Producer.every 5000 fun n => Producer.yield n

/-- Emit individual elements immediately, preserving even repeated elements. -/
def eachNow (xs : List Nat) := Producer.run do
  Producer.yieldAll xs

/-- Emit the entire list as a single observable element. -/
def wholeList (xs : List Nat) := Producer.run do
  Producer.yield xs

end Fixture
