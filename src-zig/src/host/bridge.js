// Injected into every page the app owns (main window, toast, capture) before its own scripts:
// `window.__VIBE__` is the door to the native side.
//   invoke(cmd, args, { headers })  POST <origin>/__ipc/<cmd>; args: object → JSON, Uint8Array /
//                                   ArrayBuffer → raw body. Resolves with the JSON reply, or an
//                                   ArrayBuffer for binary replies; rejects with the error text.
//   listen(event, cb)               native events; cb gets { event, payload }; returns unlisten
//   Channel                         a stream from one call: new Channel(); ch.onmessage = …
(() => {
  if (window.__VIBE__) return
  const IPC = __IPC_ORIGIN__ + '/__ipc/'
  const listeners = new Map()
  const channels = new Map()
  let nextChannel = 1

  class Channel {
    constructor() {
      this.id = nextChannel++
      this.onmessage = () => {}
      channels.set(this.id, this)
    }
    toJSON() {
      return '__CHANNEL__:' + this.id
    }
  }

  async function invoke(cmd, args, opts) {
    const headers = Object.assign({}, opts && opts.headers)
    let body
    if (args instanceof Uint8Array || args instanceof ArrayBuffer) {
      body = args
      headers['Content-Type'] = 'application/octet-stream'
    } else {
      body = JSON.stringify(args === undefined ? {} : args)
      headers['Content-Type'] = 'application/json'
    }
    const r = await fetch(IPC + cmd, { method: 'POST', body, headers })
    const type = r.headers.get('Content-Type') || ''
    if (!r.ok) throw await r.text()
    if (type.startsWith('application/octet-stream')) return r.arrayBuffer()
    const text = await r.text()
    return text ? JSON.parse(text) : null
  }

  function listen(event, cb) {
    let set = listeners.get(event)
    if (!set) listeners.set(event, (set = new Set()))
    const f = (payload) => cb({ event, payload })
    set.add(f)
    return () => set.delete(f)
  }

  // native → page: { e, p } an event, { c, m } a channel message
  function recv(msg) {
    if (typeof msg === 'string') msg = JSON.parse(msg)
    if (msg.c !== undefined) {
      const ch = channels.get(msg.c)
      if (ch) ch.onmessage(msg.m)
      return
    }
    const set = listeners.get(msg.e)
    if (set) for (const f of set) f(msg.p)
  }

  window.__VIBE__ = { invoke, listen, Channel, recv }
  if (window.chrome && window.chrome.webview) window.chrome.webview.addEventListener('message', (e) => recv(e.data))
})()
