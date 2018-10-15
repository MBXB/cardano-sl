{ environment ? "mainnet"
, name
, connect
, gitrev
, pkgs
, connectArgs ? {}
# If useConfigVolume is enabled, then topology.yaml will be loaded
# from /config, and the environment variable RUNTIME_ARGS will be
# added to the cardano-node command line.
, useConfigVolume ? false
}:

with pkgs.lib;

let
  connectToCluster = connect ({
    inherit gitrev environment;
    stateDir = "/wallet/${environment}";
    walletListen = "0.0.0.0:8090";
    walletDocListen = "0.0.0.0:8091";
    ekgListen = "0.0.0.0:8000";
  } // optionalAttrs useConfigVolume {
    topologyFile = "/config/topology.yaml";
  } // connectArgs);
  startScript = pkgs.writeScriptBin "cardano-start" ''
    #!/bin/sh
    set -e
    set -o pipefail
    export LOCALE_ARCHIVE="${pkgs.glibcLocales}/lib/locale/locale-archive"
    if [ ! -d /wallet ]; then
      echo '/wallet volume not mounted, you need to create one with `docker volume create` and pass the correct -v flag to `docker run`'
      exit 1
    fi

    ${optionalString useConfigVolume ''
    if [ ! -f /config/topology.yaml ]; then
      echo '/config/topology.yaml does not exist.'
      echo 'You need to bind-mount a config directory to'
      echo 'the /config volume (the -v flag to `docker run`)'
      exit 2
    fi
    ''}

    cd /wallet
    exec ${connectToCluster}${optionalString useConfigVolume " --runtime-args \"$RUNTIME_ARGS\""}
  '';
in pkgs.dockerTools.buildImage {
  name = "cardano-container-${environment}-${name}";
  contents = with pkgs; [ iana-etc startScript openssl bashInteractive coreutils utillinux iproute iputils curl socat ];
  config = {
    Cmd = [ "cardano-start" ];
    ExposedPorts = {
      "3000/tcp" = {}; # protocol
      "8090/tcp" = {}; # wallet
      "8091/tcp" = {}; # wallet doc
      "8100/tcp" = {}; # explorer api
      "8000/tcp" = {}; # ekg
    };
  };
}
