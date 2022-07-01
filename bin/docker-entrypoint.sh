#!/bin/bash
set -eo pipefail
trap 'kill `jobs -p`' SIGTERM

: ${NETWORK:=testnet}
: ${LIGHTNINGD_OPT:=--log-level=debug}
: ${BROCOIND_OPT:=-debug=rpc --printtoconsole=0 --fallbackfee=0.00001}

[[ "$NETWORK" == "mainnet" ]] && NETWORK=brocoin

[[ "$NETWORK" != "brocoin" ]] && NETWORK_ARG="-$NETWORK"

if [ -d /etc/lightning ]; then
  echo -n "Using lightningd directory mounted in /etc/lightning... "
  LN_PATH=/etc/lightning

else

  # Setup brocoind (only needed when we're starting our own lightningd instance)
  if [ -d /etc/brocoin ]; then
    echo -n "Connecting to brocoind configured in /etc/brocoin... "

    RPC_OPT="-datadir=/etc/brocoin $([[ -z "$BROCOIND_RPCCONNECT" ]] || echo "-rpcconnect=$BROCOIND_RPCCONNECT")"

  elif [ -n "$BROCOIND_URI" ]; then
    [[ "$BROCOIND_URI" =~ ^[a-z]+:\/+(([^:/]+):([^@/]+))@([^:/]+:[0-9]+)/?$ ]] || \
      { echo >&2 "ERROR: invalid brocoind URI: $BROCOIND_URI"; exit 1; }

    echo -n "Connecting to brocoind at ${BASH_REMATCH[4]}... "

    RPC_OPT="-rpcconnect=${BASH_REMATCH[4]}"

    if [ "${BASH_REMATCH[2]}" != "__cookie__" ]; then
      RPC_OPT="$RPC_OPT -rpcuser=${BASH_REMATCH[2]} -rpcpassword=${BASH_REMATCH[3]}"
    else
      RPC_OPT="$RPC_OPT -datadir=/tmp/brocoin"
      [[ "$NETWORK" == "brocoin" ]] && NET_PATH=/tmp/brocoin || NET_PATH=/tmp/brocoin/$NETWORK
      mkdir -p $NET_PATH
      echo "${BASH_REMATCH[1]}" > $NET_PATH/.cookie
    fi

  else
    echo -n "Starting brocoind... "

    mkdir -p /data/brocoin
    RPC_OPT="-datadir=/data/brocoin"

    brocoind $NETWORK_ARG $RPC_OPT $BROCOIND_OPT &
  fi

  echo -n "waiting for RPC... "
  brocoin-cli $NETWORK_ARG $RPC_OPT -rpcwait getblockchaininfo > /dev/null
  echo "ready."

  # Setup lightning
  echo -n "Starting lightningd... "

  LN_PATH=/data/lightning
  mkdir -p $LN_PATH

  lnopt=($LIGHTNINGD_OPT --network=$NETWORK --lightning-dir="$LN_PATH" --log-file=debug.log)
  [[ -z "$LN_ALIAS" ]] || lnopt+=(--alias="$LN_ALIAS")

  lightningd "${lnopt[@]}" $(echo "$RPC_OPT" | sed -r 's/(^| )-/\1--brocoin-/g') > /dev/null &
fi

: ${LN_NET_PATH:=$LN_PATH/$NETWORK}
mkdir -p $LN_NET_PATH

if [ ! -S $LN_NET_PATH/lightning-rpc ]; then
  echo -n "waiting for RPC unix socket... "
  sed --quiet '/^lightning-rpc$/ q' <(inotifywait -e create,moved_to --format '%f' -qm $LN_NET_PATH)
fi
sleep 0.5

if command -v lightning-cli > /dev/null; then
  lightning-cli --rpc-file=$LN_NET_PATH/lightning-rpc --network=$NETWORK getinfo > /dev/null
  echo -n "c-lightning RPC ready."
fi

echo -e "\nStarting Lightning Charge"

if [ -z "$STANDALONE"  ]; then
    # when not in standalone mode, run spark-wallet as an additional background job
  charged -d /data/charge.db -l $LN_NET_PATH -i 0.0.0.0 "$@" $CHARGED_OPTS &

  # shutdown the entire process when any of the background jobs exits (even if successfully)
  wait -n
  kill -TERM $$
else
  exec charged -d /data/charge.db -l $LN_NET_PATH -i 0.0.0.0 "$@" $CHARGED_OPTS
fi
