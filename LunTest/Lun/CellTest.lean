/- Executable examples of the independent native cell identities and codecs. -/
import Lun.Cell

open Lean Lun.Cell

namespace LunTests.Cell

/-- S1/S3: identities include immutable source, signature and producer shape. -/
def identityChecks : IO Unit := do
  let source ← IO.ofExcept ((System.Cell.GitSource.check "https://github.com/o/r"
    ("".pushn 'a' 40) "." "P" "P.double").mapError IO.userError)
  let contract : Contract := { source, signature := "Nat → Eff [] Nat", arity := 1, producer := false }
  let original ← contract.ref
  unless original != (← { contract with signature := "String → Eff [] Nat" }.ref) do
    throw (IO.userError "cell signature did not change its identity")
  unless original != (← { contract with producer := true }.ref) do
    throw (IO.userError "cell producer shape did not change its identity")
  let runtime ← contract.runtime
  unless runtime.runtimeAbi == runtimeAbi && runtime.auditVersion == auditVersion do
    throw (IO.userError "cell runtime profile did not use independent host requirements")
  let adapter ← codecs contract (fun input => if input.arguments.length == 1 then .ok () else .error "arity")
    (fun _ reply => if reply.outcome == Json.mkObj [("output", 4)] then .ok () else .error "output")
  let input : Invocation := {name := "double", contract, arguments := [2], context := Json.mkObj []}
  unless (adapter.decodeInput (adapter.encodeInput input)).isOk do
    throw (IO.userError "cell invocation did not round-trip")
  let cursorInput := {input with continuation := some ⟨Json.null⟩}
  unless ((adapter.decodeInput (adapter.encodeInput cursorInput)).toOption.bind (·.continuation)).map (·.value) == some Json.null do
    throw (IO.userError "a present JSON-null producer cursor was lost")
  unless (adapter.decodeInput []).toOption.isNone do throw (IO.userError "cell accepted a missing invocation")
  unless (adapter.decodeInput [toJson {input with arguments := []}]).toOption.isNone do
    throw (IO.userError "cell skipped the independent input validator")
  unless (adapter.decodeInput [toJson {input with contract := {contract with producer := true}}]).toOption.isNone do
    throw (IO.userError "cell accepted a different contract")
  unless (adapter.decodeOutput input (toJson ({outcome := Json.mkObj [("output", 5)], log := ""} : Reply))).toOption.isNone do
    throw (IO.userError "cell skipped the independent result validator")

#eval identityChecks

end LunTests.Cell
