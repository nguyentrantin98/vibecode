/**
 * The computer's screen on the phone, with its mouse and keyboard (served by
 * src-zig/src/remote_desk.zig, over the same WebSocket as the chats).
 *
 * The phone asks for exactly the part of the screen it shows, at its own pixel size: zoomed out it
 * gets a small picture, zoomed in sharp text. Frames only carry the parts that changed; each is
 * acknowledged once drawn, which paces the computer to the network.
 *
 * Touch: tap = click · double tap = double click · hold = right click · hold then move = drag
 * (select, move a window) · one finger = move around when zoomed in · pinch = zoom ·
 * two fingers up/down = scroll.
 */

type Send = (msg: Record<string, unknown>) => boolean
interface Screen {
  x: number
  y: number
  w: number
  h: number
  primary: boolean
}
interface Box {
  x: number
  y: number
  w: number
  h: number
}

const vi = navigator.language.toLowerCase().startsWith('vi')
const t = (en: string, viText: string): string => (vi ? viText : en)

let send: Send = () => false
let root: HTMLElement | null = null
let stage: HTMLCanvasElement
let ctx: CanvasRenderingContext2D
let note: HTMLElement
/** the last picture and the part of the screen it shows */
const img = document.createElement('canvas')
const ictx = img.getContext('2d')!
let imgView: Box | null = null
let cursor = { x: 0, y: 0 }
let screens: Screen[] = []
let mon = Number(localStorage.getItem('vibe.desk.mon') || 0)
let sharp = localStorage.getItem('vibe.desk.sharp') !== '0'
/** stage pixels per screen pixel, and the screen point at the stage's top left */
let scale = 1
let ox = 0
let oy = 0
let W = 1
let H = 1
let fitted = true
let frames: Promise<void> = Promise.resolve()
const mods = new Set<string>()
let modButtons: Record<string, HTMLElement> = {}
let monBtn: HTMLElement

/* ---------------- entry points (main.ts) ---------------- */

/** Builds the view in `app` and starts the stream; `back` leaves it. */
export function deskView(app: HTMLElement, sendFn: Send, back: () => void): void {
  send = sendFn
  imgView = null
  stage = el('canvas', 'desk-stage') as HTMLCanvasElement
  ctx = stage.getContext('2d')!
  note = el('div', 'desk-note', t('Connecting to the screen…', 'Đang kết nối màn hình…'))
  const wrap = el('div', 'desk-wrap')
  wrap.append(stage, note)
  root = el('div', 'desk')
  root.append(wrap, keyboardRow(), toolbar(back))
  app.append(root)
  touch(stage)
  new ResizeObserver(resize).observe(wrap)
  deskStart()
}

/** (Re)starts the stream: when the view opens and after a reconnection. */
export function deskStart(): void {
  if (root?.isConnected) send({ t: 'desk.start' })
}

export function deskStop(): void {
  if (root) send({ t: 'desk.stop' })
  root = null
}

export function deskMessage(m: Record<string, unknown>): void {
  if (!root?.isConnected) return
  if (m.t === 'desk.off') {
    note.textContent = t(
      'The computer does not allow screen control. On the computer: phone icon in the status bar → “Allow screen control”.',
      'Máy tính chưa cho phép điều khiển màn hình. Trên máy tính: biểu tượng điện thoại ở thanh trạng thái → “Cho điều khiển màn hình”.'
    )
    note.style.display = ''
  } else if (m.t === 'desk.info') {
    screens = (m.screens as Screen[]) || []
    if (mon >= screens.length) mon = 0
    monBtn.style.display = screens.length > 1 ? '' : 'none'
    fit()
  }
}

export function deskFrame(buf: ArrayBuffer): void {
  frames = frames.then(() => applyFrame(buf)).catch(() => {})
}

/* ---------------- frames ---------------- */

async function applyFrame(buf: ArrayBuffer): Promise<void> {
  const dv = new DataView(buf)
  if (dv.getUint8(0) !== 1) return
  const seq = dv.getUint32(4, true)
  try {
    const whole = (dv.getUint8(1) & 1) !== 0
    const view = { x: dv.getInt32(8, true), y: dv.getInt32(12, true), w: dv.getUint32(16, true), h: dv.getUint32(20, true) }
    const pw = dv.getUint16(24, true)
    const ph = dv.getUint16(26, true)
    cursor = { x: dv.getInt32(28, true), y: dv.getInt32(32, true) }
    const n = dv.getUint16(36, true)
    let off = 38
    const parts: { x: number; y: number; blob: Blob }[] = []
    for (let i = 0; i < n; i++) {
      const len = dv.getUint32(off + 8, true)
      parts.push({ x: dv.getUint16(off, true), y: dv.getUint16(off + 2, true), blob: new Blob([new Uint8Array(buf, off + 12, len)], { type: 'image/jpeg' }) })
      off += 12 + len
    }
    const pics = await Promise.all(parts.map((p) => createImageBitmap(p.blob)))
    if (whole || img.width !== pw || img.height !== ph) {
      img.width = pw
      img.height = ph
    }
    pics.forEach((pic, i) => {
      ictx.drawImage(pic, parts[i].x, parts[i].y)
      pic.close()
    })
    imgView = view
    note.style.display = 'none'
    draw()
  } finally {
    send({ t: 'desk.ack', seq })
  }
}

let drawQueued = false
function draw(): void {
  if (drawQueued) return
  drawQueued = true
  requestAnimationFrame(() => {
    drawQueued = false
    const dpr = devicePixelRatio || 1
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.fillStyle = '#000'
    ctx.fillRect(0, 0, W, H)
    if (imgView) {
      ctx.imageSmoothingQuality = 'high'
      ctx.drawImage(img, (imgView.x - ox) * scale, (imgView.y - oy) * scale, imgView.w * scale, imgView.h * scale)
      // the mouse pointer (the picture has none)
      const cx = (cursor.x - ox) * scale
      const cy = (cursor.y - oy) * scale
      ctx.beginPath()
      ctx.moveTo(cx, cy)
      ctx.lineTo(cx, cy + 17)
      ctx.lineTo(cx + 4.5, cy + 13)
      ctx.lineTo(cx + 12, cy + 12)
      ctx.closePath()
      ctx.fillStyle = '#fff'
      ctx.strokeStyle = '#000'
      ctx.lineWidth = 1.2
      ctx.fill()
      ctx.stroke()
    }
  })
}

/* ---------------- view: which part of the screen, how big ---------------- */

const screen = (): Screen => screens[mon] ?? { x: 0, y: 0, w: 1920, h: 1080, primary: true }
const minScale = (): number => Math.min(W / screen().w, H / screen().h)
const maxScale = (): number => Math.max(minScale() * 2, 3)

function resize(): void {
  const r = stage.parentElement!.getBoundingClientRect()
  const dpr = devicePixelRatio || 1
  // the screen point in the middle stays there
  const mid = { x: ox + W / 2 / scale, y: oy + H / 2 / scale }
  W = Math.max(1, r.width)
  H = Math.max(1, r.height)
  stage.width = Math.round(W * dpr)
  stage.height = Math.round(H * dpr)
  if (fitted) return fit()
  scale = Math.max(scale, minScale())
  ox = mid.x - W / 2 / scale
  oy = mid.y - H / 2 / scale
  settle()
}

function fit(): void {
  fitted = true
  scale = minScale()
  ox = screen().x
  oy = screen().y
  settle()
}

/** Keeps the screen in sight (centred when smaller than the phone), then asks for the picture. */
function settle(): void {
  const s = screen()
  const vw = W / scale
  const vh = H / scale
  ox = vw >= s.w ? s.x - (vw - s.w) / 2 : Math.min(Math.max(ox, s.x), s.x + s.w - vw)
  oy = vh >= s.h ? s.y - (vh - s.h) / 2 : Math.min(Math.max(oy, s.y), s.y + s.h - vh)
  draw()
  askView()
}

let viewTimer: ReturnType<typeof setTimeout> | undefined
function askView(): void {
  clearTimeout(viewTimer)
  viewTimer = setTimeout(() => {
    const s = screen()
    const x0 = Math.max(ox, s.x)
    const y0 = Math.max(oy, s.y)
    const x1 = Math.min(ox + W / scale, s.x + s.w)
    const y1 = Math.min(oy + H / scale, s.y + s.h)
    if (x1 <= x0 || y1 <= y0) return
    const px = scale * (sharp ? devicePixelRatio || 1 : 1)
    send({
      t: 'desk.view',
      x: Math.floor(x0),
      y: Math.floor(y0),
      w: Math.ceil(x1 - x0),
      h: Math.ceil(y1 - y0),
      pw: Math.round((x1 - x0) * px),
      ph: Math.round((y1 - y0) * px),
      q: sharp ? 0.7 : 0.45
    })
  }, 120)
}

/** A point on the stage → the screen. */
const toScreen = (x: number, y: number): { x: number; y: number } => ({ x: ox + x / scale, y: oy + y / scale })

/* ---------------- touch ---------------- */

function touch(c: HTMLCanvasElement): void {
  type Mode = 'idle' | 'tap' | 'held' | 'drag' | 'pan' | 'two' | 'pinch' | 'scroll' | 'done'
  let mode: Mode = 'idle'
  let start = { x: 0, y: 0 }
  let last = { x: 0, y: 0 }
  let hold: ReturnType<typeof setTimeout> | undefined
  let lastMove = 0
  let two = { dist: 1, mid: { x: 0, y: 0 }, scale: 1, at: { x: 0, y: 0 }, acc: 0 }
  const pos = (t: Touch): { x: number; y: number } => {
    const r = c.getBoundingClientRect()
    return { x: t.clientX - r.left, y: t.clientY - r.top }
  }
  const pair = (e: TouchEvent): { dist: number; mid: { x: number; y: number } } => {
    const a = pos(e.touches[0])
    const b = pos(e.touches[1])
    return { dist: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 } }
  }

  c.addEventListener(
    'touchstart',
    (e) => {
      e.preventDefault()
      clearTimeout(hold)
      if (e.touches.length === 1 && (mode === 'idle' || mode === 'done')) {
        start = last = pos(e.touches[0])
        mode = 'tap'
        hold = setTimeout(() => {
          if (mode !== 'tap') return
          mode = 'held'
          navigator.vibrate?.(25)
        }, 450)
      } else if (e.touches.length === 2) {
        if (mode === 'drag') mouse('up', last)
        const p = pair(e)
        two = { dist: p.dist, mid: p.mid, scale, at: toScreen(p.mid.x, p.mid.y), acc: 0 }
        mode = 'two'
      }
    },
    { passive: false }
  )

  c.addEventListener(
    'touchmove',
    (e) => {
      e.preventDefault()
      if (e.touches.length === 1 && ['tap', 'held', 'drag', 'pan'].includes(mode)) {
        const p = pos(e.touches[0])
        const moved = Math.hypot(p.x - start.x, p.y - start.y) > 10
        if (mode === 'tap' && moved) {
          clearTimeout(hold)
          mode = 'pan'
        }
        if (mode === 'held' && moved) {
          mode = 'drag'
          mouse('down', start)
        }
        if (mode === 'pan') {
          ox -= (p.x - last.x) / scale
          oy -= (p.y - last.y) / scale
          fitted = false
          settle()
        } else if (mode === 'drag' && performance.now() - lastMove > 30) {
          lastMove = performance.now()
          mouse('move', p)
        }
        last = p
      } else if (e.touches.length === 2 && ['two', 'pinch', 'scroll'].includes(mode)) {
        const p = pair(e)
        const ratio = p.dist / two.dist
        if (mode === 'two') {
          if (Math.abs(ratio - 1) > 0.06) mode = 'pinch'
          else if (Math.hypot(p.mid.x - two.mid.x, p.mid.y - two.mid.y) > 12) mode = 'scroll'
        }
        if (mode === 'pinch') {
          scale = Math.min(maxScale(), Math.max(minScale(), two.scale * ratio))
          fitted = scale <= minScale() + 1e-6
          // the screen point that was under the fingers stays under them
          ox = two.at.x - p.mid.x / scale
          oy = two.at.y - p.mid.y / scale
          settle()
        } else if (mode === 'scroll') {
          two.acc += p.mid.y - two.mid.y
          two.mid = p.mid
          const notches = Math.trunc(two.acc / 40)
          if (notches) {
            two.acc -= notches * 40
            const at = toScreen(p.mid.x, p.mid.y)
            send({ t: 'desk.wheel', x: at.x, y: at.y, dy: notches * 120 })
          }
        }
      }
    },
    { passive: false }
  )

  const end = (e: TouchEvent): void => {
    e.preventDefault()
    clearTimeout(hold)
    if (e.touches.length > 0) {
      // one of two fingers lifted: nothing more until both are
      if (mode === 'two' || mode === 'pinch' || mode === 'scroll') mode = 'done'
      return
    }
    if (mode === 'tap') mouse('click', start)
    else if (mode === 'held') mouse('rclick', start)
    else if (mode === 'drag') mouse('up', last)
    mode = 'idle'
  }
  c.addEventListener('touchend', end, { passive: false })
  c.addEventListener('touchcancel', end, { passive: false })
}

function mouse(a: string, p: { x: number; y: number }): void {
  const at = toScreen(p.x, p.y)
  send({ t: 'desk.mouse', a, x: at.x, y: at.y, mods: takeMods(a !== 'move' && a !== 'up') })
  // the pointer moves at once on the phone, before the next frame says so
  cursor = { x: Math.round(at.x), y: Math.round(at.y) }
  draw()
}

/* ---------------- keyboard and buttons ---------------- */

/** The modifiers to send, cleared after a key or a click (`use`). */
function takeMods(use = true): string[] {
  const list = [...mods]
  if (use && list.length) {
    mods.clear()
    for (const b of Object.values(modButtons)) b.classList.remove('on')
  }
  return list
}

function key(k: string, extra: string[] = []): void {
  send({ t: 'desk.key', k, mods: [...new Set([...takeMods(), ...extra])] })
}

let kbRow: HTMLElement
function keyboardRow(): HTMLElement {
  const input = el('input', 'desk-input') as HTMLInputElement
  input.placeholder = t('Type, then Enter to send', 'Gõ rồi Enter để gửi')
  input.autocomplete = 'off'
  input.setAttribute('autocapitalize', 'off')
  input.setAttribute('autocorrect', 'off')
  input.spellcheck = false
  const go = (): void => {
    if (input.value) {
      send({ t: 'desk.text', s: input.value })
      input.value = ''
    } else key('Enter')
  }
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      go()
    } else if (e.key === 'Backspace' && !input.value) {
      e.preventDefault()
      key('Backspace')
    }
  })
  const btn = el('button', 'btn small primary', t('Send', 'Gửi'))
  btn.onclick = () => {
    go()
    input.focus()
  }
  kbRow = el('div', 'desk-kb')
  kbRow.append(input, btn)
  kbRow.style.display = 'none'
  return kbRow
}

function toolbar(back: () => void): HTMLElement {
  const bar = el('div', 'desk-bar')
  const b = (label: string, title: string, onclick: () => void, cls = ''): HTMLElement => {
    const x = el('button', 'desk-key ' + cls, label)
    x.title = title
    x.onclick = onclick
    bar.append(x)
    return x
  }
  b('✕', t('Back to the chats', 'Về danh sách chat'), back, 'close')
  b('⌨', t('Keyboard', 'Bàn phím'), () => {
    const show = kbRow.style.display === 'none'
    kbRow.style.display = show ? '' : 'none'
    if (show) (kbRow.firstChild as HTMLInputElement).focus()
  })
  modButtons = {}
  for (const [m, label] of [
    ['ctrl', 'Ctrl'],
    ['alt', 'Alt'],
    ['shift', 'Shift'],
    ['win', 'Win']
  ]) {
    const x = b(label, t(`${label}: held for the next key or click`, `${label}: giữ cho phím hoặc cú bấm kế tiếp`), () => {
      if (mods.has(m)) mods.delete(m)
      else mods.add(m)
      x.classList.toggle('on', mods.has(m))
    })
    modButtons[m] = x
  }
  const keys: [string, string][] = [
    ['Esc', 'Esc'],
    ['Tab', 'Tab'],
    ['⏎', 'Enter'],
    ['⌫', 'Backspace'],
    ['Del', 'Delete'],
    ['←', 'Left'],
    ['↑', 'Up'],
    ['↓', 'Down'],
    ['→', 'Right'],
    ['Home', 'Home'],
    ['End', 'End'],
    ['PgUp', 'PageUp'],
    ['PgDn', 'PageDown']
  ]
  for (const [label, k] of keys) b(label, k, () => key(k))
  const combos: [string, string, string[]][] = [
    ['Ctrl+C', 'C', ['ctrl']],
    ['Ctrl+V', 'V', ['ctrl']],
    ['Ctrl+Z', 'Z', ['ctrl']],
    ['Ctrl+A', 'A', ['ctrl']],
    ['Ctrl+S', 'S', ['ctrl']],
    ['Alt+Tab', 'Tab', ['alt']],
    ['Win+D', 'D', ['win']],
    ['Win+E', 'E', ['win']],
    ['Alt+F4', 'F4', ['alt']],
    ['Ctrl+Shift+Esc', 'Esc', ['ctrl', 'shift']]
  ]
  for (const [label, k, m] of combos) b(label, label, () => key(k, m))
  for (let i = 1; i <= 12; i++) b('F' + i, 'F' + i, () => key('F' + i))
  b(t('R-click', 'Chuột phải'), t('Right click where the pointer is', 'Bấm chuột phải tại con trỏ'), () =>
    send({ t: 'desk.mouse', a: 'rclick', x: cursor.x, y: cursor.y, mods: takeMods() })
  )
  b('⤢', t('Whole screen', 'Cả màn hình'), fit)
  monBtn = b('🖥', t('Next monitor', 'Màn hình kế tiếp'), () => {
    if (screens.length < 2) return
    mon = (mon + 1) % screens.length
    localStorage.setItem('vibe.desk.mon', String(mon))
    fit()
  })
  monBtn.style.display = 'none'
  const q = b(sharp ? 'HD' : 'SD', t('Sharp (more data) or light (faster on a slow network)', 'Nét (tốn dữ liệu hơn) hay nhẹ (nhanh hơn khi mạng yếu)'), () => {
    sharp = !sharp
    localStorage.setItem('vibe.desk.sharp', sharp ? '1' : '0')
    q.textContent = sharp ? 'HD' : 'SD'
    askView()
  })
  return bar
}

function el(tag: string, cls: string, text?: string): HTMLElement {
  const x = document.createElement(tag)
  x.className = cls
  if (text !== undefined) x.textContent = text
  return x
}
