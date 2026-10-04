import Lun.Cli

namespace LunTests.Cli

open Lun.Cli

#guard (Request.parse "{\"method\":\"GET\",\"path\":\"/_health\"}").toOption.map (·.path) == some ["_health"]
#guard (Request.parse "{\"method\":\"POST\",\"path\":\"/v0/builds\",\"body\":{}}").toOption.map (·.waitBuild) == some true
#guard (Request.parse "{\"method\":\"POST\",\"path\":\"/v0/builds\",\"wait\":false}").toOption.map (·.waitBuild) == some false
#guard (Request.parse "[]").toOption.isNone
#guard (Request.parse "{\"method\":\"PUT\",\"path\":\"/_health\"}").toOption.isNone
#guard (Request.parse "{\"method\":\"GET\",\"path\":\"_health\"}").toOption.isNone
#guard (Request.parse "{\"method\":\"GET\",\"path\":\"/_health?x=y\"}").toOption.isNone
#guard (Request.parse "{\"method\":\"GET\",\"path\":\"/_health\",\"body\":[]}").toOption.isNone
#guard (Request.parse "{\"method\":\"GET\",\"path\":\"/_health\",\"wait\":1}").toOption.isNone
#guard (Request.parse "{\"method\":\"POST\",\"path\":\"/v0/builds\",\"body\":{\"source\":{},\"source\":{}}}").toOption.isNone

end LunTests.Cli
