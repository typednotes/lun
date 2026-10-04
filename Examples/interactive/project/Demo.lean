import Linen.Control.Monad.Effect
import Linen.Control.Monad.Effect.Producer

namespace Demo

open Control.Monad.Effect

/-- A typed function to call directly or apply to a graph input. -/
def double (n : Nat) : Eff [] Nat := pure (2 * n)

/-- A second independent branch of the live graph. -/
def greet (name : String) : Eff [] String := pure s!"Hello, {name}!"

-- ── Sequential producers ────────────────────────────────────────────────────

/-- Consume a list-valued emission as one ordinary function argument. -/
def sum (xs : List Nat) : Eff [] Nat := pure (xs.foldl (· + ·) 0)

/-- Emit each element immediately, without a wait between elements. -/
def each (xs : List Nat) := Producer.run do
  Producer.yieldAll xs

/-- Emit the full list as one value, rather than expanding it. -/
def whole (xs : List Nat) := Producer.run do
  Producer.yield xs

/-- Emit a prefix now, then yield inside a branch and loop with waits. -/
def paced (xs : List Nat) := Producer.run do
  Producer.yieldAll (xs.take 2)
  Producer.wait 2000
  for x in xs.drop 2 do
    if x % 2 == 0 then
      Producer.yield x
      Producer.wait 1000

/-- A pure source: emit a counter now and every five seconds thereafter. -/
def tick := Producer.every 5000 fun n => do
  Producer.yield n

end Demo
