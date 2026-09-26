import Lake
open System Lake DSL

-- `lun` links linen's native code (TLS for its HTTP client, OpenSSL's
-- SHA-256) but none of its pkg-config libraries (no Postgres), so unlike
-- `liaison` it needs no extra link arguments: Lean's toolchain links OpenSSL
-- statically into every executable already.

require linen from git "https://github.com/typednotes/linen" @ "v1.2.0"

package lun where
  version := v!"0.1.0"

@[default_target]
lean_lib Lun where

-- Named `LunTests` (module tree `LunTests.*`), not `Tests`: `linen` has its
-- own `Tests.*` tree, and two packages declaring the same top-level module
-- prefix confuse Lake's module lookup (see `liaison/lakefile.lean`).
lean_lib LunTests where
  precompileModules := true

@[default_target]
lean_exe lun where
  root := `Main
