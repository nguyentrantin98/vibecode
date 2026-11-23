/**
 * VIBE CODE Remote: the page the Android app (or any phone browser) shows, served by the desktop
 * app's phone remote (src-zig/src/remote.zig) and talking to its window (src/renderer/src/remote.ts)
 * over one WebSocket. No framework: a few views built with plain DOM, updated in place.
 */
import type { ChatItem, ChatLog } from '../../../shared/types'
import './phone.css'

type Status = 'starting' | 'working' | 'idle' | 'exited'
interface ChatRow {
  id: string
  title: string
  cwd: string
  status: Status
  attention: boolean
  menu: boolean
  agent: string
}
interface MenuOption {
  n: string
  label: string
  sel: boolean
}

const vi = navigator.language.toLowerCase().startsWith('vi')
const t = (en: string, viText: string): string => (vi ? viText : en)

const TOKEN_KEY = 'vibe.remote.token'
const KEYS: [string, string][] = [
  ['Esc', '\x1b'],
  ['↑', '\x1b[A'],
  ['↓', '\x1b[B'],
  ['←', '\x1b[D'],
  ['→', '\x1b[C'],
  ['Tab', '\t'],
  ['⇧Tab', '\x1b[Z'],
  ['Enter', '\r'],
  ['Ctrl+C', '\x03']
]

/* ---------------- state ---------------- */

let ws: WebSocket | null = null
let online = false
let retry = 1000
let chats: ChatRow[] = []
let projects: string[] = []
let openId = ''
let mode: 'chat' | 'term' = (localStorage.getItem('vibe.remote.mode') as 'chat' | 'term') || 'chat'
let log: ChatLog | null | undefined
let screen: { lines: string[]; menu: MenuOption[] | null } = { lines: [], menu: null }
let wrap = localStorage.getItem('vibe.remote.wrap') !== '0'
/** tool rows the user expanded, kept open across transcript updates */
const expanded = new Set<string>()

/* ---------------- tiny DOM helper ---------------- */

type Child = Node | string | null | undefined | false
function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, unknown> = {}, ...kids: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag)
  for (const [k, v] of Object.entries(props)) {
    if (v === undefined || v === null || v === false) continue
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v as EventListener)
    else if (k === 'class') el.className = String(v)
    else el.setAttribute(k, v === true ? '' : String(v))
  }
  for (const kid of kids) if (kid) el.append(kid)
  return el
}

const app = document.getElementById('app')!
const base = (p: string): string => p.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || p

function toast(text: string): void {
  const el = h('div', { class: 'toast' }, text)
  document.body.append(el)
  setTimeout(() => el.remove(), 1800)
}

/* ---------------- connection ---------------- */

function send(msg: Record<string, unknown>): boolean {
  if (!ws || ws.readyState !== WebSocket.OPEN || !online) {
    toast(t('Not connected', 'Chưa kết nối'))
    return false
  }
  ws.send(JSON.stringify(msg))
  return true
}

function connect(): void {
  const token = localStorage.getItem(TOKEN_KEY)
  if (!token) return route()
  if (ws && ws.readyState <= WebSocket.OPEN) return
  const sock = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`)
  ws = sock
  sock.onopen = () => sock.send(JSON.stringify({ t: 'auth', token }))
  sock.onmessage = (e) => onMessage(JSON.parse(String(e.data)))
  sock.onclose = () => {
    if (ws !== sock) return
    ws = null
    online = false
    setOnline()
    if (!localStorage.getItem(TOKEN_KEY)) return route()
    setTimeout(connect, retry)
    retry = Math.min(retry * 2, 10000)
  }
}

function onMessage(m: Record<string, unknown>): void {
  switch (m.t) {
    case 'auth':
      if (!m.ok) {
        // removed on the computer, or paired again: back to the PIN
        localStorage.removeItem(TOKEN_KEY)
        ws?.close()
        return route()
      }
      online = true
      retry = 1000
      setOnline()
      ws?.send(JSON.stringify({ t: 'hello' }))
      if (openId) ws?.send(JSON.stringify({ t: 'watch', id: openId }))
      return
    case 'chats':
      chats = m.chats as ChatRow[]
      projects = m.projects as string[]
      renderList()
      renderHeader()
      return
    case 'screen':
      if (m.id !== openId) return
      screen = { lines: m.lines as string[], menu: m.menu as MenuOption[] | null }
      // the choice buttons appearing shrink the view: what Claude asks stays in sight above them
      stickToBottom(refs.body, () => {
        renderMenu()
        renderScreen()
      })
      return
    case 'log':
      if (m.id !== openId) return
      log = m.log as ChatLog | null
      renderLog()
      return
    case 'created':
      location.hash = '#/c/' + encodeURIComponent(String(m.id))
      return
  }
}

function setOnline(): void {
  document.body.classList.toggle('offline', !online)
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && !ws) {
    retry = 1000
    connect()
  }
})

/* ---------------- views ---------------- */

let refs: Record<string, HTMLElement> = {}

function route(): void {
  const hash = decodeURIComponent(location.hash.slice(1))
  const was = openId
  openId = hash.startsWith('/c/') ? hash.slice(3) : ''
  if (was && was !== openId && online) ws?.send(JSON.stringify({ t: 'unwatch' }))
  if (openId && openId !== was) {
    log = undefined
    screen = { lines: [], menu: null }
    expanded.clear()
    if (online) ws?.send(JSON.stringify({ t: 'watch', id: openId }))
  }
  refs = {}
  app.replaceChildren()
  if (!localStorage.getItem(TOKEN_KEY)) return pairView()
  if (openId) return chatView()
  if (hash === '/new') return newView()
  listView()
}
window.addEventListener('hashchange', route)

const offlineBar = (): HTMLElement => h('div', { class: 'offline-bar' }, t('Connecting to the computer…', 'Đang kết nối tới máy tính…'))

/* ---- pairing ---- */

function pairView(): void {
  const input = h('input', { class: 'pin-input', inputmode: 'numeric', maxlength: '6', autocomplete: 'one-time-code', placeholder: '••••••' })
  const err = h('div', { class: 'pair-err' })
  const btn = h('button', { class: 'btn primary', onclick: () => void pair() }, t('Pair', 'Ghép nối'))
  async function pair(): Promise<void> {
    const pin = input.value.trim()
    if (pin.length !== 6) return void (err.textContent = t('The PIN has 6 digits', 'PIN gồm 6 chữ số'))
    btn.setAttribute('disabled', '')
    err.textContent = ''
    const bridge = (window as unknown as { VibeAndroid?: { deviceName(): string } }).VibeAndroid
    const name = bridge?.deviceName() ?? (/Android[^;)]*;\s*([^;)]+)/.exec(navigator.userAgent)?.[1] || 'Phone')
    try {
      const res = await fetch('/pair', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ pin, name }) })
      const body = (await res.json()) as { token?: string; error?: string }
      if (!res.ok || !body.token) throw new Error(body.error || res.statusText)
      localStorage.setItem(TOKEN_KEY, body.token)
      connect()
      route()
    } catch (e) {
      err.textContent = (e as Error).message
      btn.removeAttribute('disabled')
    }
  }
  input.addEventListener('keydown', (e) => e.key === 'Enter' && void pair())
  app.append(
    h(
      'div',
      { class: 'pair' },
      h('div', { class: 'logo' }, 'VIBE CODE'),
      h('h1', {}, t('Pair with this computer', 'Ghép nối với máy tính này')),
      h(
        'p',
        { class: 'muted' },
        t('On the computer: click the phone icon in the status bar → Pair a phone, then type the PIN here.', 'Trên máy tính: bấm biểu tượng điện thoại ở thanh trạng thái → Ghép nối điện thoại, rồi nhập PIN vào đây.')
      ),
      input,
      btn,
      err
    )
  )
  input.focus()
}

/* ---- chat list ---- */

function statusOf(c: ChatRow): { cls: string; text: string } {
  if (c.menu) return { cls: 'ask', text: t('Needs your answer', 'Cần bạn trả lời') }
  if (c.status === 'working') return { cls: 'busy', text: t('Working…', 'Đang làm…') }
  if (c.status === 'starting') return { cls: 'busy', text: t('Starting…', 'Đang khởi động…') }
  if (c.status === 'exited') return { cls: 'dead', text: t('Exited', 'Đã thoát') }
  if (c.attention) return { cls: 'done', text: t('Finished', 'Đã xong') }
  return { cls: 'idle', text: t('Idle', 'Đang chờ') }
}

function listView(): void {
  refs.list = h('div', { class: 'list' })
  app.append(
    h(
      'div',
      { class: 'view' },
      h('header', { class: 'bar' }, h('div', { class: 'bar-title' }, 'VIBE CODE'), h('button', { class: 'btn small primary', onclick: () => (location.hash = '#/new') }, '+ ' + t('New chat', 'Chat mới'))),
      offlineBar(),
      refs.list
    )
  )
  renderList()
}

function renderList(): void {
  const list = refs.list
  if (!list) return
  if (!chats.length) {
    list.replaceChildren(h('div', { class: 'empty' }, online ? t('No chats open on the computer.', 'Máy tính chưa mở chat nào.') : ''))
    return
  }
  // grouped by project, in the order the computer lists them
  const groups = new Map<string, ChatRow[]>()
  for (const c of chats) groups.set(c.cwd, [...(groups.get(c.cwd) ?? []), c])
  const out: Node[] = []
  for (const [cwd, rows] of groups) {
    out.push(h('div', { class: 'group' }, base(cwd)))
    for (const c of rows) {
      const s = statusOf(c)
      out.push(
        h(
          'a',
          { class: 'row', href: '#/c/' + encodeURIComponent(c.id) },
          h('span', { class: 'dot ' + s.cls }),
          h('span', { class: 'row-main' }, h('span', { class: 'row-title' }, c.title), h('span', { class: 'row-sub ' + s.cls }, s.text))
        )
      )
    }
  }
  list.replaceChildren(...out)
}

/* ---- new chat ---- */

function newView(): void {
  let pick = projects[0] ?? ''
  const opts = h('div', { class: 'projects' })
  const draw = (): void => {
    opts.replaceChildren(
      ...projects.map((p) =>
        h(
          'button',
          {
            class: 'project' + (p === pick ? ' on' : ''),
            onclick: () => {
              pick = p
              draw()
            }
          },
          h('span', { class: 'row-title' }, base(p)),
          h('span', { class: 'row-sub' }, p)
        )
      )
    )
  }
  draw()
  const text = h('textarea', { class: 'input', rows: '4', placeholder: t('First message (optional)', 'Tin nhắn đầu tiên (không bắt buộc)') })
  app.append(
    h(
      'div',
      { class: 'view' },
      h('header', { class: 'bar' }, h('button', { class: 'back', onclick: () => history.back() }, '‹'), h('div', { class: 'bar-title' }, t('New chat', 'Chat mới'))),
      offlineBar(),
      h(
        'div',
        { class: 'scroll pad' },
        h('div', { class: 'label' }, t('Project', 'Dự án')),
        projects.length ? opts : h('div', { class: 'muted' }, t('Open a folder on the computer first.', 'Hãy mở một thư mục trên máy tính trước.')),
        h('div', { class: 'label' }, t('Message', 'Tin nhắn')),
        text,
        h('button', { class: 'btn primary wide', onclick: () => pick && send({ t: 'new', cwd: pick, text: text.value }) }, t('Start chat', 'Bắt đầu chat'))
      )
    )
  )
}

/* ---- one chat ---- */

function chatView(): void {
  refs.title = h('div', { class: 'bar-title' })
  refs.sub = h('div', { class: 'bar-sub' })
  const tab = (m: 'chat' | 'term', label: string): HTMLElement =>
    h(
      'button',
      {
        class: 'seg' + (mode === m ? ' on' : ''),
        onclick: () => {
          mode = m
          localStorage.setItem('vibe.remote.mode', m)
          route()
        }
      },
      label
    )
  refs.body = h('div', { class: 'scroll ' + (mode === 'term' ? 'term' : 'log') })
  refs.menu = h('div', { class: 'menu' })
  const input = h('textarea', { class: 'input', rows: '1', placeholder: t('Message Claude…', 'Nhắn cho Claude…') }) as HTMLTextAreaElement
  const grow = (): void => {
    input.style.height = 'auto'
    input.style.height = Math.min(input.scrollHeight, 160) + 'px'
  }
  input.addEventListener('input', grow)
  const submit = (): void => {
    const text = input.value.trim()
    if (!text || !send({ t: 'send', id: openId, text })) return
    input.value = ''
    grow()
  }
  const keys = h('div', { class: 'keys' }, ...KEYS.map(([label, data]) => h('button', { class: 'key', onclick: () => send({ t: 'keys', id: openId, data }) }, label)))
  app.append(
    h(
      'div',
      { class: 'view' },
      h(
        'header',
        { class: 'bar' },
        h('button', { class: 'back', onclick: () => history.back() }, '‹'),
        h('div', { class: 'bar-text' }, refs.title, refs.sub),
        h('div', { class: 'segs' }, tab('chat', 'Chat'), tab('term', t('Terminal', 'Terminal')))
      ),
      offlineBar(),
      refs.body,
      refs.menu,
      keys,
      h('div', { class: 'composer' }, input, h('button', { class: 'send', onclick: submit, 'aria-label': t('Send', 'Gửi') }, '↑'))
    )
  )
  renderHeader()
  renderMenu()
  if (mode === 'term') renderScreen()
  else renderLog()
}

function renderHeader(): void {
  if (!refs.title || !openId) return
  const c = chats.find((x) => x.id === openId)
  refs.title.textContent = c?.title ?? ''
  const s = c ? statusOf(c) : { cls: 'dead', text: t('Closed on the computer', 'Đã đóng trên máy tính') }
  refs.sub.textContent = s.text
  refs.sub.className = 'bar-sub ' + s.cls
}

function renderMenu(): void {
  const menu = refs.menu
  if (!menu) return
  menu.replaceChildren(
    ...(screen.menu ?? []).map((o) => h('button', { class: 'choice' + (o.sel ? ' sel' : ''), onclick: () => send({ t: 'keys', id: openId, data: o.n }) }, `${o.n}. ${o.label}`))
  )
}

/** Keeps the view pinned to the bottom when it was there before an update. */
function stickToBottom(el: HTMLElement | undefined, update: () => void): void {
  const atBottom = !!el && el.scrollHeight - el.scrollTop - el.clientHeight < 60
  update()
  if (el && atBottom) el.scrollTop = el.scrollHeight
}

function renderScreen(): void {
  const body = refs.body
  if (!body || mode !== 'term') return
  stickToBottom(body, () => {
    const pre = h('pre', { class: 'screen' + (wrap ? ' wrap' : '') }, screen.lines.join('\n').replace(/\n{3,}/g, '\n\n'))
    const toggle = h(
      'button',
      {
        class: 'btn small ghost wrap-btn',
        onclick: () => {
          wrap = !wrap
          localStorage.setItem('vibe.remote.wrap', wrap ? '1' : '0')
          renderScreen()
        }
      },
      wrap ? t('No wrap', 'Không xuống dòng') : t('Wrap', 'Xuống dòng')
    )
    body.replaceChildren(toggle, pre)
  })
}

/* ---- the conversation ---- */

function dur(ms: number): string {
  const s = Math.round(ms / 1000)
  return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
}

/** Markdown, the little of it that matters on a phone: code blocks, `code`, **bold**, headings. */
function markdown(text: string): HTMLElement {
  const box = h('div', { class: 'md' })
  const parts = text.split(/```[^\n]*\n?/)
  parts.forEach((part, i) => {
    if (i % 2) return void box.append(h('pre', { class: 'code' }, part.replace(/\n$/, '')))
    const p = h('div', { class: 'para' })
    for (const seg of part.split(/(`[^`\n]+`|\*\*[^*\n]+\*\*)/)) {
      if (!seg) continue
      if (seg.startsWith('`') && seg.endsWith('`') && seg.length > 1) p.append(h('code', {}, seg.slice(1, -1)))
      else if (seg.startsWith('**') && seg.endsWith('**') && seg.length > 3) p.append(h('b', {}, seg.slice(2, -2)))
      else p.append(seg.replace(/^#{1,6} /gm, ''))
    }
    if (p.textContent?.trim()) box.append(p)
  })
  return box
}

function toolRow(it: Extract<ChatItem, { kind: 'tool' }>): HTMLElement {
  const name = it.name.startsWith('mcp__') ? it.name.split('__').slice(1).join(' · ') : it.name
  const body = h('div', { class: 'tool-body' })
  if (it.detail && it.detail !== it.label) body.append(h('pre', { class: 'code' }, it.detail))
  if (it.output) body.append(h('pre', { class: 'code out' + (it.error ? ' err' : '') }, it.output))
  const d = h(
    'details',
    { class: 'tool' + (it.error ? ' err' : ''), open: expanded.has(it.id) },
    h(
      'summary',
      {},
      h('span', { class: 'tool-name' }, name),
      h('span', { class: 'tool-label' }, it.label),
      it.added || it.removed ? h('span', { class: 'tool-diff' }, h('i', { class: 'add' }, `+${it.added}`), ' ', h('i', { class: 'del' }, `-${it.removed}`)) : null,
      it.output === undefined ? h('span', { class: 'spin' }) : null
    ),
    body
  )
  d.addEventListener('toggle', () => (d.open ? expanded.add(it.id) : expanded.delete(it.id)))
  return d
}

function todoList(l: ChatLog): HTMLElement | null {
  if (!l.todos.length) return null
  return h(
    'div',
    { class: 'todos' },
    ...l.todos.map((td) => h('div', { class: 'todo ' + td.status }, td.status === 'completed' ? '✓ ' : td.status === 'in_progress' ? '▸ ' : '○ ', td.text))
  )
}

function renderLog(): void {
  const body = refs.body
  if (!body || mode !== 'chat') return
  if (log === undefined) return body.replaceChildren(h('div', { class: 'empty' }, t('Loading…', 'Đang tải…')))
  if (log === null || !log.items.length)
    return body.replaceChildren(h('div', { class: 'empty' }, t('Nothing yet. Send a message below, or open Terminal.', 'Chưa có gì. Gửi tin nhắn bên dưới, hoặc mở Terminal.')))
  const l = log
  stickToBottom(body, () => {
    const out: (Node | null)[] = []
    if (l.skipped) out.push(h('div', { class: 'skipped' }, t(`${l.skipped} earlier items not shown`, `${l.skipped} mục cũ hơn không hiển thị`)))
    l.items.forEach((it, i) => {
      if (i === l.todosAt) out.push(todoList(l))
      if (it.kind === 'user') out.push(h('div', { class: 'msg user' }, it.text))
      else if (it.kind === 'text') out.push(h('div', { class: 'msg ai' }, markdown(it.text)))
      else if (it.kind === 'tool') out.push(toolRow(it))
      else out.push(h('div', { class: 'turn-end' }, it.ms ? t(`Worked for ${dur(it.ms)}`, `Đã làm ${dur(it.ms)}`) : t('Interrupted', 'Đã dừng')))
    })
    if (l.todosAt >= l.items.length) out.push(todoList(l))
    body.replaceChildren(...out.filter((n): n is Node => n !== null))
  })
}

/* ---------------- start ---------------- */

setOnline()
route()
connect()
