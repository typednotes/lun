# Notebook runtime authority

This contract describes the coordinated **Lun 0.3.0 / Lode 0.3.0 /
Typednotes 0.6.0 / Linen 1.10.0 / Liaison 0.6.0** release. Package locks and
runtime/image defaults use these versions. Local release tags require publication
before deployment. The native app/writer/runtime integration has passed local verification.

## Caller-owned types and graph inputs

Build functions may supply `outputType` independently of their generated
`signature`. `lun_output` checks definitional equality and emits a kernel-checked
`OutputContract` theorem relating `FunctionType.Out` to that caller-owned type.
Graphs may supply `inputTypes`, an object mapping configured source names to Lean
type expressions, and ordered named `dependencies`. Kernel-proved
`WiringContract` layouts establish exactly one application of each constrained
cell with its ordered direct argument names. Runtime `BoundWiring` validation
consumes equality between the actual graph and that layout; `named_arguments`
proves the contract for the graph actually returned to execution.

Constrained inputs consume evidence that their actual Lean type equals the
configured type. Unconstrained source names remain available in a partially
constrained graph. `SourceContract`/`BoundSources.present` ensure each configured
source occurs exactly once in the actual runtime layout. Direct or helper-mediated
calls to the raw input constructor are refused in constrained graphs; raw
`Reactive.subject` construction is also refused, preventing labelled subjects
from impersonating checked sources. Linen's private observable/subject constructors
prevent a project from retyping a node index. Source decoders are generated from the
caller-owned type, and their executable dictionaries undergo the same transitive
audit as served functions. `ValidatedInput` carries the decoded value and decoder
equality; `InputContract.decoder_sound` proves that successful decoding preserves
the JSON and witnesses a value of the configured type.

All newly supplied constrained inputs decode before any graph node executes.
An invalid session update is a 400 and leaves stored state unchanged. For adopted
builds, `recoverInputs: true` on session registration converts incompatible
historic values to editable source errors. They never enter a function as values;
downstream nodes are blocked, and a correctly typed edit recovers the graph.
The app's adoption/registration caller sends this recovery mode, including when
an edited source type makes historic JSON incompatible with the rebuilt graph.

## Execution envelope and session attenuation

Every effect interpreter consumes an `EffectPermission` for the request's
organization policy. Missing policy grants no effects, including for legacy
builds. Malformed policy fails closed. Binding supplies `org_id`, `user_id`,
`graph_id`. Compute bindings may additionally supply `schema`, but the current
app omits it: the runtime compares the compiled role/schema to the credential
resolved exclusively for that organization/user. A supplied schema is an
additional equality constraint, never a role selector. The runtime broker URL and vault identity
are service configuration injected into private driver stdin by `Builder.call`;
the caller cannot replace them. Driver/build processes have service credentials
removed from their environment. `_runtime` is never persisted or returned.

Ready artifacts must attest `runtimeContract: "bounded-eff-v1"`. The server
consumes a `BoundedRuntime` witness before invoking a driver. Older cached
executables are refused with 409 and resubmission rebuilds them, so deploying
the new server cannot silently retain a legacy unbounded effect interpreter.

Every cell's `connectors` array contains records with these mandatory fields
(the current app wire shape):

```json
{"provider":"s3","connection":"connection","account":"user/connection",
 "organization":{"provider":"s3","connection":"connection","scopes":[],
   "maxRequestBytes":1048576,"maxResponseBytes":16777216},
 "connectionPermissions":{"provider":"s3","connection":"connection","scopes":[],
   "maxRequestBytes":1048576,"maxResponseBytes":16777216},
 "cell":{"provider":"s3","connection":"connection","scopes":[],
   "maxRequestBytes":1048576,"maxResponseBytes":16777216},
 "warrants":[{"operation":"objects.read","cost":0,"warrant":{}}]}
```

An optional `warrantPermissions` capability can further restrict the request's
envelope. When absent, the envelope uses the cell ceiling, filtered to the signed
operation. This does **not** replace the independent fourth ceiling: liaison
fetches its trusted `warrant` projection for Connector calls, and local native
operations retain the separately fetched projection in their private witness.
An explicitly malformed/null optional ceiling is refused.

The empty scopes above deliberately grant nothing; `warrant` stands for a real
operation-specific wire warrant. Scopes require operation/root/descendants, and
all byte bounds are explicit positive integral numbers up to 64 MiB. Connector
resource validation uses UTF-8 byte lengths and refuses percent escapes, path
separators, dot segments and C0/C1 controls. Duplicate authorization JSON keys are
rejected before conversion to map-backed JSON.

`AuthorizedRequest` consumes the intersection of organization, connection, cell,
and warrant scopes. The runtime cell ceiling must narrow the compiled static
capability. `onlyOperation_narrows`, semantic narrowing transitivity, four-ceiling
permission theorems, and four-ceiling request/response byte-bound theorems are
kernel checked. Signed caveats must agree with the actual provider, connection,
operation, organization, budget and runtime clock. `CompleteWarrant` requires
expiry and a budget within the unsigned 64-bit signed encoding; operation costs
come from the explicit trusted token metadata, including ObjectStore calls.
Native outbound calls contain
only an operation, account, structured selector and payload; liaison constructs
the provider transport and independently verifies HMAC and its stored ceilings.

`ExecutionRefresh` carries proof of `executionNarrows`. The actual update path
requires this witness before invoking the driver or writing state. Bindings are
immutable; effects/domains and all four public ceilings may only narrow. In
particular, `warrantPermissions` is persisted while warrant tokens are discarded.
Omitted fresh connector grants revoke them, rather than reusing a stored token.
Refreshes cannot add a new cell, account, provider, connection or bucket grant.

## Bound local services

The app's `packages/api/src/server/local.rs` provisions actor-bound
`postgres/compute` and `vault/{graph_id}` grants and the live documents below.
These are reserved service selections (`compute`, `graph`), not external
connection UUIDs. DB-sink defaults are exact configured-table insert grants;
secret-reader defaults are configured-name read/describe and metadata-only list
grants. Advanced operation/resource ceilings remain available, and deletion
requires independent explicit organization authority. Fresh minting re-reads
actor membership, declarations and secret inventory under the organization lock;
stale cell metadata cannot restore a revoked grant.

PostgreSQL and SecretStore consume the same mandatory live documents as native
connectors: `connector-policy/{org}/{provider}/{connection}`,
`thirdparty/{provider}/{user}/{connection}/permissions`, and
`connector-authority/{org}/{run}/{warrant-id}`. The first two contain scopes and
byte bounds; the run projection binds account, cell and warrant capabilities.
They are fetched fresh for each operation. `NativeOperation` retains the actual
grant, exact four-ceiling authority, and `NativeCeilings` attenuation witnesses;
its four `live_*_permits` and `live_request_bounded` theorems prove confinement to
the documents used by execution. The outbound account also comes from this same
witness, not a separately supplied string. Request ceilings cannot exceed these
independently stored documents; missing/malformed documents never enable a local
fallback. See the sibling liaison `docs/connector-permissions.md` for their shapes.

* **Compute:** provider `postgres`, connection `compute`, operations `rows.select`,
  `rows.insert`, `rows.update`, `rows.delete`, selectors `[schema,table]`.
  `AuthorizedQuery` consumes Linen's structured parameterized query AST and
  evidence that the query's schema is exactly the binding's schema. There is no
  raw SQL API. Table identifiers have a proved 63 UTF-8 byte bound, preventing
  PostgreSQL identifier truncation from changing the authorized table.
  Credentials resolve only at `compute/{org}/{user}` and must contain
  kind `postgres`, `base_url` host:port, database, schema and token. `BoundCompute`
  has a private constructor and proves that compiled target/role match that
  credential and the bound schema. Connections derive exclusively from the
  resolved credential. Actual results are checked against the response ceiling.
* **Graph vault:** provider `vault`, connection equal to `graph_id`, operations
  `secrets.read`, `secrets.write`, `secrets.describe`, `secrets.list`. Names are
  relative structured selectors. Only `graph/{org}/{graph}/...` is derived.
  Reads/writes use UTF-8 `{value:...}` documents. Metadata describe and listing
  never disclose the plaintext to the function. Historical-version reads and
  pagination cursors are explicitly unsupported and fail closed.
* **ObjectStore:** exactly one S3/Azure grant must bind the capability's bucket
  using the record's optional `bucket` field. Get/head/list/put/delete map to
  native `objects.*`; head consumes read authority and uses the native read.
  UTF-8 writes with no metadata overrides are supported (`putString` callers
  pass `opts := {}`). Binary writes, custom content type/cache-control/metadata,
  and caller-supplied pagination cursors are refused. List results are validated
  against the authorized component prefix before disclosure.

## Anonymous HTTP and temporary files

`AuthorizedHTTP` carries static method/URL scope, organization effect/domain
permission, standard-port evidence and a public numeric DNS address. All DNS
answers must be public. The transport connects to the checked numeric address,
preserving the original Host and TLS SNI/verification. Host labels are validated;
path components refuse dot/percent/separator ambiguity and are URL-encoded only
after scope checking. It never re-resolves the
host or follows redirects. Notebook-controlled authorization/proxy/Host/framing
headers and invalid path/header bytes are refused.

`TemporaryPath` carries static operation scope, safe relative components and a
valid organization/user binding. The trusted `temporary.py` adapter derives
`{LUN_TEMP_ROOT-or-/tmp/typednotes}/{org}/{user}/{relative-path}`. Its descriptor-
relative `openat` operations refuse symlinks at every descendant including the
root; reads refuse non-regular files and hard links. Writes replace a fresh inode
atomically, so a planted final symlink/hardlink cannot overwrite its target.
Reads/deletes never create directories. Runtime image needs Python 3; generated
drivers also require the libpq development/linker flags discovered by pkg-config.

## Explicit trusted boundaries

Kernel proofs establish the Lean model and witness consumption, not a general
process sandbox. Project executable closures (including JSON dictionaries) are
audited transitively for unsafe/extern/implemented_by, axioms, initializers,
custom runners and raw IO/runtime entry points. The trusted module set consists
of exact runtime imports, not spoofable namespace prefixes. Graph shape/wiring
checks additionally rebind all implementations to the checked declared functions.

The Lean compiler/kernel and approved runtime/library implementations, build
container isolation (lakefiles/metaprograms execute during builds), libpq/socket/
TLS FFI, descriptor-relative Python syscalls, PostgreSQL role/schema ACLs and
server-side trigger/view semantics remain trusted. Local service authorization
trusts the authenticated app caller/minting service and vault ACL-protected run
projections; HMAC is independently verified by liaison for outbound connectors.
These local checks are not a claim of an independently verified local HMAC tag.
Do not expose `LUN_TOKEN` to notebook users or allow generated code to write policy,
minting, compute credential, or other organizations' vault namespaces.

Organization-shared external connections may have a credential owner different
from the actor's `user_id`. The named connection must match the account leaf;
the broker's independent run projection binds the owner, and local ObjectStore
preflight reads that owner's connection ceiling. Compute and graph-vault grants
require the bound actor's account. Session updates cannot change either account.

## Verified app integration and deployment requirements

App registration, feeds and scheduled calls supply authenticated bindings,
organization policy and fresh function-name grants. The app provisions local
compute/graph-vault authority, separates external credential owners from execution
actors, and sends `recoverInputs:true` for recorded source adoption. Writer launch
forwards organization `tools`; messages/refresh preserve the live tool intersection
and cannot restore removed operations. Trusted writer conversation/publication
projections and all native repository/model modes now execute in the verified
whole pipeline; they are not pending runtime/caller blockers.

Deployment must apply the coordinated migrations and separated vault ACLs,
configure private service identities, and use the coordinated release pins.
Those deployment/release actions remain operator/parent-owned. Missing or malformed
authority continues to produce a structured refusal.

## Verification

Use the local sibling override workspace while these modules are unpublished:

```sh
LEAN_NUM_THREADS=2 lake build lun:exe liaison:exe +LunTest +LinenTest.Linen.Control.Monad.Effect.ConnectorTest
LUN_E2E_WORKSPACE=/path/to/override/workspace LEAN_NUM_THREADS=2 test/e2e.sh ../linen
python3 test/temporary_test.py /path/to/scratch
PATH=/path/to/postgresql/bin:$PATH python3 test/runtime.py --temp-root /path/to/scratch --public-http
```

The final command uses compiled drivers, a real broker/HMAC/ledger, a disposable
SCRAM-authenticated compute role, and disposable vault/provider HTTP peers. It
checks permitted effects, denied live ceilings, no rejected provider writes or
credential reads, cross-schema/user/graph boundaries, malformed grants, typed
input refusal/recovery, and monotonic session updates. `--public-http` additionally
performs a credential-free TLS GET to example.org; it never invokes a paid model.
Linux/container and remote provider conformance remain separate verification axes.

Local verification: the full Lun end-to-end suite passes, including caller-owned
source/output types, named wiring, raw-subject/observable refusals and executable
closure auditing. `runtime.py --public-http` passes **69 compiled-driver cases**,
including real SCRAM queries, graph-vault reads/writes, actual HMAC broker/SigV4
roundtrips, shared credential owners, live four-ceiling denials, byte limits,
credential target substitution, historic-input recovery and connector session
attenuation/revocation. The temporary syscall suite passes five groups. The local
workspace builds `LunTest`, `LodeTest`, and Linen's connector proof/tests; Lode's
native fixture passes actual tool-dispatch denial, in-flight narrowing and restart
persistence against its fake model broker. Separately, the actual app → compiled
Lode → real broker → local Git → compiled Lun positive/denial pipeline passes
checkout, generation/tool execution, Lake check, independent deletion authority,
atomic publication, adoption and source constraints/recovery. App API tests pass
**99 cases**, browser regression **24 groups**, and the independent Liaison suite
**655 real HTTP cases** with zero catalog gaps. Provider replies are local controlled
fixtures; paid-provider/OAuth conformance and real-model quality remain unmeasured.
