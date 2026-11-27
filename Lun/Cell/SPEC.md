# Native DAG cells

- **S1. Compiler identity.** A successful DAG build emits Linen 4.1 version 2
  cell manifests after the existing signature, graph and transitive closure
  audits and warning-free native build. Each manifest fixes the resolved Lean
  declaration, immutable Git source, ordered signature, producer shape, host
  target/toolchain, Lun ABI/audit/codec versions and executable digest/length.
  Build keys fingerprint the source, generated wrapper, dependency sources/locks
  and explicit linker inputs/options. The canonical request records intent;
  its admitted signatures and Lun audit version record the static policy.
  Native payloads obey Linen's 128 MiB bound. Linux linking removes non-runtime
  ELF symbols while retaining the dynamic symbol table and loader metadata.
- **S2. Independent admission.** Each computation placement has a compiler-owned
  manifest pin. Before any graph effects, verify every used package using the
  configured public keyring and independently derived contract/runtime profile.
  Missing/duplicate placements, changed source, contract, signature, payload,
  pin or runtime fail closed. Request JSON cannot select packages or trust roots.
  Graph inputs are caller-owned values, rather than executable cells.
- **S3. Typed invocation.** Decode arguments before interpreting a cell. Decode
  native results with the consumer's compiled output dictionaries; producer
  state and every emission have their own decoders. Cell and placement identities
  accompany each private message. Native calls receive fresh authority and
  bounded diagnostics, never credentials from a manifest or saved graph state.
  This adapter preserves Lun's nondependent signature restriction.
- **S4. Execution.** All DAG function and producer applications run only retained,
  verified native bytes through Linen's owned local workers. There is no unsigned
  closure fallback or source compilation during a graph call. A graph step has
  at most 16 distinct cell worker scopes, reused within that step and reaped on
  exit. A private heartbeat bounds orphan lifetime after parent failure. Failed
  transport calls are not replayed. Graph state/scheduling remain caller-owned;
  its identity includes exact cell pins. Old runtime artifacts require rebuilding.
- **S5. Trust boundary.** Operators provision the compiler signing home/fingerprint
  and public trust root. Lun neither generates production keys nor publishes
  packages. Signing configuration is removed from build/worker environments;
  runtime authority travels only in private stdin messages. Build isolation must
  prevent untrusted Lakefiles/metaprograms from accessing the signing key or
  modifying trusted compiler outputs. Signatures attest compiler outputs, not
  a general process sandbox. Host libraries, native FFI and compiler isolation
  remain trusted. Local source snapshots may reference local dependency paths.
