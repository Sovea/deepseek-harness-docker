#!/usr/bin/env bash

set -Eeuo pipefail

image=${1:-dsh-docker:smoke}
expected_version=${DSH_EXPECTED_VERSION:-0.1.7-rc.2}
container="dsh-docker-smoke-${RANDOM}-$$"
volume="${container}-home"
workspace_dir=$(mktemp -d)
smoke_uid=${SMOKE_UID:-$(id -u)}
smoke_gid=${SMOKE_GID:-$(id -g)}
endpoint=''
token=''
loopback_cookie=''

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

first_set_cookie() {
  tr -d '\r' | grep -i '^set-cookie:' | head -n 1 | cut -d' ' -f2- | cut -d';' -f1
}

mint_cookie() {
  local authority=$1
  curl --silent --show-error --max-time 5 \
    -D - --output /dev/null \
    --header "Host: $authority" \
    "http://${endpoint}/?token=${token}" \
    | first_set_cookie
}

wait_for_web() {
  local web_html
  for _ in $(seq 1 120); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]]; then
      docker logs "$container" >&2
      return 1
    fi
    endpoint=$(docker port "$container" 13080/tcp 2>/dev/null | tail -n 1 || true)
    if [[ -z "$endpoint" ]]; then
      sleep 1
      continue
    fi
    token=$(docker logs "$container" 2>/dev/null \
      | grep -oE '[?&]token=[A-Za-z0-9_-]+' | tail -n 1 | cut -d= -f2 || true)
    if [[ -z "$token" ]]; then
      sleep 1
      continue
    fi
    loopback_cookie=$(curl --silent --show-error --max-time 2 \
      -D - --output /dev/null \
      "http://${endpoint}/?token=${token}" | first_set_cookie || true)
    if [[ -z "$loopback_cookie" ]]; then
      sleep 1
      continue
    fi
    web_html=$(curl --fail --silent --max-time 2 \
      --header "Cookie: $loopback_cookie" \
      "http://${endpoint}/" 2>/dev/null || true)
    if grep -qi '<!doctype html' <<<"$web_html"; then
      sleep 3
      [[ "$(docker inspect --format '{{.State.Running}}' "$container")" == true ]]
      return 0
    fi
  done
  docker logs "$container" >&2
  return 1
}

fetch_file() {
  # $1 authority (empty for loopback), $2 origin, $3 cookie, $4 output, $5 path
  local authority=${1:-}
  local origin=${2:-}
  local cookie=${3:-}
  local output=$4
  local path=$5
  local -a headers=()
  if [[ -n "$authority" ]]; then
    headers+=(--header "Host: $authority")
  fi
  if [[ -n "$origin" ]]; then
    headers+=(--header "Origin: $origin")
  fi
  if [[ -n "$cookie" ]]; then
    headers+=(--header "Cookie: $cookie")
  fi
  curl --silent --show-error --max-time 5 \
    --header 'Sec-Fetch-Site: same-origin' \
    "${headers[@]}" \
    --url "http://${endpoint}/api/file?path=${path}" \
    --output "$output" \
    --write-out '%{http_code}'
}

log "building $image"
docker build \
  --build-arg DSH_UID="$smoke_uid" \
  --build-arg DSH_GID="$smoke_gid" \
  --build-arg DSH_WITH_PYTHON=1 \
  --tag "$image" .

log 'checking pinned dsh and non-root execution'
version_output=$(docker run --rm "$image" --version)
printf '%s\n' "$version_output"
[[ "$version_output" == *"$expected_version"* ]]
docker run --rm --interactive --entrypoint node "$image" - "$expected_version" <<'NODE'
const { existsSync, readFileSync, readdirSync } = require('node:fs')
const { join } = require('node:path')

const expectedVersion = process.argv[2]
const dshRoot = '/usr/local/lib/node_modules/@deepseek-ai/dsh'
const packages = []

function visit(directory) {
  const manifestPath = join(directory, 'package.json')
  if (existsSync(manifestPath)) {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    if (
      manifest.name === '@deepseek-ai/dsh'
      || manifest.name?.startsWith('@deepseek-ai/dsh-')
    ) {
      packages.push({ name: manifest.name, version: manifest.version, manifestPath })
    }
  }

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && entry.name !== '.bin') visit(join(directory, entry.name))
  }
}

visit(dshRoot)
if (packages.length === 0) throw new Error(`no DSH packages found under ${dshRoot}`)

const mismatches = packages.filter(entry => entry.version !== expectedVersion)
if (mismatches.length > 0) {
  for (const entry of mismatches) {
    console.error(`${entry.name}: expected ${expectedVersion}, found ${entry.version} (${entry.manifestPath})`)
  }
  process.exit(1)
}
console.log(`verified ${packages.length} DSH packages at ${expectedVersion}`)
NODE
runtime_uid=$(docker run --rm --entrypoint id "$image" -u)
runtime_gid=$(docker run --rm --entrypoint id "$image" -g)
[[ "$runtime_uid" != 0 ]]
[[ "$runtime_uid" == "$smoke_uid" ]]
[[ "$runtime_gid" == "$smoke_gid" ]]
docker run --rm --entrypoint node "$image" -e \
  "const p=require(require.resolve('node-pty',{paths:['/usr/local/lib/node_modules/@deepseek-ai/dsh']})); if (!p.spawn) process.exit(1)"

log 'checking the Python toolchain is available in the workspace environment'
docker run --rm --entrypoint python3 "$image" --version
docker run --rm --entrypoint python "$image" --version

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

if docker logs "$container" 2>&1 | grep -q 'opening the default browser'; then
  log 'container unexpectedly attempted to open a browser'
  exit 1
fi

docker exec "$container" test -w /home/node/.dsh
probe_path=/home/node/workspaces/.dsh-smoke-probe
docker exec "$container" sh -c "printf smoke >$probe_path"
[[ "$(docker exec "$container" id -u)" != 0 ]]

trusted_cookie=$(mint_cookie smoke.example)
[[ -n "$trusted_cookie" ]]
trusted_alt_cookie=$(mint_cookie smoke-alt.example:8443)
[[ -n "$trusted_alt_cookie" ]]

log 'checking the API fence and browser authentication'
unauthenticated_status=$(fetch_file '' '' '' "$workspace_dir/unauth.txt" "$probe_path")
[[ "$unauthenticated_status" == 401 ]]

loopback_status=$(fetch_file '' '' "$loopback_cookie" "$workspace_dir/loopback.txt" "$probe_path")
[[ "$loopback_status" == 200 ]]
grep -q smoke "$workspace_dir/loopback.txt"

trusted_status=$(fetch_file \
  smoke.example \
  http://smoke.example \
  "$trusted_cookie" \
  "$workspace_dir/trusted.txt" \
  "$probe_path")
[[ "$trusted_status" == 200 ]]
grep -q smoke "$workspace_dir/trusted.txt"

second_trusted_status=$(fetch_file \
  smoke-alt.example:8443 \
  https://smoke-alt.example:8443 \
  "$trusted_alt_cookie" \
  "$workspace_dir/second-trusted.txt" \
  "$probe_path")
[[ "$second_trusted_status" == 200 ]]
grep -q smoke "$workspace_dir/second-trusted.txt"

trusted_unauthenticated_status=$(fetch_file \
  smoke.example \
  http://smoke.example \
  '' \
  "$workspace_dir/trusted-unauth.txt" \
  "$probe_path")
[[ "$trusted_unauthenticated_status" == 401 ]]

untrusted_status=$(fetch_file \
  untrusted.example \
  https://untrusted.example \
  '' \
  "$workspace_dir/untrusted.txt" \
  "$probe_path")
[[ "$untrusted_status" == 403 ]]

mismatched_origin_status=$(fetch_file \
  smoke.example \
  https://untrusted.example \
  "$trusted_cookie" \
  "$workspace_dir/mismatched-origin.txt" \
  "$probe_path")
[[ "$mismatched_origin_status" == 403 ]]

log "Web UI is healthy at http://${endpoint}/"
