/**
 * The phone remote's brain (the native side, src-zig/src/remote.zig, only carries messages).
 *
 * A paired phone (remote.html in the Android app) sends `{t:…}` messages; this answers with:
 *   chats  {chats, projects}            the open chats, again whenever one changes
 *   screen {id, lines, menu}            the terminal of the chat the phone is looking at
 *   log    {id, log}                    that chat's conversation (the Chat view's transcript)
 *   created {id}                        the chat a `new` made
 * and acts on: hello, watch {id}, unwatch, send {id, text}, keys {id, data}, new {cwd, text}.
 */
import type { ChatLog } from '../../shared/types'
import { useStore, type Chat } from './store'
import { menuShown, screenLines } from './terminals'
import { newChat } from './actions'
import { sendMessage } from './promptQueue'

/** phones that said hello → the chat each one has open ('' = the list) */
const phones = new Map<number, string>()

const push = (msg: unknown, to?: number): void => window.api.remote.push(msg, to)

/* ---- the chat list ---- */

function chatRow(c: Chat): Record<string, unknown> {
  return { id: c.id, title: c.title, cwd: c.cwd, status: c.status, attention: c.attention, menu: menuShown(c.id), agent: c.agent ?? 'claude' }
}

function listMsg(): Record<string, unknown> {
  const s = useStore.getState()
  const projects = [...new Set([...(s.root ? [s.root] : []), ...s.chats.map((c) => c.cwd), ...s.recent])].slice(0, 12)
  return { t: 'chats', chats: s.chats.map(chatRow), projects, active: s.activeChatId }
}

let lastList = ''
let listTimer: ReturnType<typeof setTimeout> | undefined
/** Sends the list when it changed; a burst of changes goes out once. */
function listChanged(): void {
  if (!phones.size || listTimer) return
  listTimer = setTimeout(() => {
    listTimer = undefined
    const msg = listMsg()
    const json = JSON.stringify(msg)
    if (json === lastList) return
    lastList = json
    push(msg)
  }, 300)
}

/* ---- the terminal of a chat a phone has open ---- */

/** The numbered choice Claude waits on, as buttons: `❯ 1. Yes` / `  2. No`. */
function menuOf(lines: string[]): { n: string; label: string; sel: boolean }[] | null {
  const out = new Map<string, { n: string; label: string; sel: boolean }>()
  for (const raw of lines.slice(-20)) {
    const line = raw.replace(/^[\s│┃|]+|[\s│┃|]+$/g, '')
    const m = /^(❯)?\s*(\d+)\.\s+(.+)$/.exec(line)
    if (m) out.set(m[2], { n: m[2], label: m[3].trim().replace(/\s{2,}/g, ' — '), sel: !!m[1] })
  }
  return out.size ? [...out.values()] : null
}

const lastScreen = new Map<string, string>()
const screenTimers = new Map<string, ReturnType<typeof setTimeout>>()

function sendScreen(id: string, to?: number): void {
  const lines = screenLines(id)
  const menu = menuShown(id) ? menuOf(lines) : null
  const msg = { t: 'screen', id, lines, menu }
  const json = JSON.stringify(msg)
  if (to === undefined) {
    if (json === lastScreen.get(id)) return
    lastScreen.set(id, json)
  }
  for (const [phone, open] of phones) if (open === id && (to === undefined || to === phone)) push(msg, phone)
}

/** Output arrived: the phones watching it get the screen at most ~4 times a second. */
function screenChanged(id: string): void {
  if (screenTimers.has(id) || ![...phones.values()].includes(id)) return
  screenTimers.set(
    id,
    setTimeout(() => {
      screenTimers.delete(id)
      sendScreen(id)
      listChanged()
    }, 250)
  )
}

/* ---- the conversation ---- */

const cut = (s: string | undefined, n: number): string | undefined => (s && s.length > n ? s.slice(0, n) + '\n…' : s)

/** What a phone needs of the transcript: the last items, long outputs cut, no diffs or pictures. */
function slim(log: ChatLog): ChatLog {
  const items = log.items.slice(-80).map((it) => (it.kind === 'tool' ? { ...it, output: cut(it.output, 1500), detail: cut(it.detail, 1500) ?? '', diff: undefined, images: undefined } : it))
  return { ...log, items, skipped: log.skipped + Math.max(0, log.items.length - 80), todosAt: Math.max(0, log.todosAt - Math.max(0, log.items.length - 80)) }
}

async function sendLog(id: string, to?: number): Promise<void> {
  const sessionId = useStore.getState().chats.find((c) => c.id === id)?.sessionId
  const log = sessionId ? await window.api.sessions.log(sessionId).catch(() => null) : null
  const msg = { t: 'log', id, log: log ? slim(log) : null }
  for (const [phone, open] of phones) if (open === id && (to === undefined || to === phone)) push(msg, phone)
}

/* ---- messages from the phones ---- */

function onCmd(client: number, msg: Record<string, unknown>): void {
  const id = typeof msg.id === 'string' ? msg.id : ''
  const chat = id ? useStore.getState().chats.find((c) => c.id === id) : undefined
  switch (msg.t) {
    case 'hello':
      phones.set(client, '')
      push(listMsg(), client)
      return
    case 'bye':
      phones.delete(client)
      return
    case 'watch':
      if (!chat) return
      phones.set(client, id)
      sendScreen(id, client)
      void sendLog(id, client)
      return
    case 'unwatch':
      phones.set(client, '')
      return
    case 'send':
      if (chat && typeof msg.text === 'string' && msg.text.trim()) sendMessage(id, msg.text)
      return
    case 'keys':
      if (chat && typeof msg.data === 'string') window.api.pty.write(id, msg.data)
      return
    case 'new': {
      const cwd = typeof msg.cwd === 'string' ? msg.cwd : ''
      const text = typeof msg.text === 'string' ? msg.text.replace(/\s*\n\s*/g, ' ').trim() : ''
      if (!cwd) return
      newChat({ cwd, prompt: text || undefined })
      const made = useStore.getState().activeChatId
      if (made) push({ t: 'created', id: made }, client)
      return
    }
  }
}

window.api.remote.onCmd(onCmd)
window.api.pty.onData((id) => screenChanged(id))
useStore.subscribe((s, prev) => {
  if (s.chats !== prev.chats || s.recent !== prev.recent) listChanged()
})
/* the transcript grows a line at a time while Claude works: one reload per burst */
const logTimers = new Map<string, ReturnType<typeof setTimeout>>()
window.api.sessions.onChanged((ids) => {
  const chats = useStore.getState().chats
  for (const open of new Set(phones.values())) {
    const sid = open && chats.find((c) => c.id === open)?.sessionId
    if (!sid || !(ids.includes(sid) || ids.includes('*')) || logTimers.has(open)) continue
    logTimers.set(
      open,
      setTimeout(() => {
        logTimers.delete(open)
        void sendLog(open)
      }, 400)
    )
  }
})
