# Security policy

Report vulnerabilities through GitHub's private security advisory flow rather
than a public issue. Include the affected version, reproduction steps, and
expected impact.

DeepSeek Harness can execute commands and access mounted files. Treat it as a
local control plane:

- Keep the published port bound to `127.0.0.1`.
- Use an authenticated access layer for remote access.
- Do not treat `DSH_TRUSTED_HOSTS` as authentication.
- Keep `DSH_ALLOW_REMOTE_ACCESS` disabled unless trusted hosts are protected by
  authenticated HTTPS access. Enabling it grants those hosts access to every
  dsh API, including configuration and credential operations.
- Do not mount the Docker socket, host root, or an entire home directory.
- Do not attach untrusted containers to the service network.
- Use narrowly scoped, revocable provider credentials.

The container runs as a non-root user with dropped capabilities and
`no-new-privileges`. These controls reduce impact, but they do not make hostile
code safe or hide credentials from commands executed by the agent.
