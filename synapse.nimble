mode = ScriptMode.Verbose

### Package
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Synapse, Private P2P Messaging for Resource-Restricted Devices"
license       = "MIT or Apache License 2.0"
#bin           = @["build/synapse"]

### Dependencies
requires "nim >= 1.6.0",
  "chronicles",
  "confutils",
  "chronos",
  "eth",
  "json_rpc",
  "libbacktrace",
  "nimcrypto",
  "stew",
  "stint",
  "metrics",
  "libp2p", # Only for Synapse v2
  "web3",
  "presto",
  "regex"

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc buildLibrary(name: string, srcDir = "./", params = "", `type` = "static") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  if `type` == "static":
    exec "nim c" & " --out:build/" & name & ".a --threads:on --app:staticlib --opt:size --noMain --header " & extra_params & " " & srcDir & name & ".nim"
  else:
    exec "nim c" & " --out:build/" & name & ".so --threads:on --app:lib --opt:size --noMain --header " & extra_params & " " & srcDir & name & ".nim"

### Synapse tasks
task synapse, "Build Synapse cli node":
  let name = "synapse"
  buildBinary name, "apps/synapse/"

task synapsecanary, "Build synapse-canary tool":
  let name = "synapsecanary"
  buildBinary name, "apps/synapsecanary/"

task networkmonitor, "Build network monitor tool":
  let name = "networkmonitor"
  buildBinary name, "apps/networkmonitor/"

task rln_db_inspector, "Build the rln db inspector":
  let name = "rln_db_inspector"
  buildBinary name, "tools/rln_db_inspector/"

### C Bindings
task libwakuStatic, "Build the cbindings synapse node library":
  let name = "libwaku"
  buildLibrary name, "library/", "-d:chronicles_log_level=ERROR", "static"

task libwakuDynamic, "Build the cbindings synapse node library":
  let name = "libwaku"
  buildLibrary name, "library/", "-d:chronicles_log_level=ERROR", "dynamic"
