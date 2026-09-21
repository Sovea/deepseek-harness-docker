# dsh-docker

A minimal Docker deployment for
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

This is an unofficial community project. DeepSeek Harness is currently a
developer preview, so upstream changes may require image updates.
The project follows the upstream
[DeepSeek Harness brand usage guidelines](https://github.com/deepseek-ai/deepseek-harness/blob/master/BRAND_GUIDELINES.md).

## Features

- Runs as a non-root user and persists Harness state across container
  recreation.
- Mounts a configurable host directory as the workspace root.
- Matches the host UID/GID on Linux to preserve workspace file ownership.
- Supports additional trusted browser authorities through
  `DSH_TRUSTED_HOSTS`.
- Ships a full Python toolchain (`python3`, `pip`, `venv`, plus `python`/`pip`
  aliases) in the image, so agents can run Python inside the bind-mounted
  workspaces. Control it with `DSH_WITH_PYTHON`.
- Publishes the service on host loopback by default and includes health checks
  and automatic restart handling.

## Requirements

- Docker Engine
- Docker Compose v2

## Usage

```sh
cp .env.example .env
```

The `.env` file is required: compose validates `DSH_HOST_PORT` at config
time and refuses to start the container without it. The provider variables
in the file remain optional.

On Docker Desktop:

```sh
docker compose up --detach --build
```

On Linux, set `DSH_UID` and `DSH_GID` in `.env` to the output of `id -u`
and `id -g`, so files created in the bind-mounted workspace remain
accessible (the values in `.env.example` are only correct if they match):

```sh
sed -i "s/^DSH_UID=.*/DSH_UID=$(id -u)/; s/^DSH_GID=.*/DSH_GID=$(id -g)/" .env
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
| `DSH_UID`, `DSH_GID` | Container user and group IDs | `1000` |
| `DSH_WITH_PYTHON` | Keep a full Python toolchain (`python3`, `pip`, `venv`, plus `python`/`pip` aliases) in the image so agents can run Python inside the workspaces (`1` to keep, `0` to strip it out) | `1` |
| `DEEPSEEK_API_KEY` | Optional provider API key | empty |

`DSH_TRUSTED_HOSTS` accepts comma-separated `host` or `host:port` values. Do
not include schemes, paths, or wildcards. The entrypoint forwards the entries
to dsh as `--trusted-host` flags, extending the loopback-only `/api`
host/origin fence. The fence controls reachability only; dsh additionally
requires its launch-token browser session (the URL dsh prints at startup)
before any API request is served, including from trusted hosts.

The service binds to `127.0.0.1` by default. To use it on a remote Docker host,
forward the port over SSH:

```sh
ssh -N -L 3080:127.0.0.1:3080 user@your-server
```

See [SECURITY.md](SECURITY.md) before exposing the service through any other
access layer.

## License

MIT. DeepSeek Harness is licensed separately by its upstream project.
