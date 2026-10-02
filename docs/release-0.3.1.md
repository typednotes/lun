# Lun v0.3.1

Adds a proof-bearing public-share execution mode for Typednotes v0.9.0 without
changing function declarations, operation catalogs or the broker SDK.

Session creation accepts optional `safeShare:true`. The private constructor of
`PureShareExecution` requires policy-derived effect names, evidence every name
is Trace or Error, and empty connector grants. `no_external` proves that every
other effect name is absent. Start consumes this witness before `Builder.call`;
session records persist the mode across restarts. Update consumes both existing
`ExecutionRefresh` attenuation evidence and a fresh pure-share witness. The
request cannot change the stored mode, binding or widen the effect ceiling.

The app sends no domains or credentials and owns per-browser token/session
isolation, snapshot filtering, expiry and revocation. This proof constrains
runtime execution; it is not a proof that published output lacks private data.
Runtime effect interpreters, build auditing, trusted FFI/library code and process
isolation retain their documented roles. Raw IO and unknown effects do not gain
an execution fallback.

Lean parser/refusal tests and actual compiled-driver cases verify external-effect
denial before vault reads, broker egress or database writes, plus update widening
refusal. The app browser suite independently checks anonymous viewer/owner
isolation, public snapshot filtering, limits and revocation.

No dependency source pin or previously shipped migration changes. Pair deployment
with Liaison v0.6.3 / Typednotes v0.9.0 / Typednotes-infra v0.6.1. The user can push
main and v0.3.1 together; wait for exact-SHA main CI and image publication before
manual fleet Apply. Existing tags stay immutable.
