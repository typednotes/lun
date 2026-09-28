/-
  Tests for `Lun.Server`'s pure parts.
-/
import Lun.Server

open Lun

namespace LunTests.Server

-- (The token comparison is linen's `Crypto.ConstantTime`, tested there.)
#guard (statusOf 201).statusCode == 201
#guard (statusOf 202).statusCode == 202
#guard (statusOf 504).statusCode == 504
#guard (statusOf 418).statusCode == 500

end LunTests.Server
