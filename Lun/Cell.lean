/- Shared native cell contracts, compiler attestations and admission.
   This module is also copied verbatim into generated driver packages. -/
import Linen.System.Cell

namespace Lun.Cell

open Lean (Json ToJson FromJson toJson fromJson?)
open System (FilePath)

/-- The native invocation/producer envelope, independently selected by Lun. -/
def runtimeAbi : String := "lun-native-cell-v1"

/-- The transitive executable, canonical handler and graph audit used by Lun. -/
def auditVersion : String := "lun-closure-audit-v1"

/-- A checked entry point's immutable source and ordered Lean signature.
    Producer clock/continuation arguments belong to the invocation envelope. -/
structure Contract where
  source : System.Cell.GitSource
  signature : String
  arity : Nat
  producer : Bool
  deriving DecidableEq, Repr, ToJson, FromJson

/-- Bind the formal contract and its codecs to the exact pinned source.
    A codec change at a later source revision cannot reuse this identity. -/
def Contract.ref (contract : Contract) : IO (System.Cell.Ref .contract) := do
  return ⟨← System.Cell.Digest.ofBytes
    (Json.arr #["lun.cell.contract.v1", toJson contract]).compress.toUTF8⟩

/-- Host profile for the versioned invocation adapter, never read from a package. -/
def Contract.runtime (contract : Contract) : IO System.Cell.Runtime := do
  let codec ← System.Cell.Digest.ofBytes
    (Json.arr #["lun.cell.codecs.v1", toJson (← contract.ref)]).compress.toUTF8
  return { leanToolchain := "leanprover/lean4:v" ++ Lean.versionString
           target := System.Platform.target, runtimeAbi, auditVersion, codecSha256 := ⟨codec⟩ }

/-- An explicit cursor wrapper preserves `some Json.null` across JSON encoding. -/
structure Continuation where
  value : Json
  deriving ToJson, FromJson

/-- Readiness runs no user code; execution always carries a fresh invocation. -/
inductive Mode where
  | warm | call
  deriving DecidableEq, ToJson, FromJson

/-- Fresh authority travels only in this private worker message. It is never
    included in a manifest or in caller-owned graph state. -/
structure Invocation where
  mode : Mode := .call
  name : String
  contract : Contract
  arguments : List Json
  context : Json
  now : Nat := 0
  continuation : Option Continuation := none
  deriving ToJson, FromJson

/-- A cell's outcome and bounded request-local diagnostics. -/
structure Reply where
  outcome : Json
  log : String
  deriving ToJson, FromJson

/-- The native transport's signature; the generated function dictionaries
    additionally check the actual Lean arguments, output and continuation. -/
abbrev wireSignature : System.Cell.Signature :=
  { Input := Invocation, Output := fun _ => Reply, effects := [] }

/-- Bind independent input/result validators to the signed wire identities. -/
def codecs (contract : Contract)
    (checkInput : Invocation → Except String Unit)
    (checkOutput : Invocation → Reply → Except String Unit) : IO (System.Cell.Codecs wireSignature) := do
  return {
    contract := ← contract.ref, id := (← contract.runtime).codecSha256
    encodeInput := fun input => [toJson input]
    decodeInput := fun args => do
      let [input] := args | throw "a Lun cell expects one invocation envelope"
      let input ← fromJson? input
      unless input.contract == contract do throw "cell invocation contract mismatch"
      checkInput input
      return input
    encodeOutput := fun _ => toJson
    decodeOutput := fun input json => do
      let reply ← fromJson? json
      unless reply.log.utf8ByteSize ≤ 1024 * 1024 do throw "cell Trace exceeds 1 MiB"
      checkOutput input reply
      return reply }

/-- A compiler-created placement, kept with the ready build. Callers cannot
    replace the directory, pin or contract through a graph request. -/
structure Binding where
  name : String
  directory : String
  pin : System.Cell.Ref .manifest
  contract : Contract
  deriving ToJson, FromJson

/-- Trusted compiler configuration. The signing home is never inherited by
    project builds or execution workers; only the public keyring reaches calls. -/
structure Compiler where
  fingerprint : String
  keyring : FilePath
  home : FilePath

/-- Check a compiler configuration before accepting work. No keys are created. -/
def Compiler.check (compiler : Compiler) : IO Unit := do
  unless [40, 64].contains compiler.fingerprint.length &&
      (Data.Hex.decode compiler.fingerprint).isSome do
    throw (IO.userError "LUN_CELL_SIGNING_KEY must be a complete OpenPGP fingerprint")
  unless ← compiler.home.isDir do throw (IO.userError "LUN_CELL_SIGNING_HOME must be an existing directory")
  unless ← compiler.keyring.pathExists do throw (IO.userError "LUN_CELL_KEYRING must name the trusted compiler public keyring")

/-- Verify the independent placement/profile and compiler signature before
    retaining executable bytes. All graph cells are admitted before effects. -/
def Binding.admit (binding : Binding) (expected : Contract) (keyring : FilePath) : IO System.Cell.Verified := do
  unless binding.contract == expected do throw (IO.userError s!"cell '{binding.name}' has a different contract")
  let package ← System.Cell.openPackage
    { pin := binding.pin, runtime := ← expected.runtime, keyring }
    (.local ⟨binding.directory⟩)
  unless package.manifest.revision.source == expected.source &&
      package.manifest.revision.contractSha256 == (← expected.ref) do
    throw (IO.userError s!"cell '{binding.name}' has a different source or contract")
  return package

/-- A private invocation port into one scoped worker. It contains no authority;
    callers supply a fresh envelope on every invocation. -/
abbrev Runner := Invocation → IO Reply

/-- Reuse Linen's owned local worker across a graph step without exporting its
    process handle. The service task alone owns the indexed `Local` program.
    Failed workers terminate the scope; requests are never replayed. -/
def withRunner (package : System.Cell.Verified) (adapter : System.Cell.Codecs wireSignature)
    (timeoutMillis : Nat) (action : Runner → IO α) : IO α := do
  let pending ← IO.mkRef (none : Option (Invocation × IO.Ref (Option (Except String Reply))))
  let stopped ← IO.mkRef false
  let failure ← IO.mkRef (none : Option String)
  let receive : IO (Option (Invocation × IO.Ref (Option (Except String Reply)))) := do
    repeat
      if let some call ← pending.swap none then return some call
      if ← stopped.get then return none
      IO.sleep 1
  let service ← IO.asTask (prio := .dedicated) do
    try
      package.runLocal adapter do
        repeat
          let some (input, result) ← Control.Resource.Program.lift receive | break
          let reply ← System.Cell.Local.call (sig := wireSignature) input timeoutMillis
          Control.Resource.Program.lift (result.set (some reply))
    catch error => failure.set (some (toString error))
    finally stopped.set true
  let call : Runner := fun input => do
    let result ← IO.mkRef none
    pending.set (some (input, result))
    repeat
      if let some reply ← result.get then
        return ← IO.ofExcept (reply.mapError IO.userError)
      if let some error ← failure.get then throw (IO.userError error)
      if ← stopped.get then throw (IO.userError "native cell worker stopped")
      IO.sleep 1
  try action call
  finally
    stopped.set true
    let _ ← IO.wait service

/-- Content fingerprint of a source/object tree, excluding bookkeeping by
    component. Regular files are hashed in stable relative-path order. -/
def hashTree (root : FilePath) (excluded : List String := [".git", ".lake", ".lun"]) : IO System.Cell.Digest := do
  let mut pending := [(root, "")]
  let mut files : Array (String × String) := #[]
  let mut count := 0
  repeat
    let (dir, stem) :: rest := pending | break
    pending := rest
    for entry in ← dir.readDir do
      if excluded.contains entry.fileName then continue
      count := count + 1
      unless count ≤ 1000000 do throw (IO.userError "cell compiler input tree is too large")
      let relative := stem ++ entry.fileName
      match (← entry.path.symlinkMetadata).type with
      | .dir => pending := (entry.path, relative ++ "/") :: pending
      | .file =>
        let digest ← System.Cell.Digest.ofBytes (← IO.FS.readBinFile entry.path)
        files := files.push (relative, digest.hex)
      | _ => throw (IO.userError s!"cell compiler input is not a regular file: {entry.path}")
  System.Cell.Digest.ofBytes (toJson (files.qsort (fun a b => a.1 < b.1))).compress.toUTF8

/-- Fingerprint Lake's quoted linker response and each explicit file input.
    Runtime/toolchain identities cover the host-provisioned system libraries. -/
def hashLinkInputs (response : FilePath) (extra : List String) : IO System.Cell.Digest := do
  let text ← IO.FS.readFile response
  let mut inputs : List (String × String) := []
  for line in text.splitOn "\n" do
    if line.trimAscii.isEmpty then continue
    let arg ← IO.ofExcept ((Json.parse line >>= Json.getStr?).mapError IO.userError)
    let path : FilePath := arg
    if path.isAbsolute && (← path.pathExists) && !(← path.isDir) then
      inputs := (arg, (← System.Cell.Digest.ofBytes (← IO.FS.readBinFile path)).hex) :: inputs
  System.Cell.Digest.ofBytes (toJson (text, extra, inputs)).compress.toUTF8

/-- Attest local compiler outputs after the checks/build have succeeded.
    The worker multiplexes only the listed, audited contracts. Each manifest
    fixes one entry point; execution checks it again inside the worker.
    These are build artifacts, not publication to an external registry. -/
def Compiler.package (compiler : Compiler) (directory worker : FilePath)
    (contracts : List (String × Contract)) (inputs : System.Cell.BuildInputs)
    (intent policy : Json) : IO (List Binding) := do
  compiler.check
  let artifact ← System.Process.readBounded (← IO.FS.Handle.mk worker .read) System.Cell.maxArtifactBytes
  IO.FS.createDirAll directory
  -- Package storage must never share an inode with the executing graph driver:
  -- changing a package must not modify or invalidate the executor's code pages.
  let payload := directory / ".worker"
  IO.FS.writeBinFile payload artifact
  let intent := System.Cell.Digest.ofBytes intent.compress.toUTF8
  let policy := System.Cell.Digest.ofBytes policy.compress.toUTF8
  let intent ← intent
  let policy ← policy
  contracts.mapM fun (name, contract) => do
    let dir := directory / name
    IO.FS.createDirAll dir
    -- Hard links share immutable build bytes, avoiding a full executable copy
    -- per placement. Admission still hashes and retains those exact bytes.
    let linked ← System.Process.run "ln" #[payload.toString, (dir / "worker").toString] 5000
    unless linked.ok do throw (IO.userError (linked.describe "linking native cell worker"))
    let manifest ← System.Cell.Manifest.make
      { intentSha256 := ⟨intent⟩, constraintsSha256 := ⟨policy⟩,
        contractSha256 := ← contract.ref, source := contract.source }
      inputs (← contract.runtime) artifact
    -- Select the signing home only for this trusted compiler operation.
    let signed ← System.Process.run "gpg"
      #["--no-options", "--homedir", compiler.home.toString, "--batch", "--no-tty",
        "--pinentry-mode", "cancel", "--armor", "--detach-sign", "--local-user",
        compiler.fingerprint ++ "!", "--output", "-"] 30000 (input := some manifest.render)
    unless signed.ok do throw (IO.userError "cell compiler signing failed")
    IO.FS.writeFile (dir / "manifest.asc") signed.stdout
    IO.FS.writeFile (dir / "manifest.json") manifest.render
    let binding := { name, directory := dir.toString, pin := ← System.Cell.manifestPin manifest.render, contract }
    discard <| binding.admit contract compiler.keyring
    return binding

end Lun.Cell
