# dsh-docker

A minimal Docker deployment for
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

This is an unofficial community project. DeepSeek Harness is currently a
developer preview, so upstream changes may require image updates.

## Features

- Runs as a non-root user and persists Harness state across container
  recreation.
- Mounts a configurable host directory as the workspace root.
- Matches the host UID/GID on Linux to preserve workspace file ownership.
- Supports additional trusted browser authorities through
  `DSH_TRUSTED_HOSTS`.
- Optionally enables the complete Web UI through an authenticated remote
  access layer.
- Publishes the service on host loopback by default and includes health checks
  and automatic restart handling.

## Requirements

- Docker Engine
- Docker Compose v2

## Usage

```sh
cp .env.example .env
```

On Docker Desktop:

```sh
docker compose up --detach --build
```

On Linux, pass your host identity so files created in a bind-mounted workspace
remain accessible:

```sh
DSH_UID="$(id -u)" DSH_GID="$(id -g)" \
  docker compose up --detach --build
```

Open <http://localhost:3080>, then select a workspace under
`/home/node/workspaces`. The local `./workspaces` directory is mounted there by
default.

Configure a model provider in the Web UI, or set the optional provider
variables in `.env`.

Common commands:

```sh
docker compose logs --follow dsh  # Follow service logs
docker compose down               # Stop without deleting state
./scripts/smoke-test.sh            # Run the end-to-end smoke test
```

## Configuration

The main settings in `.env` are:

| Variable | Purpose | Default |
| --- | --- | --- |
| `DSH_HOST_PORT` | Host loopback port | `3080` |
| `DSH_WORKSPACES` | Host directory mounted as the workspace root | `./workspaces` |
| `DSH_TRUSTED_HOSTS` | Extra browser authorities accepted by dsh | empty |
| `DSH_ALLOW_REMOTE_ACCESS` | Allow trusted hosts to use all dsh APIs | `0` |
| `DSH_UID`, `DSH_GID` | Container user and group IDs | `1000` |
| `DEEPSEEK_API_KEY` | Optional provider API key | empty |

`DSH_TRUSTED_HOSTS` accepts comma-separated `host` or `host:port` values. Do
not include schemes, paths, or wildcards. It only controls dsh's host/origin
checks and is not an authentication mechanism.

For a complete remote Web UI, set `DSH_ALLOW_REMOTE_ACCESS=1` together with at
least one trusted host. This grants authenticated users full control of dsh,
including settings and credentials. Only enable it behind an authenticated
HTTPS access layer.

The service binds to `127.0.0.1` by default. To use it on a remote Docker host,
forward the port over SSH:

```sh
ssh -N -L 3080:127.0.0.1:3080 user@your-server
```

See [SECURITY.md](SECURITY.md) before exposing the service through any other
access layer.

## License

MIT. DeepSeek Harness is licensed separately by its upstream project.
