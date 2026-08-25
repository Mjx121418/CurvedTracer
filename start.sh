#!/bin/bash
set -e

# Proxy used by dsh / Node and other command-line tools.
export HTTP_PROXY="http://192.168.64.1:7897"
export HTTPS_PROXY="http://192.168.64.1:7897"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"

# Let Node use the proxy environment variables.
export NODE_USE_ENV_PROXY=1

# Forward the externally reachable container port to DSH's localhost port.
socat \
    TCP-LISTEN:3081,bind=0.0.0.0,reuseaddr,fork \
    TCP:127.0.0.1:3080 &

SOCAT_PID=$!

cleanup() {
    kill "$SOCAT_PID" 2>/dev/null || true
    wait "$SOCAT_PID" 2>/dev/null || true
}

trap cleanup EXIT

# Start DSH.
dsh web
