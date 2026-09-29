import Lake
open System Lake DSL

-- `lun` links linen's native code (TLS for its HTTP client, OpenSSL's
-- SHA-256) but none of its pkg-config libraries (no Postgres), so unlike
-- `liaison` it needs no extra link arguments: Lean's toolchain links OpenSSL
-- statically into every executable already.

require linen from git "https://github.com/typednotes/linen" @ "v1.9.2"

-- For `Liaison.Wire` only: liaison's wire format (`POST /v0/egress`), the
-- module liaison's own server parses with. It is pure and imports none of
-- liaison's HMAC, Postgres or egress code, so it adds no link arguments.
require liaison from git "https://github.com/typednotes/liaison" @ "v0.5.5"

package lun where
  version := v!"0.2.5"
  testDriver := "LunTest"

-- The driver runtime, embedded in `Lun.Driver` with `include_str`. Lake does
-- not see through `include_str`, so without this `needs` an edited runtime
-- would leave the embedded copy stale.
input_file driverRuntime where
  path := "template/LunDriver/Runtime.lean"
  text := true

@[default_target]
lean_lib Lun where
  needs := #[driverRuntime]

-- Named `LunTest` (module tree `LunTest.*`), the `{Package}Test` convention
-- of mathlib, batteries and aesop, and the package's `testDriver` (`lake test`).
lean_lib LunTest where
  precompileModules := true

@[default_target]
lean_exe lun where
  root := `Main

-- `Examples/Client.lean`: lun from a client's side (build a project, register
-- a graph as a session, update its inputs). `Examples/run.sh` runs it against
-- a local lun.
lean_exe «lun-example» where
  root := `Examples.Client
