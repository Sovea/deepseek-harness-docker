# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

ARG DSH_VERSION=0.1.0-rc.6
ARG PNPM_VERSION=11.7.0

ENV DSH_HOME=/home/node/.dsh \
    DSH_WEB_PORT=3080 \
    DSH_BRIDGE_PORT=13080 \
    PNPM_HOME=/home/node/.dsh/pnpm \
    NPM_CONFIG_CACHE=/home/node/.dsh/cache/npm \
    XDG_CACHE_HOME=/home/node/.dsh/cache \
    XDG_CONFIG_HOME=/home/node/.dsh/config \
    PATH=/home/node/.dsh/pnpm:${PATH}

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      g++ \
      make \
      openssh-client \
      procps \
      python3 \
      ripgrep \
      socat \
      tini; \
    npm install --global --no-audit --no-fund \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "pnpm@${PNPM_VERSION}" \
      "@deepseek-ai/dsh@${DSH_VERSION}"; \
    npm cache clean --force; \
    apt-get purge -y --auto-remove g++ make python3; \
    rm -rf /var/lib/apt/lists/*

# Keep identity-only arguments below the expensive dependency layer so a host
# UID/GID change does not reinstall dsh and its native dependencies.
ARG DSH_UID=1000
ARG DSH_GID=1000

RUN set -eux; \
    test "${DSH_UID}" -gt 0; \
    test "${DSH_GID}" -gt 0; \
    if [ "$(id -g node)" != "${DSH_GID}" ]; then \
      existing_group="$(getent group "${DSH_GID}" | cut -d: -f1 || true)"; \
      if [ -z "${existing_group}" ]; then groupmod --gid "${DSH_GID}" node; fi; \
      usermod --gid "${DSH_GID}" node; \
    fi; \
    if [ "$(id -u node)" != "${DSH_UID}" ]; then \
      existing_user="$(getent passwd "${DSH_UID}" | cut -d: -f1 || true)"; \
      test -z "${existing_user}"; \
      usermod --uid "${DSH_UID}" node; \
    fi; \
    mkdir -p \
      /home/node/.dsh/cache/npm \
      /home/node/.dsh/config \
      /home/node/.dsh/pnpm \
      /home/node/workspaces; \
    chown -R "${DSH_UID}:${DSH_GID}" /home/node

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY --chmod=0755 docker/healthcheck.sh /usr/local/bin/dsh-healthcheck

USER ${DSH_UID}:${DSH_GID}
WORKDIR /home/node/workspaces

EXPOSE 13080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["dsh-healthcheck"]

ARG IMAGE_VERSION=0.1.0-rc.6-r1

LABEL org.opencontainers.image.title="dsh-docker" \
      org.opencontainers.image.description="Minimal, secure-by-default Docker deployment for DeepSeek Harness" \
      org.opencontainers.image.source="https://github.com/Sovea/dsh-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}"

ENTRYPOINT ["tini", "--", "dsh-entrypoint"]
CMD ["web"]
