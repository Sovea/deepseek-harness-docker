#!/usr/bin/env bash

set -Eeuo pipefail

image=${1:-dsh-docker:smoke}
expected_version=${DSH_EXPECTED_VERSION:-0.1.0-rc.6}
container="dsh-docker-smoke-${RANDOM}-$$"
volume="${container}-home"
workspace_dir=$(mktemp -d)
smoke_uid=${SMOKE_UID:-$(id -u)}
smoke_gid=${SMOKE_GID:-$(id -g)}

if (( smoke_uid == 0 || smoke_gid == 0 )); then
  smoke_uid=1000
  smoke_gid=1000
fi

log() {
  printf '[smoke] %s\n' "$*" >&2
}

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  if [[ -n "$workspace_dir" && "$workspace_dir" == /tmp/* ]]; then
    rm -rf -- "$workspace_dir"
  fi
}

finish() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    log "failed with exit status $status"
    docker logs "$container" >&2 2>/dev/null || true
  fi
  cleanup
  exit "$status"
}
trap finish EXIT

wait_for_web() {
  endpoint=''
  local web_html
  for _ in $(seq 1 90); do
    endpoint=$(docker port "$container" 13080/tcp 2>/dev/null | tail -n 1 || true)
    if [[ -n "$endpoint" ]] && curl --fail --silent --max-time 2 "http://${endpoint}/" >/dev/null; then
      sleep 3
      [[ "$(docker inspect --format '{{.State.Running}}' "$container")" == true ]]
      web_html=$(curl --fail --silent --max-time 2 "http://${endpoint}/")
      grep -qi '<!doctype html' <<<"$web_html"
      return 0
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]]; then
      docker logs "$container" >&2
      return 1
    fi
    sleep 1
  done
  docker logs "$container" >&2
  return 1
}

call_directory_api() {
  local output=$1
  local authority=${2:-}
  local origin=${3:-}
  local -a headers=()
  local payload
  payload='{"type":"client-request","rpcId":"smoke-list-directory","method":"host.listDirectory","payload":{}}'

  if [[ -n "$authority" ]]; then
    headers+=(--header "Host: $authority")
  fi
  if [[ -n "$origin" ]]; then
    headers+=(--header "Origin: $origin")
  fi

  curl --silent --show-error --max-time 5 \
    --request POST \
    --header 'Sec-Fetch-Site: same-origin' \
    --header 'Content-Type: application/json' \
    "${headers[@]}" \
    --data "$payload" \
    --output "$output" \
    --write-out '%{http_code}' \
    "http://${endpoint}/api/host.listDirectory"
}

log "building $image"
docker build \
  --build-arg DSH_UID="$smoke_uid" \
  --build-arg DSH_GID="$smoke_gid" \
  --tag "$image" .

log 'checking pinned dsh and non-root execution'
version_output=$(docker run --rm "$image" --version)
printf '%s\n' "$version_output"
[[ "$version_output" == *"$expected_version"* ]]
runtime_uid=$(docker run --rm --entrypoint id "$image" -u)
runtime_gid=$(docker run --rm --entrypoint id "$image" -g)
[[ "$runtime_uid" != 0 ]]
[[ "$runtime_uid" == "$smoke_uid" ]]
[[ "$runtime_gid" == "$smoke_gid" ]]
docker run --rm --entrypoint node "$image" -e \
  "const p=require('/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty'); if (!p.spawn) process.exit(1)"

log 'checking invalid trusted-host configuration'
if docker run --rm \
  --env 'DSH_TRUSTED_HOSTS=invalid host' \
  "$image" web >/dev/null 2>&1; then
  log 'invalid DSH_TRUSTED_HOSTS was unexpectedly accepted'
  exit 1
fi
if docker run --rm \
  --env 'DSH_TRUSTED_HOSTS=https://invalid.example' \
  "$image" web >/dev/null 2>&1; then
  log 'non-authority DSH_TRUSTED_HOSTS entry was unexpectedly accepted'
  exit 1
fi

docker volume create "$volume" >/dev/null
if (( $(id -u) == 0 )); then
  chown "$runtime_uid:$runtime_gid" "$workspace_dir"
else
  chmod 0770 "$workspace_dir"
fi

log 'starting Web profile through the loopback bridge with trusted hosts'
docker run --detach \
  --name "$container" \
  --env 'DSH_TRUSTED_HOSTS=smoke.example,smoke-alt.example:8443' \
  --publish 127.0.0.1::13080 \
  --volume "$volume:/home/node/.dsh" \
  --volume "$workspace_dir:/home/node/workspaces" \
  "$image" >/dev/null

wait_for_web

docker exec "$container" test -w /home/node/.dsh
docker exec "$container" sh -c '
  probe=/home/node/workspaces/.dsh-smoke-write
  trap "rm -f $probe" EXIT
  printf smoke >"$probe"
  test "$(cat "$probe")" = smoke
'
[[ "$(docker exec "$container" id -u)" != 0 ]]

loopback_status=$(call_directory_api "$workspace_dir/loopback.json")
[[ "$loopback_status" == 200 ]]
grep -q '"ok":true' "$workspace_dir/loopback.json"

trusted_status=$(call_directory_api \
  "$workspace_dir/trusted.json" \
  smoke.example \
  http://smoke.example)
[[ "$trusted_status" == 200 ]]
grep -q '"ok":true' "$workspace_dir/trusted.json"

second_trusted_status=$(call_directory_api \
  "$workspace_dir/second-trusted.json" \
  smoke-alt.example:8443 \
  https://smoke-alt.example:8443)
[[ "$second_trusted_status" == 200 ]]
grep -q '"ok":true' "$workspace_dir/second-trusted.json"

untrusted_status=$(call_directory_api \
  "$workspace_dir/untrusted.txt" \
  untrusted.example \
  https://untrusted.example)
[[ "$untrusted_status" == 403 ]]

mismatched_origin_status=$(call_directory_api \
  "$workspace_dir/mismatched-origin.txt" \
  smoke.example \
  https://untrusted.example)
[[ "$mismatched_origin_status" == 403 ]]

log "Web UI is healthy at http://${endpoint}/"
