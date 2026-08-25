import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const dshRoot = process.argv[2]
const expectedVersion = process.argv[3]

if (!dshRoot || !expectedVersion) {
  throw new Error('usage: enable-remote-access.mjs <dsh-root> <expected-version>')
}

const packageJsonPath = resolve(dshRoot, 'package.json')
const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf8'))

if (packageJson.version !== expectedVersion) {
  throw new Error(
    `dsh version mismatch: expected ${expectedVersion}, found ${String(packageJson.version)}`,
  )
}

const serverTarget = resolve(
  dshRoot,
  'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js',
)
let source = readFileSync(serverTarget, 'utf8')

function assertExactlyOnce(fragment, description) {
  const occurrences = source.split(fragment).length - 1
  if (occurrences !== 1) {
    throw new Error(`${description}: expected one upstream match, found ${occurrences}`)
  }
}

function replaceExactlyOnce(before, after, description) {
  assertExactlyOnce(before, description)
  source = source.replace(before, after)
}

const privilegedMethods = `const PRIVILEGED_METHODS = new Set([
\t"agentPreset.read",
\t"agentPreset.copy",
\t"agentPreset.openDocument",
\t"agentPreset.remove",
\t"host.pickDirectory",
\t"host.openPath",
\t"settings.describe",
\t"settings.openDocument",
\t"settings.update",
\t"settings.replace",
\t"settings.mutate",
\t"credentials.describe",
\t"credentials.set",
\t"credentials.unset",
\t"llm.discoverModels"
]);`

assertExactlyOnce(privilegedMethods, 'privileged method registry')

replaceExactlyOnce(
  `\tconst trustedHosts = config?.trustedHosts ?? [];`,
  `\tconst trustedHosts = config?.trustedHosts ?? [];
\tconst remoteAccessEnabled = process.env.DSH_ALLOW_REMOTE_ACCESS === "1";
\tconst privilegedHosts = remoteAccessEnabled ? trustedHosts : [];
\tif (remoteAccessEnabled) ctx.effect(() => ctx.webServer.tapIndex((html) => html.replace("<head>", '<head><script>globalThis.__DSH_REMOTE_ACCESS__=true</script>')), "client-connection: remote access browser marker");`,
  'remote access trust list',
)

replaceExactlyOnce(
  `\t\tif (method !== void 0 && PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, [])) return new Response("forbidden", { status: 403 });`,
  `\t\tif (method !== void 0 && PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, privilegedHosts)) return new Response("forbidden", { status: 403 });`,
  'privileged request fence',
)

writeFileSync(serverTarget, source)
console.log(`Patched ${serverTarget} for optional trusted-host remote access`)

const clientTarget = resolve(
  dshRoot,
  'node_modules/@deepseek-ai/dsh-client-connection/lib/client.js',
)
source = readFileSync(clientTarget, 'utf8')

replaceExactlyOnce(
  `\t\t\t\tisLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),`,
  `\t\t\t\tisLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname) || globalThis.__DSH_REMOTE_ACCESS__ === true,`,
  'remote browser capability gate',
)

writeFileSync(clientTarget, source)
console.log(`Patched ${clientTarget} for optional remote browser capabilities`)
