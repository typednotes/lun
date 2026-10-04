import Linen.Control.Monad.Effect.Producer

namespace Tutorial

open Control.Monad.Effect

-- ── Pure sources and immediate emissions ────────────────────────────────────

/-- Emit immediately and then every five seconds. -/
def every5s := Producer.every 5000 fun n => do
  Producer.yield n

/-- Wait before the first and only value. -/
def after5s := Producer.run do
  Producer.wait 5000
  Producer.yield (42 : Nat)

/-- Each element is a separate emission, with no explicit delay. -/
def eachNow (xs : List Nat) := Producer.run do
  Producer.yieldAll xs

/-- The observable element type is List Nat: this is one whole-list emission. -/
def wholeList (xs : List Nat) := Producer.run do
  Producer.yield xs

-- ── Branches, loops and reusable blocks ──────────────────────────────────────

/-- Emit two elements now, then selected loop elements a second apart. -/
def paced (xs : List Nat) := Producer.run do
  Producer.yieldAll (xs.take 2)
  Producer.wait 2000
  for x in xs.drop 2 do
    if x % 2 == 0 then
      Producer.yield x
      Producer.wait 1000

/-- Either emit all elements or just the even ones. -/
def selected (xs : List Nat) := Producer.run do
  if xs.length <= 3 then
    Producer.yieldAll xs
  else
    Producer.yieldAll (xs.filter fun x => x % 2 == 0)

/-- A match branch may emit, wait, and emit again. -/
def headThenTail (xs : List Nat) := Producer.run do
  match xs with
  | [] => pure ()
  | first :: rest =>
    Producer.yield first
    Producer.wait 1000
    Producer.yieldAll rest

/-- Three immediate bursts separated by waits. -/
def batches (xs : List Nat) := Producer.run do
  Producer.yieldAll xs
  Producer.wait 2000
  Producer.yieldAll (xs.filter fun x => x % 2 == 0)
  Producer.wait 1000
  Producer.yieldAll xs.reverse

/-- Local mutable values are reconstructed on each resume. -/
def runningTotal (xs : List Nat) := Producer.run do
  let mut total := 0
  for x in xs do
    total := total + x
    Producer.yield total
    Producer.wait 1000

/-- Skip zeroes, and stop before the first element above ten. -/
def bounded (xs : List Nat) := Producer.run do
  for x in xs do
    if x == 0 then continue
    if x > 10 then break
    Producer.yield x
    Producer.wait 1000

/-- Ordinary nested finite loops can suspend between iterations. -/
def pairs (xs ys : List Nat) := Producer.run do
  for x in xs do
    for y in ys do
      Producer.yield (x * y)
      Producer.wait 250

/-- A reusable pure fragment, composed before lowering to a step. -/
def emitEven (xs : List Nat) : Producer.Script Nat Unit := do
  for x in xs do
    if x % 2 == 0 then Producer.yield x

/-- Call the same fragment with different pure arguments around a wait. -/
def composed (xs : List Nat) := Producer.run do
  emitEven xs
  Producer.wait 500
  emitEven (xs.map (· + 1))

-- ── Repeated blocks and a common output schema ───────────────────────────────

/-- An internal wait belongs to the current cycle; the period follows its end. -/
def sampleCycle := Producer.every 5000 fun n => do
  Producer.yield (n * 10)
  Producer.wait 2000
  Producer.yield (n * 10 + 1)

/-- One fixed output type can represent both a whole list and selected items. -/
structure Emission where
  items : List Nat
  whole : Bool
  deriving Lean.ToJson, Lean.FromJson

/-- Emit the full list, then individual even elements after a wait. -/
def mixed (xs : List Nat) := Producer.run do
  Producer.yield ({ items := xs, whole := true } : Emission)
  Producer.wait 2000
  for x in xs do
    if x % 2 == 0 then
      Producer.yield ({ items := [x], whole := false } : Emission)
      Producer.wait 1000

end Tutorial
