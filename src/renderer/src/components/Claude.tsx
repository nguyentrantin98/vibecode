import { useEffect, useRef, useState } from 'react'
import { Check, ChevronDown, FileText, Gauge, Image as ImageIcon, ListChecks, MessageSquare, Monitor, Copy, Download, GitCommitHorizontal, Shield, ShieldOff, History, Plus, RefreshCw, RotateCcw, Sparkles, Play, FastForward, Upload, Paperclip, Square, SquareTerminal, Trash2, X, ExternalLink, Ellipsis, FolderOpen, FlaskConical, ScanSearch, Shrink, KeyRound } from 'lucide-react'
import { useStore, type Chat } from '../store'
import { SlidePill, useEnterAnimation } from './motion'
import {
  closeChat,
  closeShell,
  defaultAgent,
  detectClaude,
  newChat,
  newChatWith,
  newShell,
  restartChat,
  selectChat,
  setChatEffort,
  setChatModel,
  setChatPermission,
  disabledTools,
  setDisabledTools,
  folderKey,
  loadProjectBypass,
  toggleProjectBypass,
  toggleDesktop,
  setClaudeApiKey
} from '../actions'
import { attachTerm, detachTerm, fitTerm, focusTerm, menuShown, writeToTerm } from '../terminals'
import { Logo, StatusDot, statusText } from './icons'
import { ChatImages, useChatImages } from './ChatImages'
import { ChatTasks, useChatTasks } from './ChatTasks'
import { ChatView } from './ChatView'
import { ChatFiles, useChatFiles } from './ChatFiles'
import { ChatTitle, chatMenu } from './Sidebar'
import { AttachmentTray } from './AttachmentTray'
import { pickAttachments } from '../attachments'
import { NewChatMenu } from './AgentMenu'
import { AGENTS, agentDef } from '../../../shared/agents'
import { useT } from '../i18n'
import type { T } from '../i18n'
import type { ClaudeApiKey } from '../../../shared/types'

export function TerminalView({ id, autoFocus = true }: { id: string; autoFocus?: boolean }): React.JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = ref.current!
    attachTerm(id, el, autoFocus)
    // A fit that changes the column count re-wraps the whole scrollback: while a panel is dragged,
    // at most ~12 a second (the last size always gets one), not one every frame.
    let raf = 0
    let last = 0
    let timer: ReturnType<typeof setTimeout> | undefined
    const run = (): void => {
      last = performance.now()
      fitTerm(id)
    }
    const ro = new ResizeObserver(() => {
      clearTimeout(timer)
      cancelAnimationFrame(raf)
      const wait = 80 - (performance.now() - last)
      if (wait <= 0) raf = requestAnimationFrame(run)
      else timer = setTimeout(() => (raf = requestAnimationFrame(run)), wait)
    })
    ro.observe(el)
    return () => {
      ro.disconnect()
      cancelAnimationFrame(raf)
      clearTimeout(timer)
      detachTerm(id)
    }
  }, [id, autoFocus])
  return <div className="term-view" ref={ref} onMouseDown={() => setTimeout(() => focusTerm(id), 0)} />
}

/* ================================ Claude panel ================================ */

/** One click: Claude commits everything and pushes, following our commit-message rules. */
const COMMIT_PUSH = (t: T): string =>
  t(
    'Commit all current changes and push to the remote. Commit message rules: English, one short subject line only ' +
      '(no body or description), and no Co-Authored-By or any other author/attribution trailer.',
    'Commit toàn bộ thay đổi hiện tại và push lên remote. Quy tắc commit message: tiếng Anh, chỉ một dòng tiêu đề ngắn ' +
      '(không có body hay mô tả), và không có Co-Authored-By hay bất kỳ dòng ghi tác giả/attribution nào khác.'
  )

const PULL = (t: T): string =>
  t(
    'Pull the latest code from the remote for the current branch (git pull). If there are local changes or conflicts, ' +
      'keep my work safe and tell me what happened.',
    'Pull code mới nhất từ remote cho branch hiện tại (git pull). Nếu có thay đổi local hoặc conflict, ' +
      'giữ an toàn cho phần việc của tôi và cho tôi biết chuyện gì đã xảy ra.'
  )

const RUN_APP = (t: T): string =>
  t(
    "Run this project's app the usual way for this project (backend and frontend if both are needed). Keep it running in the background, check that it responds, and give me the local URL.",
    'Chạy app của project này theo cách thường dùng của project (cả backend và frontend nếu cần). Để nó chạy nền, kiểm tra xem nó có phản hồi không, và cho tôi URL local.'
  )

const RUN_TESTS = (t: T): string =>
  t(
    "Run this project's tests (if it has none, its build or type check) and tell me what fails and why. Don't change any files.",
    'Chạy test của project này (nếu không có test thì chạy build hoặc type check) và cho tôi biết cái gì lỗi và vì sao. Không sửa file nào.'
  )

const REVIEW = (t: T): string =>
  t(
    "Review the uncommitted changes in this project for bugs, missed cases and leftovers. List what you find with file:line, most serious first. Don't change any files.",
    'Review các thay đổi chưa commit trong project này để tìm bug, trường hợp bị bỏ sót và phần còn sót lại. Liệt kê những gì tìm được kèm file:line, nghiêm trọng nhất trước. Không sửa file nào.'
  )

const PUBLISH = (t: T): string =>
  t(
    "Publish this project's backend: build it in Release and publish it the way this project is set up to (publish profile or script). Tell me where the output went and whether anything failed.",
    'Publish backend của project này: build ở chế độ Release và publish theo cách project đã thiết lập (publish profile hoặc script). Cho tôi biết output nằm ở đâu và có gì lỗi không.'
  )

export function ClaudePanel(): React.JSX.Element {
  const t = useT()
  // only the open chat: other chats' status / title changes don't re-render this panel
  const active = useStore((s) => s.chats.find((c) => c.id === s.activeChatId) ?? null)
  const activeId = active?.id ?? null
  const claude = useStore((s) => s.claude)
  // Codex / Gemini… alone is enough to chat; the install card is for when no agent is there at all
  const anyAgent = useStore((s) => !!s.claude?.found || s.agents.some((a) => a.found))
  const images = useChatImages(active?.sessionId)
  const tasks = useChatTasks(active?.sessionId)
  const runningTasks = tasks.filter((t) => t.status === 'running').length
  const files = useChatFiles(active?.sessionId)
  const changedFiles = files.filter((f) => f.action !== 'read').length
  const [tab, setTab] = useState<'chat' | 'terminal' | 'images' | 'files' | 'tasks'>('terminal')
  // Chat (drawn from Claude's transcript) or Terminal: the last one you picked; other agents only have the terminal
  const [lastView, setLastView] = useState<'chat' | 'terminal'>('terminal')
  const hasChatView = !!active && agentDef(active.agent).id === 'claude'
  const view = hasChatView ? lastView : 'terminal'
  // another chat opens on that view
  useEffect(() => {
    setTab(view)
    if (view === 'terminal' && activeId) setTimeout(() => focusTerm(activeId), 0)
  }, [activeId])
  // the terminal stays under the other tabs, so it must not keep the keyboard
  const leaveTerminal = (t: 'chat' | 'images' | 'files' | 'tasks'): void => {
    const el = document.activeElement
    if (el instanceof HTMLElement && termFrame.current?.contains(el)) el.blur()
    if (t === 'chat') setLastView('chat')
    setTab(t)
  }
  const showTerminal = (): void => {
    setLastView('terminal')
    setTab('terminal')
    setTimeout(() => active && focusTerm(active.id), 0)
  }
  // Claude waits on a numbered choice (permission prompt, plan approval…): only its terminal can answer, so show it
  useEffect(() => {
    if (!activeId) return
    let shown = menuShown(activeId)
    const i = setInterval(() => {
      const now = menuShown(activeId)
      if (now && !shown) {
        setTab('terminal')
        focusTerm(activeId)
      }
      shown = now
    }, 700)
    return () => clearInterval(i)
  }, [activeId])
  // a quick action: back to the conversation, keyboard in the terminal only when it shows
  const backToView = (): void => {
    setTab(view)
    if (view === 'terminal' && active) focusTerm(active.id)
  }
  // switching chats: the new conversation eases in
  const termFrame = useRef<HTMLDivElement>(null)
  useEnterAnimation(termFrame, activeId)

  // the bar over the quick actions: moving while the chat works, green once that run has finished
  const busy = active?.status === 'working' || active?.status === 'starting'
  const [done, setDone] = useState(false)
  const wasBusy = useRef(false)
  useEffect(() => {
    wasBusy.current = false
    setDone(false)
  }, [activeId])
  useEffect(() => {
    if (busy) setDone(false)
    else if (wasBusy.current && active?.status === 'idle') setDone(true)
    wasBusy.current = busy
  }, [busy, active?.status])

  // Chats are picked from the sidebar, so there is no tab strip here — just the open chat's title row.
  return (
    <div className="claude-panel">
      {claude && !anyAgent && <InstallCard />}
      {anyAgent && !active && <NoChat />}

      {active && (
        <>
          <div className="chat-titlebar">
            <div className="chat-titlebar-main" onContextMenu={(e) => chatMenu(e, { chatId: active.id }, 'title')}>
              <StatusDot status={active.status} attention={active.attention} />
              <ChatTitle place="title" chatId={active.id} title={active.title} className="chat-titlebar-title" />
              {active.cwd && (
                <span className="chat-project" title={`Project: ${active.cwd}`}>
                  <FolderOpen size={12} />
                  <span>{active.cwd.split(/[\\/]/).filter(Boolean).pop()}</span>
                </span>
              )}
              {agentDef(active.agent).id !== 'claude' && <span className="chat-agent">{agentDef(active.agent).label}</span>}
              <span className={`chat-state s-${active.status}`}>{statusText(active.status, t)}</span>
            </div>
            <div className="chat-titlebar-actions">
              {active.status === 'exited' && (
                <button className="btn btn-ghost btn-sm" onClick={() => restartChat(active.id)}>
                  <RefreshCw size={13} /> {t('Restart', 'Khởi động lại')}
                </button>
              )}
              {agentDef(active.agent).id === 'claude' && <BypassProjectButton chat={active} />}
              <NewChatMenu
                title={t('New chat with the default agent (Ctrl+Shift+N) — right-click to pick another AI', 'Chat mới với agent mặc định (Ctrl+Shift+N) — chuột phải để chọn AI khác')}
                onPick={newChatWith}
              />
              <button className="icon-btn" title={t('Close chat (it stays in the sidebar history)', 'Đóng chat (vẫn còn trong lịch sử ở thanh bên)')} onClick={() => closeChat(active.id)}>
                <X size={15} />
              </button>
            </div>
          </div>
          <div className="code-side-switch chat-tabs">
            <SlidePill />
            <button
              className={tab === 'terminal' || tab === 'chat' ? 'on' : ''}
              title={t("The conversation: Claude Code's own screen or a chat", 'Cuộc trò chuyện: màn hình gốc của Claude Code hoặc dạng chat')}
              onClick={() => (view === 'terminal' ? showTerminal() : leaveTerminal('chat'))}
            >
              <SquareTerminal size={13} /> Terminal
            </button>
            <button className={tab === 'images' ? 'on' : ''} onClick={() => leaveTerminal('images')}>
              <ImageIcon size={13} /> {t('Images', 'Ảnh')}
              {images.length > 0 && <span className="center-count">{images.length}</span>}
            </button>
            <button className={tab === 'files' ? 'on' : ''} title={t('Files Claude created, edited or read in this chat', 'Các tệp Claude đã tạo, sửa hoặc đọc trong chat này')} onClick={() => leaveTerminal('files')}>
              <FileText size={13} /> {t('Files', 'Tệp')}
              {changedFiles > 0 && <span className="center-count">{changedFiles}</span>}
            </button>
            <button className={tab === 'tasks' ? 'on' : ''} title={t('Background tasks Claude started in this chat', 'Các việc chạy nền Claude đã bắt đầu trong chat này')} onClick={() => leaveTerminal('tasks')}>
              <ListChecks size={13} /> {t('Tasks', 'Việc')}
              {runningTasks > 0 ? <span className="center-count running">{runningTasks}</span> : tasks.length > 0 && <span className="center-count">{tasks.length}</span>}
            </button>
          </div>
          {hasChatView && (tab === 'terminal' || tab === 'chat') && (
            <div className="code-side-switch term-views">
              <SlidePill />
              <button className={tab === 'terminal' ? 'on' : ''} title={t("Claude Code's own screen", 'Màn hình gốc của Claude Code')} onClick={showTerminal}>
                <SquareTerminal size={12} /> {t('Terminal view', 'Dạng terminal')}
              </button>
              <button className={tab === 'chat' ? 'on' : ''} title={t('The conversation, with tool calls folded up', 'Cuộc trò chuyện, với các lệnh gọi tool được thu gọn')} onClick={() => leaveTerminal('chat')}>
                <MessageSquare size={12} /> {t('Chat view', 'Dạng chat')}
              </button>
            </div>
          )}
          {/*
            The terminal stays mounted and laid out (only made invisible): display:none would reset
            xterm's scroll position to the top of the buffer and replay the enter animation on return.
            Chat / Images / Files / Tasks cover it instead.
          */}
          <div className="term-frame" ref={termFrame}>
            <div className="term-layer" style={tab === 'terminal' ? undefined : { visibility: 'hidden' }}>
              <TerminalView id={active.id} autoFocus={false} />
            </div>
            <StartSkeleton show={active.status === 'starting'} />
            {tab !== 'terminal' && (
              <div className="chat-overlay">
                {tab === 'chat' ? (
                  <ChatView chat={active} onTerminal={showTerminal} />
                ) : tab === 'images' ? (
                  <ChatImages images={images} />
                ) : tab === 'files' ? (
                  <ChatFiles files={files} cwd={active.cwd} />
                ) : (
                  <ChatTasks tasks={tasks} />
                )}
              </div>
            )}
          </div>
          {/* the Chat tab shows the tray itself, right above its message box */}
          {tab !== 'chat' && <AttachmentTray chatId={active.id} />}
          <div className={`quick-bar${busy ? ' busy' : done ? ' done' : ''}`}>
            {active.status === 'working' && (
              <button
                className="chip chip-stop"
                title={t('Stop what the AI is doing (Esc)', 'Dừng việc AI đang làm (Esc)')}
                onClick={() => {
                  writeToTerm(active.id, '\x1b')
                  backToView()
                }}
              >
                <Square size={10} fill="currentColor" />
                {t('Stop', 'Dừng')}
              </button>
            )}
            <button
              className="chip"
              title={t(
                'Attach files — they go with your next message (you can also paste pictures or drag files onto the chat)',
                'Đính kèm tệp — gửi kèm tin nhắn tiếp theo (cũng có thể dán ảnh hoặc kéo tệp vào chat)'
              )}
              disabled={active.status === 'exited'}
              onClick={async () => {
                await pickAttachments(active.id, active.cwd)
                backToView()
              }}
            >
              <Paperclip size={12} />
              <span className="chip-label">{t('Attach files', 'Đính kèm tệp')}</span>
            </button>
            <MoreMenu chat={active} onDone={backToView} />
            <ChatPickers chat={active} />
          </div>
          {agentDef(active.agent).id === 'claude' && <ContextBar chat={active} />}
        </>
      )}
    </div>
  )
}

/** Until the agent draws its first screen: a shimmering outline of its banner and prompt, faded out once it has. */
function StartSkeleton({ show }: { show: boolean }): React.JSX.Element | null {
  const [mounted, setMounted] = useState(show)
  useEffect(() => {
    if (show) return setMounted(true)
    const t = setTimeout(() => setMounted(false), 260)
    return () => clearTimeout(t)
  }, [show])
  if (!mounted) return null
  return (
    <div className={`chat-skel${show ? '' : ' out'}`} aria-hidden>
      <div className="chat-skel-head">
        <span className="sk sk-logo" />
        <div className="chat-skel-lines">
          <span className="sk" style={{ width: '38%' }} />
          <span className="sk" style={{ width: '62%' }} />
          <span className="sk" style={{ width: '28%' }} />
        </div>
      </div>
      <div className="chat-skel-prompt">
        <span className="sk sk-rule" />
        <span className="sk" style={{ width: '46%' }} />
        <span className="sk sk-rule" />
        <span className="sk" style={{ width: '34%' }} />
      </div>
    </div>
  )
}

/** One click: Claude never asks for permission anywhere in this chat's project. */
function BypassProjectButton({ chat }: { chat: Chat }): React.JSX.Element {
  const t = useT()
  const on = useStore((s) => !!s.projectBypass[folderKey(chat.cwd)])
  useEffect(() => {
    loadProjectBypass(chat.cwd)
  }, [chat.cwd])
  return (
    <button
      className={`btn btn-sm bypass-btn${on ? ' on' : ''}`}
      title={
        on
          ? t(`Bypass is on for ${chat.cwd} — click to turn off`, `Bypass đang bật cho ${chat.cwd} — bấm để tắt`)
          : t(`Bypass permissions for the whole project ${chat.cwd}`, `Không hỏi quyền trong toàn bộ project ${chat.cwd}`)
      }
      onClick={() => toggleProjectBypass(chat.id)}
    >
      {on ? <ShieldOff size={13} /> : <Shield size={13} />}
      <span className="bypass-label">{on ? t('Project bypassed', 'Đã bypass project') : t('Bypass project', 'Bypass project')}</span>
    </button>
  )
}

/** Tools Claude can't do much without: turning them off is allowed, but flagged. */
const CORE_TOOLS = new Set(['Bash', 'PowerShell', 'Read', 'Edit', 'Write', 'Glob', 'Grep', 'ToolSearch', 'Skill'])

/** Pick tools to take out of Claude chats: their definitions stop filling the context. Opened from More. */
function TokenMenu({ chat, at, onClose }: { chat: Chat; at: { left: number; bottom: number }; onClose: () => void }): React.JSX.Element {
  const tl = useT()
  const saved = disabledTools()
  const [tools, setTools] = useState<{ name: string; tokens: number }[]>([])
  const [off, setOff] = useState<Set<string>>(() => new Set(saved))
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (chat.sessionId)
      window.api.sessions
        .context(chat.sessionId)
        .then((c) => setTools(c?.tools ?? []))
        .catch(() => {})
  }, [chat.sessionId])
  useEffect(() => {
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) onClose()
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [onClose])

  // tools already off aren't in the chat's requests any more: listed after the rest, size unknown
  const rows = [...tools, ...saved.filter((n) => !tools.some((t) => t.name === n)).map((name) => ({ name, tokens: 0 }))]
  const saving = tools.filter((t) => off.has(t.name)).reduce((n, t) => n + t.tokens, 0)
  const changed = off.size !== saved.length || saved.some((n) => !off.has(n))
  const fmt = (n: number): string => (n < 1000 ? String(n) : `${(n / 1000).toFixed(1)}k`)
  const toggle = (name: string): void =>
    setOff((s) => {
      const next = new Set(s)
      if (!next.delete(name)) next.add(name)
      return next
    })

  return (
    <div className="tok-menu" ref={ref} style={{ left: at.left, bottom: at.bottom }} role="menu">
      <div className="sb-menu-title">{tl('Tick the tools to turn off (all Claude chats)', 'Đánh dấu các tool muốn tắt (mọi chat Claude)')}</div>
      <div className="tok-list">
        {rows.length === 0 && (
          <div className="tok-empty">{chat.sessionId ? tl('Loading…', 'Đang tải…') : tl('Send a message first to see the tools.', 'Gửi một tin nhắn trước để xem các tool.')}</div>
        )}
        {rows.map((t) => (
          <label key={t.name} className={`tok-row${off.has(t.name) ? ' on' : ''}`}>
            <input type="checkbox" checked={off.has(t.name)} onChange={() => toggle(t.name)} />
            <span className="tok-name">{t.name}</span>
            {CORE_TOOLS.has(t.name) && (
              <span className="tok-core" title={tl('Claude relies on this tool for everyday work', 'Claude cần tool này cho công việc hằng ngày')}>
                {tl('core', 'lõi')}
              </span>
            )}
            <span className="tok-size">{t.tokens ? fmt(t.tokens) : tl('off', 'tắt')}</span>
          </label>
        ))}
      </div>
      <div className="tok-foot">
        <span>{saving > 0 ? tl(`Saves ~${fmt(saving)} tokens`, `Tiết kiệm ~${fmt(saving)} token`) : ''}</span>
        <button
          className="btn btn-primary btn-sm"
          disabled={!changed}
          onClick={() => {
            onClose()
            setDisabledTools(chat.id, [...off])
          }}
        >
          {tl('Apply & restart chat', 'Áp dụng & khởi động lại chat')}
        </button>
      </div>
    </div>
  )
}

/** The Anthropic API key all Claude chats can run on when the plan's usage limit is reached. */
function ApiKeyMenu({ at, state, onChange, onClose }: { at: { left: number; bottom: number }; state: ClaudeApiKey | null; onChange: (s: ClaudeApiKey) => void; onClose: () => void }): React.JSX.Element {
  const tl = useT()
  const [key, setKey] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) onClose()
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [onClose])

  const apply = async (o: { key?: string; on?: boolean }): Promise<void> => {
    setBusy(true)
    setError('')
    try {
      onChange(await setClaudeApiKey(o))
      setKey('')
    } catch (e) {
      setError(String((e as Error)?.message ?? e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="tok-menu" ref={ref} style={{ left: at.left, bottom: at.bottom }} role="dialog">
      <div className="sb-menu-title">{tl('Anthropic API key (all Claude chats)', 'API key Anthropic (mọi chat Claude)')}</div>
      <div className="key-note">
        {tl(
          "For when your plan's usage limit is reached: Claude chats run on the key instead, billed per token to its Console account. Open chats restart (same conversations).",
          'Dùng khi gói của bạn hết lượt: các chat Claude chạy bằng key này, tính phí theo token vào tài khoản Console của key. Các chat đang mở sẽ khởi động lại (giữ nguyên hội thoại).'
        )}
      </div>
      {state?.hint && (
        <label className="tok-row">
          <input type="checkbox" checked={state.on} disabled={busy} onChange={() => void apply({ on: !state.on })} />
          <span className="tok-name">
            {tl('Use the key', 'Dùng key')} <code>{state.hint}</code>
          </span>
          <button className="btn btn-ghost btn-sm" disabled={busy} onClick={(e) => (e.preventDefault(), void apply({ key: '' }))}>
            {tl('Remove', 'Xoá')}
          </button>
        </label>
      )}
      <form
        className="key-form"
        onSubmit={(e) => {
          e.preventDefault()
          if (key.trim()) void apply({ key })
        }}
      >
        <input
          className="key-input"
          type="password"
          autoFocus
          placeholder={state?.hint ? tl('New key: sk-ant-…', 'Key mới: sk-ant-…') : 'sk-ant-…'}
          value={key}
          onChange={(e) => setKey(e.target.value)}
        />
        <button className="btn btn-primary btn-sm" type="submit" disabled={busy || !key.trim()}>
          {tl('Save & use', 'Lưu & dùng')}
        </button>
      </form>
      {error && <div className="key-error">{error}</div>}
    </div>
  )
}

interface MoreItem {
  key: string
  icon: React.JSX.Element
  label: string
  hint: string
  run: () => void
  /** a switch: drawn on or off */
  on?: boolean
  badge?: string
}

/** Claude's last answer (every text of its last turn), from the transcript. */
async function lastReply(sessionId: string | undefined): Promise<string> {
  const log = sessionId ? await window.api.sessions.log(sessionId).catch(() => null) : null
  const items = log?.items ?? []
  const texts: string[] = []
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i]
    if (it.kind === 'user' && !it.mid) break
    if (it.kind === 'text') texts.unshift(it.text)
  }
  return texts.join('\n\n')
}

/** "…": the one-click prompts and chat switches, each with what it does, out of the conversation's way. */
function MoreMenu({ chat, onDone }: { chat: Chat; onDone: () => void }): React.JSX.Element {
  const t = useT()
  const [open, setOpen] = useState(false)
  const [tokensAt, setTokensAt] = useState<{ left: number; bottom: number } | null>(null)
  const [keyAt, setKeyAt] = useState<{ left: number; bottom: number } | null>(null)
  const [apiKey, setApiKey] = useState<ClaudeApiKey | null>(null)
  const [copied, setCopied] = useState('')
  const ref = useRef<HTMLDivElement>(null)
  const btn = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    if (open)
      window.api.claude
        .apiKey()
        .then(setApiKey)
        .catch(() => {})
  }, [open])
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [open])

  const exited = chat.status === 'exited'
  const isClaude = agentDef(chat.agent).id === 'claude'
  const off = disabledTools().length
  const ask =
    (prompt: string, confirm = ''): (() => void) =>
    async () => {
      setOpen(false)
      if (confirm && !(await window.api.ask(confirm))) return
      sendPrompt(chat.id, prompt)
      onDone()
    }
  const sections: { title: string; items: (MoreItem | false)[] }[] = [
    {
      title: t('Ask the AI', 'Hỏi AI'),
      items: [
        { key: 'continue', icon: <FastForward size={14} />, label: t('Continue', 'Tiếp tục'), hint: t('Pick up where it stopped', 'Làm tiếp từ chỗ đã dừng'), run: ask(t('continue', 'tiếp tục')) },
        { key: 'run', icon: <Play size={14} />, label: t('Run app', 'Chạy app'), hint: t('Start the project and give the local URL', 'Khởi động project và cho URL local'), run: ask(RUN_APP(t)) },
        {
          key: 'test',
          icon: <FlaskConical size={14} />,
          label: t('Run tests', 'Chạy test'),
          hint: t('Tests (or build) and what fails, no edits', 'Test (hoặc build) và chỗ lỗi, không sửa gì'),
          run: ask(RUN_TESTS(t))
        },
        {
          key: 'review',
          icon: <ScanSearch size={14} />,
          label: t('Review changes', 'Review thay đổi'),
          hint: t('Look over uncommitted code for bugs, no edits', 'Soát code chưa commit để tìm bug, không sửa gì'),
          run: ask(REVIEW(t))
        },
        {
          key: 'publish',
          icon: <Upload size={14} />,
          label: t('Publish backend', 'Publish backend'),
          hint: t('Release build, published the way the project is set up', 'Build Release, publish theo cách project đã thiết lập'),
          run: ask(PUBLISH(t), t('Ask the AI to publish the backend of this project now?', 'Nhờ AI publish backend của project này ngay bây giờ?'))
        }
      ]
    },
    {
      title: 'Git',
      items: [
        {
          key: 'commit',
          icon: <GitCommitHorizontal size={14} />,
          label: 'Commit + push',
          hint: t('One English subject line, no co-author', 'Một dòng tiêu đề tiếng Anh, không co-author'),
          run: ask(COMMIT_PUSH(t))
        },
        { key: 'pull', icon: <Download size={14} />, label: 'Pull', hint: t('Get the latest code, keep local work safe', 'Lấy code mới nhất, giữ an toàn thay đổi local'), run: ask(PULL(t)) }
      ]
    },
    {
      title: t('This chat', 'Chat này'),
      items: [
        isClaude && {
          key: 'copy',
          icon: <Copy size={14} />,
          label: t('Copy last reply', 'Sao chép câu trả lời cuối'),
          hint: copied || t("Claude's last answer, as markdown", 'Câu trả lời cuối của Claude, dạng markdown'),
          run: async () => {
            const text = await lastReply(chat.sessionId)
            if (text) await navigator.clipboard.writeText(text)
            setCopied(text ? t('Copied', 'Đã sao chép') : t('No reply yet', 'Chưa có câu trả lời'))
            setTimeout(() => {
              setCopied('')
              setOpen(false)
            }, 700)
          }
        },
        isClaude && {
          key: 'compact',
          icon: <Shrink size={14} />,
          label: t('Compact context', 'Thu gọn ngữ cảnh'),
          hint: t('Summarise the chat to free up context (/compact)', 'Tóm tắt chat để giải phóng ngữ cảnh (/compact)'),
          run: ask('/compact')
        },
        isClaude && {
          key: 'tokens',
          icon: <Gauge size={14} />,
          label: t('Optimize tokens', 'Tối ưu token'),
          hint: t("Turn off tools you don't use", 'Tắt các tool bạn không dùng'),
          badge: off ? t(`${off} off`, `${off} tắt`) : undefined,
          run: () => {
            const r = btn.current!.getBoundingClientRect()
            setOpen(false)
            setTokensAt({ left: Math.max(8, Math.min(r.left, window.innerWidth - 328)), bottom: window.innerHeight - r.top + 6 })
          }
        },
        isClaude && {
          key: 'apikey',
          icon: <KeyRound size={14} />,
          label: t('API key', 'API key'),
          hint: apiKey?.on
            ? t(`On for all Claude chats · ${apiKey.hint}`, `Đang bật cho mọi chat Claude · ${apiKey.hint}`)
            : t("Run on your own key when the plan's limit is reached", 'Chạy bằng key riêng khi gói hết lượt'),
          on: !!apiKey?.on,
          run: () => {
            const r = btn.current!.getBoundingClientRect()
            setOpen(false)
            setKeyAt({ left: Math.max(8, Math.min(r.left, window.innerWidth - 328)), bottom: window.innerHeight - r.top + 6 })
          }
        },
        isClaude &&
          window.api.platform === 'win32' && {
            key: 'desktop',
            icon: <Monitor size={14} />,
            label: t('Desktop control', 'Điều khiển desktop'),
            hint: t('See and use your other apps (restarts the chat)', 'Xem và dùng các app khác của bạn (khởi động lại chat)'),
            on: !!chat.desktop,
            run: () => {
              setOpen(false)
              void toggleDesktop(chat.id)
            }
          }
      ]
    }
  ]

  return (
    <div className="more-wrap" ref={ref}>
      <button ref={btn} className={`chip more-btn${open ? ' open' : ''}`} title={t('More: quick prompts, Git, tokens, desktop control', 'Thêm: prompt nhanh, Git, token, điều khiển desktop')}onClick={() => setOpen(!open)}>
        <Ellipsis size={14} />
        {(chat.desktop || off > 0) && <i className="more-dot" />}
      </button>
      {open && (
        <div className="sb-menu more-menu" role="menu">
          {sections.map((s) => (
            <div key={s.title} className="more-section">
              <div className="sb-menu-title">{s.title}</div>
              {s.items.map(
                (it) =>
                  it && (
                    <button key={it.key} role="menuitem" className="sb-item more-item" disabled={exited && it.key !== 'copy'} onClick={it.run}>
                      <span className="more-icon">{it.icon}</span>
                      <span className="more-text">
                        <span>{it.label}</span>
                        <span className="sb-item-hint">{it.hint}</span>
                      </span>
                      {it.badge && <span className="tok-count">{it.badge}</span>}
                      {it.on !== undefined && <span className={`more-switch${it.on ? ' on' : ''}`} />}
                    </button>
                  )
              )}
            </div>
          ))}
        </div>
      )}
      {tokensAt && <TokenMenu chat={chat} at={tokensAt} onClose={() => setTokensAt(null)} />}
      {keyAt && <ApiKeyMenu at={keyAt} state={apiKey} onChange={setApiKey} onClose={() => setKeyAt(null)} />}
    </div>
  )
}

/* ---------------- Model / effort / permission pickers ---------------- */

interface Opt {
  value: string
  label: string
  hint?: string
}

const MODELS = (t: T): Opt[] => [
  { value: '', label: t('Default', 'Mặc định'), hint: t("Claude Code's choice", 'Claude Code tự chọn') },
  { value: 'claude-opus-5-5', label: 'Opus 5.5', hint: t('Most capable', 'Mạnh nhất') },
  { value: 'claude-sonnet-5-5', label: 'Sonnet 5.5', hint: t('Fast, strong', 'Nhanh, mạnh') },
  { value: 'claude-haiku-5-5', label: 'Haiku 5.5', hint: t('Fastest', 'Nhanh nhất') },
  { value: 'claude-fable-5-2', label: 'Fable 5.2' }
]

const EFFORTS = (t: T): Opt[] => [
  { value: '', label: t('Auto', 'Tự động') },
  { value: 'low', label: t('Low', 'Thấp') },
  { value: 'medium', label: t('Medium', 'Vừa') },
  { value: 'high', label: t('High', 'Cao') },
  { value: 'xhigh', label: t('Extra high', 'Rất cao') },
  { value: 'max', label: t('Max', 'Tối đa') }
]

const MODES = (t: T): Opt[] => [
  { value: '', label: t('Ask permissions', 'Hỏi quyền'), hint: t('Default', 'Mặc định') },
  { value: 'acceptEdits', label: t('Accept edits', 'Chấp nhận sửa'), hint: t('Auto-approve file edits', 'Tự duyệt sửa tệp') },
  { value: 'plan', label: t('Plan mode', 'Chế độ Plan'), hint: t('Read-only planning', 'Lập kế hoạch, chỉ đọc') },
  { value: 'bypassPermissions', label: t('Bypass permissions', 'Bỏ qua quyền'), hint: t('No prompts at all', 'Không hỏi gì cả') }
]

/** Typed into the chat's prompt, then Enter on its own so it isn't read as part of a pasted block. */
function sendPrompt(id: string, text: string): void {
  writeToTerm(id, text)
  setTimeout(() => writeToTerm(id, '\r'), 150)
}

/** Model / effort / permission mode, at the right of the bar under the chat. */
function ChatPickers({ chat }: { chat: Chat }): React.JSX.Element {
  const t = useT()
  const agent = agentDef(chat.agent)
  const isClaude = agent.id === 'claude'
  // other agents: only "ask" vs their own never-ask flag (Codex --dangerously-bypass…, Gemini --yolo…)
  const modes = isClaude ? MODES(t) : agent.yolo.length ? MODES(t).filter((m) => !m.value || m.value === 'bypassPermissions') : []
  return (
    <div className="sb-pickers">
      {isClaude && <Picker title="Model" options={MODELS(t)} value={chat.model ?? ''} onPick={(v) => setChatModel(chat.id, v)} />}
      {isClaude && <Picker title={t('Effort', 'Mức suy nghĩ')} options={EFFORTS(t)} value={chat.effort ?? ''} onPick={(v) => setChatEffort(chat.id, v)} />}
      {modes.length > 0 && (
        <Picker
          title={t('Permission mode (restarts the chat)', 'Chế độ quyền (khởi động lại chat)')}
          options={modes}
          value={chat.permissionMode ?? ''}
          warn={chat.permissionMode === 'bypassPermissions'}
          onPick={(v) => setChatPermission(chat.id, v)}
        />
      )}
    </div>
  )
}

/**
 * Models with a 200k context window: Haiku 4.5 and everything before the 4.6 generation
 * (claude-haiku-4-5-20251001, claude-opus-4-20250514, claude-3-…). Every newer model — Fable,
 * Opus 4.6+, Sonnet 4.6+, Haiku 5.5 and ones not released yet — has 1M.
 */
const SMALL_WINDOW = /-(opus|sonnet|haiku)-4(-[0-5])?(-\d{8})?$|claude-[23]/i

/** What the context is made of (keys as sessions.rs sends them), in the bar's order. */
const CTX_PARTS = (t: T): { key: string; label: string; hint: string }[] => [
  { key: 'system', label: 'System prompt', hint: t("Claude Code's instructions, environment, date", 'Hướng dẫn, môi trường, ngày giờ của Claude Code') },
  { key: 'tools', label: t('Built-in tools', 'Tool có sẵn'), hint: t('Bash, Read, Edit… and the deferred-tool list', 'Bash, Read, Edit… và danh sách tool tải sau') },
  { key: 'mcp', label: t('MCP servers', 'MCP server'), hint: t('Tools and instructions of MCP servers', 'Tool và hướng dẫn của các MCP server') },
  { key: 'plugins', label: 'Plugins', hint: t("Plugins' skills, agents and MCP tools", 'Skill, agent và tool MCP của plugin') },
  { key: 'skills', label: 'Skills', hint: t('Skill list, plus skills Claude loaded', 'Danh sách skill, cùng các skill Claude đã nạp') },
  { key: 'agents', label: 'Agents', hint: t('Subagent types for the Agent tool', 'Các loại subagent cho tool Agent') },
  { key: 'memory', label: t('Memory files', 'Tệp memory'), hint: 'CLAUDE.md, MEMORY.md' },
  { key: 'messages', label: t('Messages', 'Tin nhắn'), hint: t('Your messages, replies, tool calls and results', 'Tin nhắn của bạn, câu trả lời, lệnh gọi tool và kết quả') }
]

/** How full this chat's context window is, from the last reply in its session file. */
function ContextBar({ chat }: { chat: Chat }): React.JSX.Element {
  const t = useT()
  const sessionId = chat.sessionId
  const [ctx, setCtx] = useState<{ used: number; model: string; parts: { key: string; tokens: number }[] } | null>(null)
  const [hover, setHover] = useState(false)
  useEffect(() => {
    setCtx(null)
    if (!sessionId) return
    let alive = true
    let timer: ReturnType<typeof setTimeout> | undefined
    const load = (): void => {
      window.api.sessions
        .context(sessionId)
        .then((c) => alive && setCtx((prev) => (prev && c && prev.used === c.used && prev.model === c.model ? prev : c)))
        .catch(() => {})
    }
    load()
    const off = window.api.sessions.onChanged((ids) => {
      if (!ids.includes(sessionId) && !ids.includes('*')) return
      clearTimeout(timer)
      timer = setTimeout(load, 400)
    })
    return () => {
      alive = false
      clearTimeout(timer)
      off()
    }
  }, [sessionId])

  const used = ctx?.used ?? 0
  // the model that wrote the last reply decides (it follows a /model typed in the chat); the
  // `[1m]` suffix only exists on the launch flag. A 200k model already past 200k is on 1M too.
  const small = SMALL_WINDOW.test(ctx?.model || chat.model || '') && !/\[1m\]/i.test(chat.model ?? '')
  const max = small && used <= 200_000 ? 200_000 : 1_000_000
  const pct = Math.min(100, (used / max) * 100)
  const level = pct >= 85 ? 'high' : pct >= 60 ? 'mid' : 'low'
  const k = (n: number): string => (n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : `${Math.round(n / 1000)}k`)
  const kk = (n: number): string => (n < 1000 ? String(n) : n < 10_000 ? `${(n / 1000).toFixed(1)}k` : k(n))
  const pc = (n: number): string => {
    const p = (n / max) * 100
    return p > 0 && p < 0.1 ? '<0.1%' : `${p.toFixed(p < 10 ? 1 : 0)}%`
  }
  const tokens = new Map(ctx?.parts?.map((p) => [p.key, p.tokens]))
  const parts = CTX_PARTS(t).map((p) => ({ ...p, tokens: tokens.get(p.key) ?? 0 }))
  return (
    <div
      className="ctx-bar"
      title={ctx ? undefined : t('No reply yet', 'Chưa có câu trả lời')}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <span className="ctx-label">{t('Context', 'Ngữ cảnh')}</span>
      <div className="ctx-track">
        {parts.map(
          (p) => p.tokens > 0 && <div key={p.key} className={`ctx-seg ctx-${p.key}`} style={{ width: `${(p.tokens / max) * 100}%` }} />
        )}
      </div>
      <span className={`ctx-num ${level}`}>{ctx ? `${k(used)} / ${k(max)} · ${Math.round(pct)}%` : '—'}</span>
      {hover && ctx && (
        <div className="ctx-pop">
          <div className="ctx-pop-head">
            <span>{t('Context window', 'Cửa sổ ngữ cảnh')}</span>
            <span>
              {used.toLocaleString(t('en-US', 'vi-VN'))} / {max.toLocaleString(t('en-US', 'vi-VN'))} · {Math.round(pct)}%
            </span>
          </div>
          {parts.map((p) => (
            <div key={p.key} className={`ctx-row${p.tokens ? '' : ' none'}`} title={p.hint}>
              <i className={`ctx-dot ctx-${p.key}`} />
              <span className="ctx-row-label">{p.label}</span>
              <span className="ctx-row-num">{kk(p.tokens)}</span>
              <span className="ctx-row-pct">{pc(p.tokens)}</span>
            </div>
          ))}
          <div className="ctx-row free">
            <i className="ctx-dot" />
            <span className="ctx-row-label">{t('Free space', 'Còn trống')}</span>
            <span className="ctx-row-num">{kk(Math.max(0, max - used))}</span>
            <span className="ctx-row-pct">{pc(Math.max(0, max - used))}</span>
          </div>
          <div className="ctx-pop-note">{t('Estimated from the session file · total is exact', 'Ước tính từ file session · tổng là chính xác')}</div>
        </div>
      )}
    </div>
  )
}

function Picker(props: { title: string; options: Opt[]; value: string; warn?: boolean; onPick: (v: string) => void }): React.JSX.Element {
  const { title, options, value, warn, onPick } = props
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [open])
  const cur = options.find((o) => o.value === value) ?? options[0]
  return (
    <div className="sb-picker" ref={ref}>
      <button className={`sb-btn${open ? ' open' : ''}${warn ? ' warn' : ''}`} title={`${cur.label} — ${title}`} onClick={() => setOpen(!open)}>
        {cur.label}
      </button>
      {open && (
        <div className="sb-menu" role="menu">
          <div className="sb-menu-title">{title}</div>
          {options.map((o) => (
            <button
              key={o.value}
              role="menuitemradio"
              aria-checked={o.value === value}
              className={`sb-item${o.value === value ? ' on' : ''}`}
              onClick={() => {
                setOpen(false)
                if (o.value !== value) onPick(o.value)
              }}
            >
              <Check size={13} className="sb-check" />
              <span className="sb-item-label">{o.label}</span>
              {o.hint && <span className="sb-item-hint">{o.hint}</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function NoChat(): React.JSX.Element {
  const t = useT()
  const agents = useStore((s) => s.agents)
  const claudeFound = useStore((s) => !!s.claude?.found)
  useStore((s) => s.preferredAgent)
  const def = agentDef(defaultAgent())
  const others = AGENTS.filter((a) => a.id !== def.id && (a.id === 'claude' ? claudeFound : agents.some((x) => x.id === a.id && x.found)))
  return (
    <div className="no-chat">
      <div className="glow-orb">
        <Logo size={56} />
      </div>
      <h3>{t('What should we build?', 'Hôm nay mình build gì?')}</h3>
      <p>
        {t(
          `Each chat runs its own ${def.label} session in this folder. Run several in parallel and hop between them.`,
          `Mỗi chat chạy một phiên ${def.label} riêng trong thư mục này. Chạy nhiều chat song song và chuyển qua lại giữa chúng.`
        )}
      </p>
      <div className="no-chat-actions">
        <button className="btn btn-primary btn-lg" onClick={() => newChat()}>
          <Sparkles size={16} /> {t('New chat', 'Chat mới')}
          {def.id !== 'claude' ? ` · ${def.label}` : ''}
        </button>
        {claudeFound && (
          <>
            <button className="btn btn-ghost" onClick={() => newChat({ args: ['--continue'], title: t('Continued chat', 'Chat tiếp tục') })}>
              <RotateCcw size={14} /> {t('Continue last', 'Tiếp tục chat trước')}
            </button>
            <button className="btn btn-ghost" onClick={() => newChat({ args: ['--resume'], title: t('Resume…', 'Mở lại…') })}>
              <History size={14} /> {t('Resume…', 'Mở lại…')}
            </button>
          </>
        )}
      </div>
      {others.length > 0 && (
        <div className="no-chat-actions no-chat-agents">
          {others.map((a) => (
            <button key={a.id} className="btn btn-ghost btn-sm" onClick={() => newChatWith(a.id)}>
              <Plus size={13} /> {a.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function InstallCard(): React.JSX.Element {
  const t = useT()
  const cmd = 'npm install -g @anthropic-ai/claude-code'
  return (
    <div className="no-chat">
      <div className="glow-orb dim">
        <Logo size={56} />
      </div>
      <h3>{t("Claude Code isn't installed", 'Chưa cài Claude Code')}</h3>
      <p>
        {t('VIBE CODE runs the', 'VIBE CODE chạy công cụ dòng lệnh')} <code>claude</code>
        {t(' command-line tool. Install it, then sign in once from a terminal.', '. Hãy cài nó, rồi đăng nhập một lần từ terminal.')}
      </p>
      <div className="code-line">
        <code>{cmd}</code>
        <button className="icon-btn" title={t('Copy', 'Sao chép')} onClick={() => navigator.clipboard.writeText(cmd)}>
          <Copy size={14} />
        </button>
      </div>
      <div className="no-chat-actions">
        <button
          className="btn btn-primary"
          onClick={() => {
            newShell()
            setTimeout(() => {
              const id = useStore.getState().activeShellId
              if (id) writeToTerm(id, cmd + '\r')
            }, 900)
          }}
        >
          <SquareTerminal size={15} /> {t('Install in terminal', 'Cài trong terminal')}
        </button>
        <button className="btn btn-ghost" onClick={() => detectClaude()}>
          <RefreshCw size={14} /> {t("I've installed it", 'Tôi đã cài xong')}
        </button>
        <button className="btn btn-ghost" onClick={() => window.api.app.openExternal('https://docs.claude.com/en/docs/claude-code/setup')}>
          <ExternalLink size={14} /> {t('Docs', 'Tài liệu')}
        </button>
      </div>
    </div>
  )
}

/* ================================ Bottom terminal panel ================================ */

export function BottomPanel(): React.JSX.Element {
  const t = useT()
  const shells = useStore((s) => s.shells)
  const activeId = useStore((s) => s.activeShellId)
  return (
    <div className="bottom-panel">
      <div className="bottom-header">
        <div className="bottom-tabs">
          <span className="bottom-label">Terminal</span>
          <SlidePill />
          {shells.map((sh) => (
            <button
              key={sh.id}
              className={`bottom-tab${sh.id === activeId ? ' active' : ''}${sh.exited ? ' exited' : ''}`}
              onClick={() => useStore.setState({ activeShellId: sh.id })}
            >
              <SquareTerminal size={13} />
              <span>{sh.title}</span>
              <X
                size={12}
                className="bottom-tab-x"
                onClick={(e) => {
                  e.stopPropagation()
                  closeShell(sh.id)
                }}
              />
            </button>
          ))}
        </div>
        <div className="section-actions">
          <button className="icon-btn" title={t('New terminal', 'Terminal mới')} onClick={() => newShell()}>
            <Plus size={15} />
          </button>
          {activeId && (
            <button className="icon-btn" title={t('Kill terminal', 'Tắt terminal')} onClick={() => closeShell(activeId)}>
              <Trash2 size={14} />
            </button>
          )}
          <button className="icon-btn" title={t('Hide panel (Ctrl+`)', 'Ẩn bảng (Ctrl+`)')} onClick={() => useStore.setState({ bottomOpen: false })}>
            <ChevronDown size={15} />
          </button>
        </div>
      </div>
      <div className="term-frame bottom">{activeId && <TerminalView id={activeId} />}</div>
    </div>
  )
}
