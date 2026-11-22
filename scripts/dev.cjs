// `npm run dev`: a debug build of the app (src-zig) showing the page from vite, with hot reload.
// Closing the app stops vite.
const { spawn } = require('node:child_process')
const path = require('node:path')

const root = path.join(__dirname, '..')
const vite = spawn(process.execPath, [path.join(root, 'node_modules/vite/bin/vite.js')], { cwd: root, stdio: 'inherit' })
const app = spawn('zig', ['build', 'run'], {
  cwd: path.join(root, 'src-zig'),
  stdio: 'inherit',
  env: { ...process.env, VIBE_DEV_URL: 'http://127.0.0.1:5173' }
})
app.on('exit', (code) => {
  vite.kill()
  process.exit(code ?? 0)
})
