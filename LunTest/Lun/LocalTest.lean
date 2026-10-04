import Lun.Local

open Lun

namespace LunTests.Local

#guard Local.excluded ".git"
#guard Local.excluded ".lake"
#guard Local.excluded ".lun"
#guard !Local.excluded "Local.lean"
#guard Validate.localDirectory "/tmp/local project"
#guard !Validate.localDirectory "/tmp/../project"
#guard !Validate.localDirectory "./project"
#guard !Validate.localDirectory "/tmp/project\n"

end LunTests.Local
