when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  chronicles,
  ./node_spec as Waku,
  ./stealth_commitment_protocol as SCP

logScope:
  topics = "waku stealthcommitments"

when isMainModule:
  ## Logging setup

  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color =
    try:
      not parseBool(os.getEnv("NO_COLOR", "false"))
    except CatchableError:
      true

  logging.setupLogLevel(logging.LogLevel.INFO)
  logging.setupLogFormat(logging.LogFormat.TEXT, color)
  
  info "Starting Waku Stealth Commitment Protocol"
  info "Starting Waku Node"
  let node = Waku.setup()
  info "Waku Node started, listening for StealthCommitmentMessages"
  let scp = SCP.new(node).valueOr:
    error "Could not start Stealth Commitment Protocol", error = $error
    quit(1)
  
  try:
    info "Sending stealth commitment request"
    (waitFor scp.sendRequest()).isOkOr:
      error "Could not send stealth commitment request", error = $error
  except:
    error "Could not send stealth commitment request", error = getCurrentExceptionMsg()

  runForever()
