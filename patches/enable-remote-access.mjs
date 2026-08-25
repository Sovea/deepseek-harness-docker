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

const target = resolve(
  dshRoot,
  'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js',
)
let source = readFileSync(target, 'utf8')

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
\tconst privilegedHosts = process.env.DSH_ALLOW_REMOTE_ACCESS === "1" ? trustedHosts : [];`,
  'remote access trust list',
)

replaceExactlyOnce(
  `\t\tif (method !== void 0 && PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, [])) return new Response("forbidden", { status: 403 });`,
  `\t\tif (method !== void 0 && PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, privilegedHosts)) return new Response("forbidden", { status: 403 });`,
  'privileged request fence',
)

writeFileSync(target, source)
console.log(`Patched ${target} for optional trusted-host remote access`)
