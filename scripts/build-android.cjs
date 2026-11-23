// `npm run build:android`: the phone remote's APK (android/) → android/build/vibe-code-remote.apk.
//
// No Gradle, no Kotlin, no AndroidX: one Java file and the SDK's own tools (aapt2, javac, d8,
// zipalign, apksigner), so the APK is a few dozen KB and builds in seconds. Needs an Android SDK
// with a platform and build-tools (ANDROID_HOME, default %LOCALAPPDATA%\Android\Sdk) and a JDK
// (JAVA_HOME, default Android Studio's). The signing key is made on first build in
// android/release.jks (git-ignored): keep it, or phones must uninstall before the next APK installs.
const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const app = path.join(root, 'android')
const out = path.join(app, 'build')
const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk')
const jdk = process.env.JAVA_HOME || 'C:\\Program Files\\Android\\Android Studio\\jbr'
const win = process.platform === 'win32'
// d8 and apksigner are Java programs started by .bat files that look for java on PATH
process.env.JAVA_HOME = jdk
process.env.PATH = path.join(jdk, 'bin') + path.delimiter + process.env.PATH

/** the newest installed version in an SDK folder */
function newest(dir, prefix = '') {
  const names = fs.existsSync(dir) ? fs.readdirSync(dir).filter((n) => n.startsWith(prefix)) : []
  const num = (n) => n.slice(prefix.length).split(/[.-]/).map(Number)
  names.sort((a, b) => {
    const x = num(a)
    const y = num(b)
    for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0)
    return 0
  })
  if (!names.length) throw new Error(`nothing in ${dir} — install it with sdkmanager ("platforms;android-35", "build-tools;35.0.0")`)
  return path.join(dir, names[names.length - 1])
}

const tools = newest(path.join(sdk, 'build-tools'))
const androidJar = path.join(newest(path.join(sdk, 'platforms'), 'android-'), 'android.jar')
const tool = (name) => path.join(tools, name + (win ? (['d8', 'apksigner'].includes(name) ? '.bat' : '.exe') : ''))
const java = (name) => path.join(jdk, 'bin', name + (win ? '.exe' : ''))

function run(cmd, args, opts = {}) {
  // the SDK's .bat wrappers need a shell
  execFileSync(cmd, args, { stdio: 'inherit', shell: cmd.endsWith('.bat'), ...opts })
}
const q = (p) => (win ? `"${p}"` : p)

const files = (dir, ext) => fs.readdirSync(dir, { recursive: true }).filter((f) => f.endsWith(ext)).map((f) => path.join(dir, f))

const { version } = require(path.join(root, 'package.json'))
const [major, minor, patch] = version.split('.').map(Number)
const versionCode = String(major * 10000 + minor * 100 + patch)

fs.rmSync(out, { recursive: true, force: true })
fs.mkdirSync(path.join(out, 'classes'), { recursive: true })

console.log(`VIBE CODE Remote ${version} — ${path.basename(tools)}, ${path.basename(path.dirname(androidJar))}`)

// resources + manifest + assets
run(tool('aapt2'), ['compile', '--dir', path.join(app, 'res'), '-o', path.join(out, 'res.zip')])
run(tool('aapt2'), [
  'link',
  '-o', path.join(out, 'base.apk'),
  '-I', androidJar,
  '--manifest', path.join(app, 'AndroidManifest.xml'),
  '-A', path.join(app, 'assets'),
  '--min-sdk-version', '24',
  '--target-sdk-version', '34',
  '--version-code', versionCode,
  '--version-name', version,
  path.join(out, 'res.zip')
])

// code
run(java('javac'), ['-nowarn', '-Xlint:-options', '-source', '8', '-target', '8', '-encoding', 'UTF-8', '-bootclasspath', androidJar, '-classpath', path.join(tools, 'core-lambda-stubs.jar'), '-d', path.join(out, 'classes'), ...files(path.join(app, 'src'), '.java')])
const d8Args = ['--release', '--min-api', '24', '--lib', androidJar, '--output', out, ...files(path.join(out, 'classes'), '.class')]
run(tool('d8'), win ? d8Args.map(q) : d8Args)
run(tool('aapt'), ['add', 'base.apk', 'classes.dex'], { cwd: out, stdio: 'ignore' })

// align, sign
run(tool('zipalign'), ['-p', '-f', '4', path.join(out, 'base.apk'), path.join(out, 'aligned.apk')])
const ks = path.join(app, 'release.jks')
const pass = process.env.VIBE_REMOTE_KEY_PASS || 'vibecode'
if (!fs.existsSync(ks)) {
  console.log('making the signing key android/release.jks')
  run(java('keytool'), ['-genkeypair', '-keystore', ks, '-alias', 'vibe', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000', '-storepass', pass, '-keypass', pass, '-dname', 'CN=VIBE CODE Remote'], { stdio: 'ignore' })
}
const apk = path.join(out, 'vibe-code-remote.apk')
const signArgs = ['sign', '--ks', ks, '--ks-pass', 'pass:' + pass, '--out', apk, path.join(out, 'aligned.apk')]
run(tool('apksigner'), win ? signArgs.map(q) : signArgs)

for (const f of ['res.zip', 'base.apk', 'aligned.apk', 'classes.dex', 'vibe-code-remote.apk.idsig']) fs.rmSync(path.join(out, f), { force: true })
fs.rmSync(path.join(out, 'classes'), { recursive: true, force: true })
console.log(`\n${path.relative(root, apk)} (${(fs.statSync(apk).size / 1024).toFixed(1)} KB)`)
