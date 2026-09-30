/-
  Tests for `Lun.Fetch`'s pure parts: the host API URLs, percent-encoding,
  and the tarball redirect allow-list.
-/
import Lun.Fetch

open Lun.Fetch

namespace LunTests.Fetch

def nativeEntry (path mode : String) := Lean.Json.mkObj [("path", Lean.Json.str path), ("mode", Lean.Json.str mode)]
#guard (NativeFile.ofJson (nativeEntry "src/Main.lean" "100644")).toOption.isSome
#guard (NativeFile.ofJson (nativeEntry "bin/run" "100755")).toOption.isSome
#guard ["../outside", "src/../outside", "/outside", "a%2Fb", ".git/config", ".GIT/config", ".LaKe/cache"].all
  (fun path => (NativeFile.ofJson (nativeEntry path "100644")).toOption.isNone)
#guard (NativeFile.ofJson (nativeEntry "link" "120000")).toOption.isNone
#guard (NativeFile.ofJson (nativeEntry "submodule" "160000")).toOption.isNone

#guard percentEncode "abc-._~XYZ09" == "abc-._~XYZ09"
#guard percentEncode "a/b c" == "a%2Fb%20c"
#guard percentEncode "é" == "%C3%A9"

def sha := "dc19b371d09f409810678d8b35dbb381afecf272"

#guard githubUrls "o" "r" "feature/x" sha ==
  ( s!"https://api.github.com/repos/o/r/compare/feature/x...{sha}?per_page=1"
  , s!"https://api.github.com/repos/o/r/tarball/{sha}" )

#guard gitlabUrls ["g", "sub", "p"] "feature/x" sha ==
  ( s!"https://gitlab.com/api/v4/projects/g%2Fsub%2Fp/repository/merge_base?refs%5B%5D=feature%2Fx&refs%5B%5D={sha}"
  , s!"https://gitlab.com/api/v4/projects/g%2Fsub%2Fp/repository/archive.tar.gz?sha={sha}" )

#guard isCodeloadUrl "https://codeload.github.com/o/r/legacy.tar.gz/abc?token=x"
#guard !isCodeloadUrl "http://codeload.github.com/o/r"
#guard !isCodeloadUrl "https://codeload.github.com.evil.com/o/r"

end LunTests.Fetch
