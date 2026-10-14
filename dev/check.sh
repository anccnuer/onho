#!/usr/bin/env bash
# One entry point for the local WCGI test environment.
#
#   dev/check.sh          build, test, verify the ABI and the fixtures
#   dev/check.sh --update rewrite fixtures/*.expect from the current build
set -euo pipefail
cd "$(dirname "$0")/.."

WASM=_build/wasm/release/build/cmd/wcgi/wcgi.wasm

moon test
moon build --target wasm --release
node dev/host.mjs abi
if [ "${1:-}" = "--update" ]; then
  node dev/host.mjs update
fi
node dev/host.mjs check
# The same guest, driven by the real engine: no Node host and no WASI shim, only the
# environment and the stdin a CGI gateway would hand it.
if command -v wasmer >/dev/null 2>&1; then
  # Git for Windows rewrites /echo into a Windows path, so argument conversion is off
  # for this call.
  got=$(MSYS2_ARG_CONV_EXCL='*' sh -c \
    "printf 'body through wasmer' | wasmer run '$WASM' --env REQUEST_METHOD=POST --env SCRIPT_NAME=/echo --env CONTENT_LENGTH=19")
  want=$(printf 'Status: 200 OK\ncontent-type: text/plain; charset=utf-8\n\nbody through wasmer')
  if [ "$got" = "$want" ]; then
    echo "ok   wasmer run as a CGI program"
  else
    echo "FAIL wasmer run returned $(printf '%q' "$got")"
    exit 1
  fi
  # The access-log middleware writes to fd 2; stdout stays the response alone.
  err=$(MSYS2_ARG_CONV_EXCL='*' sh -c \
    "printf '' | wasmer run '$WASM' --env REQUEST_METHOD=GET --env SCRIPT_NAME=/health --env CONTENT_LENGTH=0 2>&1 >/dev/null")
  if [ "$err" = "GET /health -> 200 OK" ]; then
    echo "ok   wasmer run logs the request to stderr"
  else
    echo "FAIL wasmer stderr was $(printf '%q' "$err")"
    exit 1
  fi
else
  echo "skip wasmer CLI not on PATH"
fi
