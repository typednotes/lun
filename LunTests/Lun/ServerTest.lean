/-
  Tests for `Lun.Server`'s pure parts.
-/
import Lun.Server

open Lun

namespace LunTests.Server

#guard constantTimeEq "Bearer abc" "Bearer abc"
#guard !constantTimeEq "Bearer abc" "Bearer abd"
#guard !constantTimeEq "Bearer abc" "Bearer ab"
#guard !constantTimeEq "" "x"

#guard (statusOf 202).statusCode == 202
#guard (statusOf 504).statusCode == 504
#guard (statusOf 418).statusCode == 500

end LunTests.Server
