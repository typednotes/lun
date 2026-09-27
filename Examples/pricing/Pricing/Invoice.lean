/-
  An invoice, as the functions lun serves and the graph wires them into.

  Every amount is in cents. Each function traces what it computes, so a
  client sees which ones an update ran: only those downstream of the inputs
  it changed.
-/
import Lean.Data.Json
import Linen.Control.Monad.Effect
import Linen.Control.Monad.Effect.Trace
import Linen.Control.Monad.Effect.Error

namespace Pricing

open Control.Monad.Effect

/-- One line of the invoice. -/
structure Line where
  sku : String
  quantity : Nat
  unitPrice : Nat
  deriving Lean.ToJson, Lean.FromJson, Repr

/-- The sum of the lines. -/
def subtotal (lines : List Line) : Eff [Trace.Trace] Nat := do
  let s := (lines.map fun l => l.quantity * l.unitPrice).foldl (· + ·) 0
  Trace.trace s!"subtotal: {lines.length} lines"
  pure s

/-- The amount after a discount code (`""` for none); an unknown code fails. -/
def discounted (amount : Nat) (code : String) : Eff [Trace.Trace, Error.Error String] Nat := do
  Trace.trace s!"discounted: code '{code}' on {amount}"
  let percent ← match code with
    | "" => pure 0
    | "WELCOME10" => pure 10
    | "VIP" => pure 20
    | other => Error.throwError s!"unknown discount code '{other}'"
  pure (amount - amount * percent / 100)

/-- Shipping to a country: free from 100.00, otherwise a flat rate. -/
def shipping (amount : Nat) (country : String) : Eff [Trace.Trace, Error.Error String] Nat := do
  Trace.trace s!"shipping: {amount} to {country}"
  let rate ← match country with
    | "FR" => pure 490
    | "DE" | "BE" | "NL" => pure 890
    | "US" => pure 1990
    | other => Error.throwError s!"no shipping to '{other}'"
  pure (if amount ≥ 10000 then 0 else rate)

/-- The VAT due in a country on an amount, rounded down. -/
def vat (amount : Nat) (country : String) : Eff [Trace.Trace, Error.Error String] Nat := do
  Trace.trace s!"vat: on {amount} in {country}"
  let rate ← match country with
    | "FR" => pure 20
    | "DE" => pure 19
    | "BE" | "NL" => pure 21
    | "US" => pure 0
    | other => Error.throwError s!"no VAT rate for '{other}'"
  pure (amount * rate / 100)

/-- What is due. -/
def total (net shippingFee tax : Nat) : Eff [Trace.Trace] Nat := do
  Trace.trace s!"total: {net} + {shippingFee} + {tax}"
  pure (net + shippingFee + tax)

/-- An amount as euros: `12345` ↦ `"€123.45"`. -/
def euros (cents : Nat) : Eff [] String :=
  let c := cents % 100
  pure s!"€{cents / 100}.{if c < 10 then "0" else ""}{c}"

end Pricing
