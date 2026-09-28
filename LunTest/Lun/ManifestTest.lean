/-
  Tests for `Lun.Manifest`: a project may depend on linen, from its GitHub
  repository, and on nothing else.
-/
import Lun.Manifest

open Lun.Manifest

namespace LunTests.Manifest

def manifest (packages : String) (name := "proj") : String :=
  s!"\{\"version\": \"1.2.0\", \"packagesDir\": \".lake/packages\", \"name\": \"{name}\", \"packages\": [{packages}]}"

def linenGit (url := "https://github.com/typednotes/linen") : String :=
  s!"\{\"type\": \"git\", \"name\": \"linen\", \"url\": \"{url}\", \"rev\": \"32dafdf\", \"inputRev\": \"v1.3.0\"}"

def linenPath : String := "{\"type\": \"path\", \"name\": \"linen\", \"dir\": \"../linen\"}"

def other : String :=
  "{\"type\": \"git\", \"name\": \"mathlib\", \"url\": \"https://github.com/leanprover-community/mathlib4\", \"rev\": \"1\"}"

def verdict (text : String) (allowPath := false) : String :=
  match parse text >>= fun m => check m allowPath with
  | .ok () => "ok"
  | .error e => e

#guard verdict (manifest "") == "ok"
#guard verdict (manifest (linenGit)) == "ok"
#guard verdict (manifest (linenGit "https://github.com/typednotes/linen.git")) == "ok"
#guard verdict (manifest (linenGit "https://github.com/evil/linen")) != "ok"
#guard verdict (manifest s!"{linenGit}, {other}") != "ok"
#guard verdict (manifest linenPath) != "ok"
#guard verdict (manifest linenPath) (allowPath := true) == "ok"
#guard verdict (manifest "" (name := "bad name")) != "ok"
#guard verdict "not json" != "ok"

#guard (parse (manifest (linenGit))).toOption.bind linenRev? == some "32dafdf"
#guard (parse (manifest linenPath)).toOption.bind linenRev? == none
#guard (parse (manifest (linenGit))).toOption.map (·.name) == some "proj"

end LunTests.Manifest
