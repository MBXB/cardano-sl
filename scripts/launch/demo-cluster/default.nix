with import ../../../lib.nix;

{ stdenv, runCommand, writeText, writeScript
, jq, coreutils, curl, gnused, openssl

, cardano-sl, cardano-sl-tools, cardano-sl-wallet-new-static, cardano-sl-node-static
, connect, callPackage

, useStackBinaries ? false

## lots of options!
, stateDir ? maybeEnv "CARDANO_STATE_DIR" "./state-demo"
, runWallet ? true
, runExplorer ? false
, numCoreNodes ? 4
, numRelayNodes ? 1
, numImportedWallets ? 11
, assetLockAddresses ? []
, ghcRuntimeArgs ? "-N2 -qg -A1m -I0 -T"
, additionalNodeArgs ? ""
, keepAlive ? true
, launchGenesis ? false
, configurationKey ? "default"
, disableClientAuth ? false
, useLegacyDataLayer ? false
}:

let
  stackExec = optionalString useStackBinaries "stack exec -- ";
  cardanoDeps = [ cardano-sl-tools cardano-sl-wallet-new-static cardano-sl-node-static ];
  demoClusterDeps = [ jq coreutils curl gnused openssl ];
  allDeps =  demoClusterDeps ++ (optionals (!useStackBinaries ) cardanoDeps);
  walletConfig = {
    inherit stateDir disableClientAuth useLegacyDataLayer;
    topologyFile = walletTopologyFile;
    environment = "demo";
  };
  walletEnvironment = if launchGenesis then {
    environment = "override";
    relays = "127.0.0.1";
    confKey = "testnet_full";
    confFile = "${stateDir}/configuration.yaml";
  } else {
    environment = "demo";
  };
  demoWallet = connect ({ debug = false; } // walletEnvironment // walletConfig);

  ifWallet = optionalString (runWallet);
  ifKeepAlive = optionalString (keepAlive);
  topologyFile = import ./make-topology.nix { inherit (stdenv) lib; cores = numCoreNodes; relays = numRelayNodes; };
  walletTopologyFile = builtins.toFile "wallet-topology.yaml" (builtins.toJSON {
    wallet = {
      relays = [ [ { addr = "127.0.0.1"; port = 3100; } ] ];
      valency = 1;
      fallbacks = 1;
    };
  });
  assetLockFile = writeText "asset-lock-file" (intersperse "\n" assetLockAddresses);
  ifAssetLock = optionalString (assetLockAddresses != []);
  configFiles = runCommand "cardano-config" {} ''
      mkdir -pv $out
      cd $out
      cp -vi ${cardano-sl.src + "/configuration.yaml"} configuration.yaml
      cp -vi ${cardano-sl.src + "/mainnet-genesis-dryrun-with-stakeholders.json"} mainnet-genesis-dryrun-with-stakeholders.json
      cp -vi ${cardano-sl.src + "/mainnet-genesis.json"} mainnet-genesis.json
    '';
  prepareGenesis = callPackage ../../prepare-genesis {
    # fixme: sort this out
    # inherit config system pkgs gitrev numCoreNodes;
    configurationKey = "testnet_full";
    configurationKeyLaunch = "testnet_launch";
  };

in writeScript "demo-cluster" ''
  #!${stdenv.shell} -e
  export PATH=${stdenv.lib.makeBinPath allDeps}:$PATH
  # Set to 0 (passing) by default. Tests using this cluster can set this variable
  # to force the `stop_cardano` function to exit with a different code.
  EXIT_STATUS=0
  function stop_cardano {
    trap "" INT TERM
    echo "Received TERM!"
    echo "Stopping Cardano core nodes"
    for pid in ''${core_pid[@]}
    do
      echo killing pid $pid
      kill $pid
    done
    for pid in ''${relay_pid[@]}
    do
      echo killing pid $pid
      kill $pid
    done
    ${ifWallet ''
      echo killing wallet pid $wallet_pid
    kill $wallet_pid
    ''}
    wait
    echo "Stopped all Cardano processes, exiting with code $EXIT_STATUS!"
    exit $EXIT_STATUS
  }
  system_start=$((`date +%s` + 15))
  echo "Using system start time "$system_start



  # Remove previous state
  rm -rf ${stateDir}
  mkdir -p ${stateDir}/logs

  ${if launchGenesis then ''
    echo "Creating genesis data and keys using external method..."
    config_files=${stateDir}
    ${prepareGenesis} $config_files
  '' else ''
    echo "Creating genesis keys..."
    config_files=${configFiles}
    ${stackExec}cardano-keygen --system-start 0 generate-keys-by-spec --genesis-out-dir ${stateDir}/genesis-keys --configuration-file $config_files/configuration.yaml --configuration-key ${configurationKey}
  ''}

  trap "stop_cardano" INT TERM
  echo "Launching a demo cluster..."
  for i in {0..${builtins.toString (numCoreNodes - 1)}}
  do
    echo -e "loggerTree:\n  severity: Debug+\n  file: core$i.log" > ${stateDir}/logs/log-config-node$i.yaml
    node_args="--db-path ${stateDir}/core-db$i --rebuild-db ${if launchGenesis then "--keyfile ${stateDir}/genesis-keys/generated-keys/rich/key\${i}.sk" else "--genesis-secret $i"} --listen 127.0.0.1:$((3000 + i)) --json-log ${stateDir}/logs/core$i.json --logs-prefix ${stateDir}/logs --log-config ${stateDir}/logs/log-config-node$i.yaml --system-start $system_start --metrics +RTS -N2 -qg -A1m -I0 -T -RTS --node-id core$i --topology ${topologyFile} --configuration-file $config_files/configuration.yaml --configuration-key ${configurationKey} ${ifAssetLock "--asset-lock-file ${assetLockFile}"}"
    echo Launching core node $i: cardano-node-simple $node_args
    ${stackExec}cardano-node-simple $node_args &> ${stateDir}/logs/core$i.output &
    core_pid[$i]=$!

  done
  for i in {0..${builtins.toString (numRelayNodes - 1)}}
  do
    echo -e "loggerTree:\n  severity: Debug+\n  file: relay$i.log" > ${stateDir}/logs/log-config-relay$i.yaml
    node_args="--db-path ${stateDir}/relay-db$i --rebuild-db --listen 127.0.0.1:$((3100 + i)) --json-log ${stateDir}/logs/relay$i.json --logs-prefix ${stateDir}/logs --log-config ${stateDir}/logs/log-config-relay$i.yaml --system-start $system_start --metrics +RTS -N2 -qg -A1m -I0 -T -RTS --node-id relay$i --topology ${topologyFile} --configuration-file $config_files/configuration.yaml --configuration-key ${configurationKey}"
    echo Launching relay node $i: cardano-node-simple $node_args
    ${stackExec}cardano-node-simple $node_args &> ${stateDir}/logs/relay$i.output &
    relay_pid[$i]=$!

  done
  ${ifWallet ''
    ${utf8LocaleSetting}
    echo Launching wallet node: ${demoWallet}
    ${demoWallet} --runtime-args "--system-start $system_start" &> ${stateDir}/logs/wallet.output &
    wallet_pid=$!

    # Query node info until synced
    SYNCED=0
    while [[ $SYNCED != 100 ]]
    do
      PERC=$(curl --silent --cacert ${stateDir}/tls/client/ca.crt --cert ${stateDir}/tls/client/client.pem https://${demoWallet.walletListen}/api/v1/node-info | jq .data.syncProgress.quantity)
      if [[ $PERC == "100" ]]
      then
        echo Blockchain Synced: $PERC%
        SYNCED=100
      elif [[ $SYNCED -ge 20 ]]
      then
        echo Blockchain Syncing: $PERC%
        echo "Sync Failed, Exiting!"
        EXIT_STATUS=1
        stop_cardano
      else
        echo Blockchain Syncing: $PERC%
        SYNCED=$((SYNCED + 1))
        sleep 5
      fi
    done
    echo Blockchain Synced: $PERC%
    if [ ${builtins.toString numImportedWallets} -gt 0 ]
    then
      echo "Importing ${builtins.toString numImportedWallets} poor HD keys/wallet..."
      for i in {0..${builtins.toString numImportedWallets}}
      do
          echo "Importing key$i.sk ..."
          curl https://${demoWallet.walletListen}/api/internal/import-wallet \
          --cacert ${stateDir}/tls/client/ca.crt \
          --cert ${stateDir}/tls/client/client.pem \
          -X POST \
          -H 'cache-control: no-cache' \
          -H 'Content-Type: application/json; charset=utf-8' \
          -H 'Accept: application/json; charset=utf-8' \
          -d "{\"filePath\": \"${stateDir}/genesis-keys/generated-keys/poor/key$i.sk\"}" | jq .
      done
    fi
  ''}
  ${ifKeepAlive ''
    echo "The demo cluster has started and will stop when you exit with Ctrl-C. Log files are in ${stateDir}/logs."
    sleep infinity
  ''}
''
