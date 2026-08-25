#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '[dsh-docker] %s\n' "$*" >&2
}

fail() {
  log "error: $*"
  exit 1
}

validate_port() {
  local name=$1
  local value=$2
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be an integer"
  (( value >= 1 && value <= 65535 )) || fail "$name must be between 1 and 65535"
}

append_trusted_hosts() {
  local raw=${DSH_TRUSTED_HOSTS:-}
  local entry
  local -a entries
  [[ -n "$raw" ]] || return 0

  case "$raw" in
    ,* | *, | *,,*) fail 'DSH_TRUSTED_HOSTS contains an empty entry' ;;
  esac

  IFS=',' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || fail 'DSH_TRUSTED_HOSTS contains an empty entry'
    [[ "$entry" != *[[:space:]]* ]] ||
      fail 'DSH_TRUSTED_HOSTS entries must not contain whitespace'
    [[ "$entry" != *'*'* ]] ||
      fail 'DSH_TRUSTED_HOSTS entries must not contain wildcards'
  done

  log "adding ${#entries[@]} trusted host authority entries"
  dsh_args+=(--trusted-host "${entries[@]}")
}

validate_remote_access() {
  local value=${DSH_ALLOW_REMOTE_ACCESS:-0}

  case "$value" in
    0) return 0 ;;
    1)
      [[ -n "${DSH_TRUSTED_HOSTS:-}" ]] ||
        fail 'DSH_ALLOW_REMOTE_ACCESS=1 requires DSH_TRUSTED_HOSTS'
      log 'warning: remote access is enabled for all APIs on trusted hosts; require authenticated HTTPS access'
      ;;
    *) fail 'DSH_ALLOW_REMOTE_ACCESS must be 0 or 1' ;;
  esac
}

mkdir -p \
  "${DSH_HOME:-/home/node/.dsh}" \
  "${NPM_CONFIG_CACHE:-/home/node/.dsh/cache/npm}" \
  "${PNPM_HOME:-/home/node/.dsh/pnpm}" \
  "${XDG_CACHE_HOME:-/home/node/.dsh/cache}" \
  "${XDG_CONFIG_HOME:-/home/node/.dsh/config}"

if (( $# == 0 )); then
  set -- web
elif [[ "$1" == dsh ]]; then
  shift
fi

dsh_args=("$@")
web_mode=false

if [[ "${1:-}" == web ]]; then
  web_mode=true
elif [[ "${1:-}" == --profile && "${2:-}" == web ]]; then
  web_mode=true
elif [[ "${1:-}" == --profile=web ]]; then
  web_mode=true
fi

if ! $web_mode; then
  exec dsh "${dsh_args[@]}"
fi

# These Web-profile invocations inspect configuration or print help and never
# bind a server. Do not add app arguments or start a bridge around them.
for argument in "${dsh_args[@]}"; do
  case "$argument" in
    --dump-config | --dump-default-config | -h | --help)
      exec dsh "${dsh_args[@]}"
      ;;
  esac
done

validate_remote_access
append_trusted_hosts

web_port=${DSH_WEB_PORT:-3080}
bridge_port=${DSH_BRIDGE_PORT:-13080}

has_port=false
has_no_open=false
for (( index = 0; index < ${#dsh_args[@]}; index++ )); do
  argument=${dsh_args[index]}
  if [[ "$argument" == --port ]]; then
    (( index + 1 < ${#dsh_args[@]} )) || fail '--port needs a value'
    web_port=${dsh_args[index + 1]}
    has_port=true
  elif [[ "$argument" == --port=* ]]; then
    web_port=${argument#--port=}
    has_port=true
  elif [[ "$argument" == --no-open ]]; then
    has_no_open=true
  fi
done
if ! $has_port; then
  dsh_args+=(--port "$web_port")
fi
if ! $has_no_open; then
  dsh_args+=(--no-open)
fi

validate_port DSH_WEB_PORT "$web_port"
validate_port DSH_BRIDGE_PORT "$bridge_port"
export DSH_WEB_PORT="$web_port"

log "forwarding container 0.0.0.0:${bridge_port} to dsh 127.0.0.1:${web_port}"
socat \
  "TCP4-LISTEN:${bridge_port},bind=0.0.0.0,reuseaddr,fork" \
  "TCP4:127.0.0.1:${web_port}" &
bridge_pid=$!

dsh "${dsh_args[@]}" &
dsh_pid=$!

termination_signal=''

stop_children() {
  kill -TERM "$dsh_pid" "$bridge_pid" 2>/dev/null || true
}

trap 'termination_signal=TERM; stop_children' TERM
trap 'termination_signal=INT; stop_children' INT

first_pid=''
first_status=0
set +e
wait -n -p first_pid "$dsh_pid" "$bridge_pid"
first_status=$?
set -e

if [[ -n "$termination_signal" ]]; then
  stop_children
  wait "$dsh_pid" 2>/dev/null || true
  wait "$bridge_pid" 2>/dev/null || true
  [[ "$termination_signal" == TERM ]] && exit 0
  exit 130
fi

if [[ "$first_pid" == "$bridge_pid" ]]; then
  log "network bridge exited unexpectedly"
  stop_children
  wait "$dsh_pid" 2>/dev/null || true
  (( first_status == 0 )) && exit 1
  exit "$first_status"
fi

kill -TERM "$bridge_pid" 2>/dev/null || true
wait "$bridge_pid" 2>/dev/null || true
exit "$first_status"
