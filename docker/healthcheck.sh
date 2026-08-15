#!/usr/bin/env sh

set -eu

port=${DSH_WEB_PORT:-3080}
curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:${port}/" >/dev/null
