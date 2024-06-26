import
  std/[options, sequtils],
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/nameresolving/dnsresolver,
  libp2p/crypto/crypto

import
  ./internal_config,
  ./external_config,
  ./builder,
  ./validator_signed,
  ../waku_enr/sharding,
  ../waku_node,
  ../waku_core,
  ../waku_rln_relay,
  ../waku_dnsdisc,
  ../waku_archive,
  ../waku_store,
  ../waku_filter,
  ../waku_filter_v2,
  ../waku_peer_exchange,
  ../node/peer_manager,
  ../node/peer_manager/peer_store/waku_peer_storage,
  ../node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../waku_lightpush/common,
  ../waku_archive/driver/builder,
  ../waku_archive/retention_policy/builder,
  ../common/utils/parse_size_units

## Peer persistence

const PeerPersistenceDbUrl = "peers.db"
proc setupPeerStorage*(): Result[Option[WakuPeerStorage], string] =
  let db = ? SqliteDatabase.new(PeerPersistenceDbUrl)

  ? peer_store_sqlite_migrations.migrate(db)

  let res = WakuPeerStorage.new(db)
  if res.isErr():
    return err("failed to init peer store" & res.error)

  ok(some(res.value))

## Retrieve dynamic bootstrap nodes (DNS discovery)

proc retrieveDynamicBootstrapNodes*(dnsDiscovery: bool,
                                    dnsDiscoveryUrl: string,
                                    dnsDiscoveryNameServers: seq[IpAddress]):
                                    Result[seq[RemotePeerInfo], string] =

  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Synapse DNS discovery", url=dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Synapse DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

## Init synapse node instance

proc initNode*(conf: WakuNodeConf,
              netConfig: NetConfig,
              rng: ref HmacDrbgContext,
              nodeKey: crypto.PrivateKey,
              record: enr.Record,
              peerStore: Option[WakuPeerStorage],
              dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[]): Result[WakuNode, string] =

  ## Setup a basic Synapse v2 node based on a supplied configuration
  ## file. Optionally include persistent peer storage.
  ## No protocols are mounted yet.

  var dnsResolver: DnsResolver
  if conf.dnsAddrs:
    # Support for DNS multiaddrs
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    dnsResolver = DnsResolver.new(nameServers)

  var node: WakuNode

  let pStorage = if peerStore.isNone(): nil
                 else: peerStore.get()

  # Build synapse node instance
  var builder = WakuNodeBuilder.init()
  builder.withRng(rng)
  builder.withNodeKey(nodekey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withPeerStorage(pStorage, capacity = conf.peerStoreCapacity)
  builder.withSwitchConfiguration(
      maxConnections = some(conf.maxConnections.int),
      secureKey = some(conf.websocketSecureKeyPath),
      secureCert = some(conf.websocketSecureCertPath),
      nameResolver = dnsResolver,
      sendSignedPeerRecord = conf.relayPeerExchange, # We send our own signed peer record when peer exchange enabled
      agentString = some(conf.agentString)
  )
  builder.withColocationLimit(conf.colocationLimit)
  builder.withPeerManagerConfig(
    maxRelayPeers = conf.maxRelayPeers,
    shardAware = conf.relayShardedPeerManagement,)

  node = ? builder.build().mapErr(proc (err: string): string = "failed to create synapse node instance: " & err)

  ok(node)

## Mount protocols

proc setupProtocols*(node: WakuNode,
                    conf: WakuNodeConf,
                    nodeKey: crypto.PrivateKey):
                    Future[Result[void, string]] {.async.} =
  ## Setup configured protocols on an existing Synapse v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.

  node.mountMetadata(conf.clusterId).isOkOr:
    return err("failed to mount synapse metadata protocol: " & error)

  # Mount relay on all nodes
  var peerExchangeHandler = none(RoutingRecordsHandler)
  if conf.relayPeerExchange:
    proc handlePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe.} =
      ## Handle peers received via gossipsub peer exchange
      # TODO: Only consider peers on pubsub topics we subscribe to
      let exchangedPeers = peers.filterIt(it.record.isSome()) # only peers with populated records
                                .mapIt(toRemotePeerInfo(it.record.get()))

      debug "connecting to exchanged peers", src=peer, topic=topic, numPeers=exchangedPeers.len

      # asyncSpawn, as we don't want to block here
      asyncSpawn node.connectToNodes(exchangedPeers, "peer exchange")

    peerExchangeHandler = some(handlePeerExchange)

  if conf.relay:
    let pubsubTopics =
      if conf.pubsubTopics.len > 0 or conf.contentTopics.len > 0:
        # TODO autoshard content topics only once.
        # Already checked for errors in app.init
        let shards = conf.contentTopics.mapIt(getShard(it).expect("Valid Shard"))
        conf.pubsubTopics & shards
      else:
        conf.topics

    let parsedMaxMsgSize = parseMsgSize(conf.maxMessageSize).valueOr:
      return err("failed to parse 'max-num-bytes-msg-size' param: " & $error)

    debug "Setting max message size", num_bytes=parsedMaxMsgSize

    try:
      await mountRelay(node, pubsubTopics, peerExchangeHandler = peerExchangeHandler,
                       int(parsedMaxMsgSize))
    except CatchableError:
      return err("failed to mount synapse relay protocol: " & getCurrentExceptionMsg())

    # Add validation keys to protected topics
    var subscribedProtectedTopics : seq[ProtectedTopic]
    for topicKey in conf.protectedTopics:
      if topicKey.topic notin pubsubTopics:
        warn "protected topic not in subscribed pubsub topics, skipping adding validator",
              protectedTopic=topicKey.topic, subscribedTopics=pubsubTopics
        continue
      subscribedProtectedTopics.add(topicKey)
      notice "routing only signed traffic", protectedTopic=topicKey.topic, publicKey=topicKey.key
    node.wakuRelay.addSignedTopicsValidator(subscribedProtectedTopics)

    # Enable Rendezvous Discovery protocol when Relay is enabled
    try:
      await mountRendezvous(node)
    except CatchableError:
      return err("failed to mount synapse rendezvous protocol: " & getCurrentExceptionMsg())

  # Keepalive mounted on all nodes
  try:
    await mountLibp2pPing(node)
  except CatchableError:
    return err("failed to mount libp2p ping protocol: " & getCurrentExceptionMsg())

  var onFatalErrorAction = proc(msg: string) {.gcsafe, closure.} =
    ## Action to be taken when an internal error occurs during the node run.
    ## e.g. the connection with the database is lost and not recovered.
    error "Unrecoverable error occurred", error = msg
    quit(QuitFailure)

  if conf.rlnRelay:
    when defined(rln_v2):
      let rlnConf = WakuRlnConfig(
        rlnRelayDynamic: conf.rlnRelayDynamic,
        rlnRelayCredIndex: conf.rlnRelayCredIndex,
        rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
        rlnRelayEthClientAddress: string(conf.rlnRelayethClientAddress),
        rlnRelayCredPath: conf.rlnRelayCredPath,
        rlnRelayCredPassword: conf.rlnRelayCredPassword,
        rlnRelayTreePath: conf.rlnRelayTreePath,
        rlnRelayUserMessageLimit: conf.rlnRelayUserMessageLimit,
        rlnEpochSizeSec: conf.rlnEpochSizeSec,
        onFatalErrorAction: onFatalErrorAction,
      )
    else:
      let rlnConf = WakuRlnConfig(
        rlnRelayDynamic: conf.rlnRelayDynamic,
        rlnRelayCredIndex: conf.rlnRelayCredIndex,
        rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
        rlnRelayEthClientAddress: string(conf.rlnRelayethClientAddress),
        rlnRelayCredPath: conf.rlnRelayCredPath,
        rlnRelayCredPassword: conf.rlnRelayCredPassword,
        rlnRelayTreePath: conf.rlnRelayTreePath,
        rlnEpochSizeSec: conf.rlnEpochSizeSec,
        onFatalErrorAction: onFatalErrorAction,
      )

    try:
      waitFor node.mountRlnRelay(rlnConf)
    except CatchableError:
      return err("failed to mount synapse RLN relay protocol: " & getCurrentExceptionMsg())

  if conf.store:
    # Archive setup
    let archiveDriverRes = waitFor ArchiveDriver.new(conf.storeMessageDbUrl,
                                             conf.storeMessageDbVacuum,
                                             conf.storeMessageDbMigration,
                                             conf.storeMaxNumDbConnections,
                                             onFatalErrorAction)
    if archiveDriverRes.isErr():
      return err("failed to setup archive driver: " & archiveDriverRes.error)

    let retPolicyRes = RetentionPolicy.new(conf.storeMessageRetentionPolicy)
    if retPolicyRes.isErr():
      return err("failed to create retention policy: " & retPolicyRes.error)

    let mountArcRes = node.mountArchive(archiveDriverRes.get(),
                                        retPolicyRes.get())
    if mountArcRes.isErr():
      return err("failed to mount synapse archive protocol: " & mountArcRes.error)

    # Store setup
    try:
      await mountStore(node)
    except CatchableError:
      return err("failed to mount synapse store protocol: " & getCurrentExceptionMsg())

  mountStoreClient(node)
  if conf.storenode != "":
    let storeNode = parsePeerInfo(conf.storenode)
    if storeNode.isOk():
      node.peerManager.addServicePeer(storeNode.value, WakuStoreCodec)
    else:
      return err("failed to set node synapse store peer: " & storeNode.error)

  # NOTE Must be mounted after relay
  if conf.lightpush:
    try:
      await mountLightPush(node)
    except CatchableError:
      return err("failed to mount synapse lightpush protocol: " & getCurrentExceptionMsg())

  if conf.lightpushnode != "":
    let lightPushNode = parsePeerInfo(conf.lightpushnode)
    if lightPushNode.isOk():
      mountLightPushClient(node)
      node.peerManager.addServicePeer(lightPushNode.value, WakuLightPushCodec)
    else:
      return err("failed to set node synapse lightpush peer: " & lightPushNode.error)

  # Filter setup. NOTE Must be mounted after relay
  if conf.filter:
    try:
      await mountLegacyFilter(node, filterTimeout = chronos.seconds(conf.filterTimeout))
    except CatchableError:
      return err("failed to mount synapse legacy filter protocol: " & getCurrentExceptionMsg())

    try:
      await mountFilter(node,
                        subscriptionTimeout = chronos.seconds(conf.filterSubscriptionTimeout),
                        maxFilterPeers = conf.filterMaxPeersToServe,
                        maxFilterCriteriaPerPeer = conf.filterMaxCriteria)
    except CatchableError:
      return err("failed to mount synapse filter protocol: " & getCurrentExceptionMsg())

  if conf.filternode != "":
    let filterNode = parsePeerInfo(conf.filternode)
    if filterNode.isOk():
      try:
        await node.mountFilterClient()
        node.peerManager.addServicePeer(filterNode.value, WakuLegacyFilterCodec)
        node.peerManager.addServicePeer(filterNode.value, WakuFilterSubscribeCodec)
      except CatchableError:
        return err("failed to mount synapse filter client protocol: " & getCurrentExceptionMsg())
    else:
      return err("failed to set node synapse filter peer: " & filterNode.error)

  # synapse peer exchange setup
  if conf.peerExchangeNode != "" or conf.peerExchange:
    try:
      await mountPeerExchange(node)
    except CatchableError:
      return err("failed to mount synapse peer-exchange protocol: " & getCurrentExceptionMsg())

    if conf.peerExchangeNode != "":
      let peerExchangeNode = parsePeerInfo(conf.peerExchangeNode)
      if peerExchangeNode.isOk():
        node.peerManager.addServicePeer(peerExchangeNode.value, WakuPeerExchangeCodec)
      else:
        return err("failed to set node synapse peer-exchange peer: " & peerExchangeNode.error)

  return ok()

## Start node

proc startNode*(node: WakuNode, conf: WakuNodeConf,
               dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]): Future[Result[void, string]] {.async.} =
  ## Start a configured node and all mounted protocols.
  ## Connect to static nodes and start
  ## keep-alive, if configured.

  # Start Synapse v2 node
  try:
    await node.start()
  except CatchableError:
    return err("failed to start synapse node: " & getCurrentExceptionMsg())

  # Connect to configured static nodes
  if conf.staticnodes.len > 0:
    try:
      await connectToNodes(node, conf.staticnodes, "static")
    except CatchableError:
      return err("failed to connect to static nodes: " & getCurrentExceptionMsg())

  if dynamicBootstrapNodes.len > 0:
    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    except CatchableError:
      return err("failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg())

  # retrieve px peers and add the to the peer store
  if conf.peerExchangeNode != "":
    let desiredOutDegree = node.wakuRelay.parameters.d.uint64()
    await node.fetchPeerExchangePeers(desiredOutDegree)

  # Start keepalive, if enabled
  if conf.keepAlive:
    node.startKeepalive()

  # Maintain relay connections
  if conf.relay:
    node.peerManager.start()

  return ok()