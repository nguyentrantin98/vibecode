// Builds a new version and publishes its installer as a GitHub release, which the app's
// Update button installs.  `npm run release` bumps the patch version; `npm run release 0.3.0` sets one.
// Token: GITHUB_TOKEN, else the one git already stores for github.com.
const { execSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const run = (cmd, opts = {}) => execSync(cmd, { cwd: root, stdio: 'inherit', ...opts })
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8')
const write = (f, s) => fs.writeFileSync(path.join(root, f), s)

const current = JSON.parse(read('package.json')).version
const version =
  process.argv[2] ||
  current
    .split('.')
    .map((n, i) => (i === 2 ? Number(n) + 1 : n))
    .join('.')
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`bad version: ${version}`)

const repo = execSync('git remote get-url origin', { cwd: root, encoding: 'utf8' })
  .trim()
  .match(/github\.com[:/](.+?)(?:\.git)?$/)[1]
const token =
  process.env.GITHUB_TOKEN ||
  execSync('git credential fill', { cwd: root, input: 'protocol=https\nhost=github.com\n\n', encoding: 'utf8' }).match(/^password=(.*)$/m)[1]

async function gh(url, init = {}) {
  const r = await fetch(url, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'User-Agent': 'vibe-code-release', ...init.headers }
  })
  if (!r.ok) throw new Error(`${init.method || 'GET'} ${url}: ${r.status} ${await r.text()}`)
  return r.json()
}

async function main() {
  console.log(`Releasing ${current} -> ${version}`)
  write('package.json', read('package.json').replace(/"version": "[^"]+"/, `"version": "${version}"`))
  write('src-zig/build.zig.zon', read('src-zig/build.zig.zon').replace(/\.version = "[^"]+"/, `.version = "${version}"`))
  write('src-zig/build.zig', read('src-zig/build.zig').replace(/"app version"\) orelse "[^"]+"/, `"app version") orelse "${version}"`))

  run('npm run build')

  // the installer: NSIS and its nsis_tauri_utils plugin, as the Tauri CLI downloaded them
  const nsis = path.join(process.env.LOCALAPPDATA, 'tauri', 'NSIS')
  if (!fs.existsSync(path.join(nsis, 'makensis.exe'))) throw new Error(`NSIS not found: ${nsis}`)
  const bin = path.join(root, 'src-zig/zig-out/bin')
  const size = ['vibe-code.exe', 'WebView2Loader.dll'].reduce((n, f) => n + fs.statSync(path.join(bin, f)).size, 0)
  const exe = path.join(root, 'src-zig/zig-out', `VIBE CODE_${version}_x64-setup.exe`)
  execSync(
    [
      `"${path.join(nsis, 'makensis.exe')}" -V2 -INPUTCHARSET UTF8`,
      `"-DVERSION=${version}"`,
      `"-DBINDIR=${bin}"`,
      `"-DOUTFILE=${exe}"`,
      `"-DADDITIONALPLUGINSPATH=${path.join(nsis, 'Plugins/x86-unicode/additional')}"`,
      `-DESTIMATEDSIZE=${Math.ceil(size / 1024)}`,
      'installer.nsi'
    ].join(' '),
    { cwd: path.join(root, 'src-zig/installer'), stdio: 'inherit' }
  )
  if (!fs.existsSync(exe)) throw new Error(`installer not found: ${exe}`)

  // release notes the app's update popup shows: the commits since the previous release
  const git = (cmd) => execSync(cmd, { cwd: root, encoding: 'utf8' }).trim()
  const prev = git('git log -1 --format=%H --grep="^Release v"')
  const notes = git(`git log --no-merges --format="- %s" ${prev ? `${prev}..HEAD` : '-20'}`)

  run(`git commit -m "Release v${version}" -- package.json src-zig/build.zig.zon src-zig/build.zig`)
  run('git push')

  const branch = execSync('git rev-parse --abbrev-ref HEAD', { cwd: root, encoding: 'utf8' }).trim()
  const rel = await gh(`https://api.github.com/repos/${repo}/releases`, {
    method: 'POST',
    body: JSON.stringify({ tag_name: `v${version}`, target_commitish: branch, name: `v${version}`, body: notes })
  })
  // same name every release, so releases/latest/download/vibe-code_x64-setup.exe always gets the newest
  const name = 'vibe-code_x64-setup.exe'
  await gh(`https://uploads.github.com/repos/${repo}/releases/${rel.id}/assets?name=${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream' },
    body: fs.readFileSync(exe)
  })
  console.log(`Published ${rel.html_url}`)
}

main().catch((e) => {
  console.error(e.message)
  process.exit(1)
})
