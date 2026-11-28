/**
 * The computer's screen on the phone, with its mouse and keyboard (served by
 * src-zig/src/remote_desk.zig, over the same WebSocket as the chats).
 *
 * The phone asks for exactly the part of the screen it shows, at its own pixel size: zoomed out it
 * gets a small picture, zoomed in sharp text. Frames only carry the parts that changed; each is
 * acknowledged once drawn, which paces the computer to the network.
 *
 * Touch, as in remote desktop apps: tap = click · double tap = double click (the second tap lands
 * where the first did) · hold = right click · hold then move = drag (select, move a window) ·
 * two-finger tap = right click · one finger = move around when zoomed in · pinch = zoom ·
 * two fingers up/down = scroll. Moving around and scrolling glide on after the fingers lift.
 * Everything the finger does shows at once on the phone; the computer's picture follows.
 *
 * The controls float over the screen: a dock (move it by its grip) with the modifier keys, and a
 * key sheet sorted by use — keys, shortcuts, F1–F12, display.
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
interface Pt {
  x: number
  y: number
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
/** every button of each modifier (the dock's and the sheet's) */
let modButtons: Record<string, HTMLElement[]> = {}
let monBtn: HTMLElement
/** touch feedback on the stage: a ring while holding, a ripple after a click */
let marks: { x: number; y: number; at: number; kind: 'tap' | 'hold' }[] = []

/* ---------------- entry points (main.ts) ---------------- */

/** Builds the view in `app` and starts the stream; `back` leaves it. */
export function deskView(app: HTMLElement, sendFn: Send, back: () => void): void {
  send = sendFn
  imgView = null
  modButtons = {}
  stage = el('canvas', 'desk-stage') as HTMLCanvasElement
  ctx = stage.getContext('2d')!
  note = el('div', 'desk-note', t('Connecting to the screen…', 'Đang kết nối màn hình…'))
  const wrap = el('div', 'desk-wrap')
  wrap.append(stage, note)
  root = el('div', 'desk')
  const sheet = keySheet()
  const kb = keyboardRow()
  root.append(wrap, sheet, kb, dock(back, sheet, kb))
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
    // while a finger drives the pointer, the phone's own position is the newer one
    if (performance.now() - pointerAt > 400) cursor = { x: dv.getInt32(28, true), y: dv.getInt32(32, true) }
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
    if (!imgView) return
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
    // touch feedback
    const now = performance.now()
    marks = marks.filter((m) => now - m.at < (m.kind === 'tap' ? 350 : 60000))
    for (const m of marks) {
      const k = Math.min(1, (now - m.at) / (m.kind === 'tap' ? 350 : HOLD_MS))
      ctx.beginPath()
      if (m.kind === 'tap') {
        ctx.arc(m.x, m.y, 10 + 18 * k, 0, Math.PI * 2)
        ctx.strokeStyle = `rgba(10,132,255,${1 - k})`
        ctx.lineWidth = 3
        ctx.stroke()
      } else {
        // fills up while the finger is held: full = right click (or drag)
        ctx.arc(m.x, m.y, 26, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * k)
        ctx.strokeStyle = 'rgba(10,132,255,0.9)'
        ctx.lineWidth = 4
        ctx.stroke()
      }
    }
    if (marks.length) draw()
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
const toScreen = (p: Pt): Pt => ({ x: ox + p.x / scale, y: oy + p.y / scale })

/* ---------------- touch ---------------- */

const HOLD_MS = 450
const SLOP = 10
/** the last time a finger moved the pointer (frames' pointer position is older then) */
let pointerAt = 0

/** Runs `step(dt)` every animation frame until it returns false (or `stop` is called). */
function glide(step: (dt: number) => boolean): () => void {
  let on = true
  let last = performance.now()
  const tick = (now: number): void => {
    if (!on) return
    const dt = Math.min(50, now - last)
    last = now
    if (step(dt)) requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
  return () => (on = false)
}

/** Finger speed in px/ms over the last ~100 ms. */
class Velocity {
  private s: { t: number; x: number; y: number }[] = []
  add(p: Pt): void {
    const now = performance.now()
    this.s.push({ t: now, x: p.x, y: p.y })
    while (this.s.length > 2 && now - this.s[0].t > 100) this.s.shift()
  }
  get(): Pt {
    if (this.s.length < 2) return { x: 0, y: 0 }
    const a = this.s[0]
    const b = this.s[this.s.length - 1]
    const dt = Math.max(1, b.t - a.t)
    return performance.now() - b.t > 80 ? { x: 0, y: 0 } : { x: (b.x - a.x) / dt, y: (b.y - a.y) / dt }
  }
  clear(): void {
    this.s = []
  }
}

function touch(c: HTMLCanvasElement): void {
  type Mode = 'idle' | 'tap' | 'held' | 'drag' | 'pan' | 'two' | 'pinch' | 'scroll' | 'done'
  let mode: Mode = 'idle'
  let start: Pt = { x: 0, y: 0 }
  let last: Pt = { x: 0, y: 0 }
  let hold: ReturnType<typeof setTimeout> | undefined
  let holdMark: (typeof marks)[number] | null = null
  let twoAt = 0
  let two = { dist: 1, mid: { x: 0, y: 0 }, scale: 1, at: { x: 0, y: 0 } }
  /** the last click, for double clicks: the second one lands on the first one's point */
  let lastTap = { at: 0, p: { x: 0, y: 0 } }
  const vel = new Velocity()
  let stopGlide: () => void = () => {}
  // mouse moves while dragging: the newest position, sent once per frame
  let movePending: Pt | null = null
  // scroll: wheel units not sent yet
  let wheelAcc = 0
  let wheelAt: Pt = { x: 0, y: 0 }

  const pos = (e: Touch): Pt => {
    const r = c.getBoundingClientRect()
    return { x: e.clientX - r.left, y: e.clientY - r.top }
  }
  const pair = (e: TouchEvent): { dist: number; mid: Pt } => {
    const a = pos(e.touches[0])
    const b = pos(e.touches[1])
    return { dist: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 } }
  }
  const unhold = (): void => {
    clearTimeout(hold)
    if (holdMark) marks = marks.filter((m) => m !== holdMark)
    holdMark = null
  }
  const pan = (dx: number, dy: number): void => {
    ox -= dx / scale
    oy -= dy / scale
    fitted = false
    settle()
  }
  /** Finger pixels → wheel units: 120 (one notch, three lines) per 40 px, sent as they add up. */
  const wheel = (dy: number, flush = false): void => {
    wheelAcc += dy * 3
    const n = Math.trunc(wheelAcc)
    if (n && (Math.abs(n) >= 15 || flush)) {
      wheelAcc -= n
      const at = toScreen(wheelAt)
      send({ t: 'desk.wheel', x: at.x, y: at.y, dy: n })
    }
  }

  c.addEventListener(
    'touchstart',
    (e) => {
      e.preventDefault()
      stopGlide()
      if (e.touches.length === 1 && (mode === 'idle' || mode === 'done')) {
        start = last = pos(e.touches[0])
        vel.clear()
        vel.add(start)
        mode = 'tap'
        holdMark = { ...start, at: performance.now(), kind: 'hold' }
        // the ring shows only once it is clearly a hold, not on every tap
        hold = setTimeout(() => {
          if (mode !== 'tap') return
          mode = 'held'
          navigator.vibrate?.(25)
          draw()
        }, HOLD_MS)
        setTimeout(() => {
          if (mode === 'tap' && holdMark) {
            holdMark.at = performance.now() - 150
            marks.push(holdMark)
            draw()
          }
        }, 150)
      } else if (e.touches.length === 2) {
        unhold()
        if (mode === 'drag') mouse('up', last)
        const p = pair(e)
        two = { dist: p.dist, mid: p.mid, scale, at: toScreen(p.mid) }
        twoAt = performance.now()
        wheelAcc = 0
        wheelAt = p.mid
        vel.clear()
        vel.add(p.mid)
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
        const moved = Math.hypot(p.x - start.x, p.y - start.y) > SLOP
        if (mode === 'tap' && moved) {
          unhold()
          mode = 'pan'
        }
        if (mode === 'held' && moved) {
          unhold()
          mode = 'drag'
          mouse('down', start)
        }
        if (mode === 'pan') pan(p.x - last.x, p.y - last.y)
        else if (mode === 'drag') {
          if (!movePending)
            requestAnimationFrame(() => {
              if (movePending) mouse('move', movePending)
              movePending = null
            })
          movePending = p
        }
        vel.add(p)
        last = p
      } else if (e.touches.length === 2 && ['two', 'pinch', 'scroll'].includes(mode)) {
        const p = pair(e)
        const ratio = p.dist / two.dist
        if (mode === 'two') {
          if (Math.abs(ratio - 1) > 0.06) mode = 'pinch'
          else if (Math.hypot(p.mid.x - two.mid.x, p.mid.y - two.mid.y) > SLOP) mode = 'scroll'
        }
        if (mode === 'pinch') {
          scale = Math.min(maxScale(), Math.max(minScale(), two.scale * ratio))
          fitted = scale <= minScale() + 1e-6
          // the screen point that was under the fingers stays under them
          ox = two.at.x - p.mid.x / scale
          oy = two.at.y - p.mid.y / scale
          settle()
        } else if (mode === 'scroll') {
          wheel(p.mid.y - two.mid.y)
          two.mid = p.mid
          vel.add(p.mid)
        }
      }
    },
    { passive: false }
  )

  const end = (e: TouchEvent): void => {
    e.preventDefault()
    unhold()
    if (e.touches.length > 0) {
      // one of two fingers lifted: a quick two-finger tap is a right click
      if (mode === 'two' && performance.now() - twoAt < 300) mouse('rclick', two.mid)
      if (mode === 'two' || mode === 'pinch' || mode === 'scroll') {
        if (mode === 'scroll') wheel(0, true)
        mode = 'done'
      }
      return
    }
    if (mode === 'two' && performance.now() - twoAt < 300) mouse('rclick', two.mid)
    if (mode === 'tap') {
      const now = performance.now()
      const near = now - lastTap.at < 400 && Math.hypot(start.x - lastTap.p.x, start.y - lastTap.p.y) < 40
      const p = near ? lastTap.p : start
      mouse('click', p)
      lastTap = { at: near ? 0 : now, p }
      marks.push({ ...p, at: now, kind: 'tap' })
      draw()
    } else if (mode === 'held') mouse('rclick', start)
    else if (mode === 'drag') {
      if (movePending) mouse('move', movePending)
      movePending = null
      mouse('up', last)
    } else if (mode === 'pan') {
      // glides on, slowing down
      let v = vel.get()
      if (Math.hypot(v.x, v.y) > 0.3)
        stopGlide = glide((dt) => {
          pan(v.x * dt, v.y * dt)
          v = { x: v.x * Math.pow(0.995, dt), y: v.y * Math.pow(0.995, dt) }
          return Math.hypot(v.x, v.y) > 0.02
        })
    } else if (mode === 'scroll') {
      let v = vel.get().y
      if (Math.abs(v) > 0.3)
        stopGlide = glide((dt) => {
          wheel(v * dt)
          v *= Math.pow(0.996, dt)
          if (Math.abs(v) > 0.03) return true
          wheel(0, true)
          return false
        })
      else wheel(0, true)
    }
    mode = 'idle'
  }
  c.addEventListener('touchend', end, { passive: false })
  c.addEventListener('touchcancel', end, { passive: false })
}

function mouse(a: string, p: Pt): void {
  const at = toScreen(p)
  send({ t: 'desk.mouse', a, x: at.x, y: at.y, mods: takeMods(a !== 'move' && a !== 'up') })
  // the pointer moves at once on the phone, before the next frame says so
  cursor = { x: Math.round(at.x), y: Math.round(at.y) }
  pointerAt = performance.now()
  draw()
}

/* ---------------- keyboard and buttons ---------------- */

/** The modifiers to send, cleared after a key or a click (`use`). */
function takeMods(use = true): string[] {
  const list = [...mods]
  if (use && list.length) {
    mods.clear()
    for (const list of Object.values(modButtons)) for (const b of list) b.classList.remove('on')
  }
  return list
}

function key(k: string, extra: string[] = []): void {
  send({ t: 'desk.key', k, mods: [...new Set([...takeMods(), ...extra])] })
}

function button(label: string, title: string, onclick: () => void, cls = 'desk-key'): HTMLElement {
  const x = el('button', cls, label)
  x.title = title
  x.onclick = onclick
  return x
}

/** A sticky modifier key (held for the next key or click); several buttons share one state. */
function modButton(m: string, label: string, cls = 'desk-key mod'): HTMLElement {
  const x = button(label, t(`${label}: held for the next key or click`, `${label}: giữ cho phím hoặc cú bấm kế tiếp`), () => {
    if (mods.has(m)) mods.delete(m)
    else mods.add(m)
    for (const b of modButtons[m]) b.classList.toggle('on', mods.has(m))
  }, cls)
  ;(modButtons[m] ??= []).push(x)
  return x
}

const MODS: [string, string][] = [
  ['ctrl', 'Ctrl'],
  ['alt', 'Alt'],
  ['shift', '⇧'],
  ['win', '⊞']
]

/** The floating dock: back, keyboard, the modifiers, the key sheet. Its grip moves it. */
function dock(back: () => void, sheet: HTMLElement, kb: HTMLElement): HTMLElement {
  const d = el('div', 'desk-dock')
  const grip = el('div', 'desk-grip', '⠿')
  grip.title = t('Move', 'Di chuyển')
  const toggle = (show: HTMLElement): void => {
    const open = show.classList.toggle('open')
    for (const other of [sheet, kb]) if (other !== show) other.classList.remove('open')
    if (show === kb && open) (kb.querySelector('input') as HTMLInputElement).focus()
  }
  d.append(
    grip,
    button('✕', t('Back to the chats', 'Về danh sách chat'), back, 'desk-key close'),
    button('⌨', t('Type text', 'Gõ chữ'), () => toggle(kb)),
    ...MODS.map(([m, label]) => modButton(m, label)),
    button('⌘', t('Keys and shortcuts', 'Phím và phím tắt'), () => toggle(sheet), 'desk-key accent')
  )
  for (const x of [sheet, kb]) x.querySelector('.desk-close')!.addEventListener('click', () => toggle(x))
  // the dock steps aside while the sheet or the text box is open
  for (const x of [sheet, kb]) new MutationObserver(() => d.classList.toggle('hidden', sheet.classList.contains('open') || kb.classList.contains('open'))).observe(x, { attributes: true })

  // dragged by the grip; the place is kept (as a fraction of the screen, for any orientation)
  const saved = JSON.parse(localStorage.getItem('vibe.desk.dock') || 'null') as Pt | null
  const place = (fx: number, fy: number): void => {
    const r = d.getBoundingClientRect()
    const pr = d.parentElement!.getBoundingClientRect()
    const x = Math.min(Math.max(0, fx * pr.width - r.width / 2), pr.width - r.width)
    const y = Math.min(Math.max(0, fy * pr.height - r.height / 2), pr.height - r.height)
    d.style.left = x + 'px'
    d.style.top = y + 'px'
    d.style.bottom = 'auto'
    d.style.transform = 'none'
  }
  if (saved) requestAnimationFrame(() => place(saved.x, saved.y))
  grip.addEventListener('pointerdown', (e) => {
    e.preventDefault()
    grip.setPointerCapture(e.pointerId)
    const move = (ev: PointerEvent): void => {
      const pr = d.parentElement!.getBoundingClientRect()
      const f = { x: (ev.clientX - pr.left) / pr.width, y: (ev.clientY - pr.top) / pr.height }
      place(f.x, f.y)
      localStorage.setItem('vibe.desk.dock', JSON.stringify(f))
    }
    const up = (): void => {
      grip.removeEventListener('pointermove', move)
      grip.removeEventListener('pointerup', up)
    }
    grip.addEventListener('pointermove', move)
    grip.addEventListener('pointerup', up)
  })
  return d
}

/** The text box: any language (the phone's keyboard composes it), sent with Enter. */
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
  const row = el('div', 'desk-kb')
  row.append(
    button('✕', t('Close', 'Đóng'), () => {}, 'desk-key close desk-close'),
    input,
    button('⌫', 'Backspace', () => key('Backspace')),
    button(t('Send', 'Gửi'), t('Send the text (Enter alone: the Enter key)', 'Gửi chữ (để trống: phím Enter)'), () => {
      go()
      input.focus()
    }, 'desk-key accent')
  )
  return row
}

/** The key sheet, by use: keys (modifiers, editing, arrows), shortcuts, F1–F12, display. */
function keySheet(): HTMLElement {
  const sheet = el('div', 'desk-sheet')
  const tabs = el('div', 'desk-tabs')
  const body = el('div', 'desk-sheet-body')
  const pages: Record<string, HTMLElement> = {}

  // keys: modifiers on top, editing keys on the left, the arrows as a pad on the right
  const keys = el('div', 'desk-page desk-keys')
  const modRow = el('div', 'desk-row')
  modRow.append(...MODS.map(([m, label]) => modButton(m, m === 'shift' ? 'Shift' : m === 'win' ? 'Win' : label)), button('Esc', 'Esc', () => key('Esc')), button('Tab', 'Tab', () => key('Tab')))
  const edit = el('div', 'desk-grid3')
  for (const [label, k] of [
    ['Home', 'Home'],
    ['PgUp', 'PageUp'],
    ['⌫', 'Backspace'],
    ['End', 'End'],
    ['PgDn', 'PageDown'],
    ['Del', 'Delete'],
    ['Ins', 'Insert'],
    [t('Space', 'Cách'), 'Space'],
    ['⏎', 'Enter']
  ])
    edit.append(button(label, k, () => key(k)))
  const pad = el('div', 'desk-pad')
  for (const [label, k, area] of [
    ['↑', 'Up', 'u'],
    ['←', 'Left', 'l'],
    ['↓', 'Down', 'd'],
    ['→', 'Right', 'r']
  ]) {
    const b = button(label, k, () => key(k))
    b.style.gridArea = area
    pad.append(b)
  }
  const lower = el('div', 'desk-split')
  lower.append(edit, pad)
  keys.append(modRow, lower)
  pages.keys = keys

  // shortcuts, grouped, each named by what it does
  const shortcuts = el('div', 'desk-page')
  const group = (title: string, items: [string, string, string, string[]][]): void => {
    shortcuts.append(el('div', 'desk-group', title))
    const g = el('div', 'desk-grid3')
    for (const [name, combo, k, m] of items) {
      const b = button('', combo, () => key(k, m), 'desk-key desk-combo')
      b.append(el('b', '', name), el('small', '', combo))
      g.append(b)
    }
    shortcuts.append(g)
  }
  group(t('Editing', 'Soạn thảo'), [
    [t('Copy', 'Sao chép'), 'Ctrl+C', 'C', ['ctrl']],
    [t('Paste', 'Dán'), 'Ctrl+V', 'V', ['ctrl']],
    [t('Cut', 'Cắt'), 'Ctrl+X', 'X', ['ctrl']],
    [t('Undo', 'Hoàn tác'), 'Ctrl+Z', 'Z', ['ctrl']],
    [t('Redo', 'Làm lại'), 'Ctrl+Y', 'Y', ['ctrl']],
    [t('Select all', 'Chọn hết'), 'Ctrl+A', 'A', ['ctrl']],
    [t('Save', 'Lưu'), 'Ctrl+S', 'S', ['ctrl']],
    [t('Find', 'Tìm'), 'Ctrl+F', 'F', ['ctrl']],
    [t('New tab', 'Tab mới'), 'Ctrl+T', 'T', ['ctrl']]
  ])
  group(t('Windows', 'Cửa sổ'), [
    [t('Switch app', 'Đổi cửa sổ'), 'Alt+Tab', 'Tab', ['alt']],
    [t('Close', 'Đóng'), 'Alt+F4', 'F4', ['alt']],
    [t('Desktop', 'Màn hình nền'), 'Win+D', 'D', ['win']],
    [t('Start menu', 'Menu Start'), 'Win', 'Win', []],
    [t('Files', 'Thư mục'), 'Win+E', 'E', ['win']],
    [t('Run', 'Chạy lệnh'), 'Win+R', 'R', ['win']],
    [t('Task Manager', 'Task Manager'), 'Ctrl+Shift+Esc', 'Esc', ['ctrl', 'shift']],
    [t('Snip', 'Chụp vùng'), 'Win+Shift+S', 'S', ['win', 'shift']],
    [t('Close tab', 'Đóng tab'), 'Ctrl+W', 'W', ['ctrl']]
  ])
  pages.shortcuts = shortcuts

  const fkeys = el('div', 'desk-page desk-grid4')
  for (let i = 1; i <= 12; i++) fkeys.append(button('F' + i, 'F' + i, () => key('F' + i)))
  pages.fkeys = fkeys

  // display
  const display = el('div', 'desk-page desk-grid2')
  const q = button(sharp ? t('Sharp (HD)', 'Nét (HD)') : t('Light (SD)', 'Nhẹ (SD)'), t('Sharp: more data · Light: faster on a slow network', 'Nét: tốn dữ liệu hơn · Nhẹ: nhanh hơn khi mạng yếu'), () => {
    sharp = !sharp
    localStorage.setItem('vibe.desk.sharp', sharp ? '1' : '0')
    q.textContent = sharp ? t('Sharp (HD)', 'Nét (HD)') : t('Light (SD)', 'Nhẹ (SD)')
    askView()
  })
  monBtn = button(t('Next monitor', 'Màn hình kế tiếp'), '', () => {
    if (screens.length < 2) return
    mon = (mon + 1) % screens.length
    localStorage.setItem('vibe.desk.mon', String(mon))
    fit()
  })
  monBtn.style.display = 'none'
  display.append(
    button(t('Whole screen', 'Cả màn hình'), '', fit),
    q,
    monBtn,
    button(t('Right click', 'Chuột phải'), t('At the pointer', 'Tại con trỏ'), () => send({ t: 'desk.mouse', a: 'rclick', x: cursor.x, y: cursor.y, mods: takeMods() })),
    button(t('Move the controls back', 'Đưa thanh điều khiển về chỗ cũ'), '', () => {
      localStorage.removeItem('vibe.desk.dock')
      const d = root?.querySelector('.desk-dock') as HTMLElement | null
      if (d) d.removeAttribute('style')
    })
  )
  pages.display = display

  const names: [string, string][] = [
    ['keys', t('Keys', 'Phím')],
    ['shortcuts', t('Shortcuts', 'Phím tắt')],
    ['fkeys', 'F1–F12'],
    ['display', t('Display', 'Hiển thị')]
  ]
  const show = (name: string): void => {
    localStorage.setItem('vibe.desk.tab', name)
    for (const [n] of names) pages[n].style.display = n === name ? '' : 'none'
    for (const b of tabs.querySelectorAll('button[data-tab]')) b.classList.toggle('on', (b as HTMLElement).dataset.tab === name)
  }
  for (const [n, label] of names) {
    const b = button(label, label, () => show(n), 'desk-tab')
    b.dataset.tab = n
    tabs.append(b)
  }
  tabs.append(button('✕', t('Close', 'Đóng'), () => {}, 'desk-tab desk-close'))
  body.append(...Object.values(pages))
  sheet.append(tabs, body)
  show(pages[localStorage.getItem('vibe.desk.tab') || ''] ? localStorage.getItem('vibe.desk.tab')! : 'keys')
  return sheet
}

function el(tag: string, cls: string, text?: string): HTMLElement {
  const x = document.createElement(tag)
  x.className = cls
  if (text !== undefined) x.textContent = text
  return x
}
