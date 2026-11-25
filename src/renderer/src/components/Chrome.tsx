import { invoke } from '../native'
import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react'
import { SlidePill } from './motion'
import {
  ChevronDown,
  CircleCheck,
  CircleAlert,
  Files,
  FolderOpen,
  GitBranch,
  GitCompare,
  Loader2,
  MessagesSquare,
  PanelLeft,
  PanelBottom,
  Search,
  Clock,
  ArrowDownToLine,
  ChevronUp,
  Minus,
  Square,
  Copy,
  X,
  Link2,
  Check,
  Droplet,
  Globe,
  Moon,
  Sun,
  SquareDashedPlus
} from 'lucide-react'
import { basename, useStore, type SidebarView } from '../store'
import { defaultAgent, installedAgents, openBrowser, openFile, openFolder, openSession, setDefaultAgent, toggleBottom, toggleTheme } from '../actions'
import { AGENTS, agentDef } from '../../../shared/agents'
import { languageOf } from '../fileModelsLite'
import { FileIcon, Logo } from './icons'
import type { UsageLimit } from '../../../shared/types'
import { revealIn } from '../scroll'
import { TempMeter } from './Thermal'
import { SoundMeter } from './Sound'
import { giveFiles } from '../terminals'
import { COMMANDS, type Command } from '../shortcuts'
import { RemoteButton } from './RemotePanel'
import { setLang, useT, type T } from '../i18n'

/* ================================ Title bar ================================ */

/** Empty parts of the title bar move the window (the drop-down stays pinned to the top edge). */
const NO_DRAG = 'button, input, a, kbd, .menu, .search-box, .folder-switch, .win-controls'
// A double-click is handled here (e.detail === 2), not in onDoubleClick: once the first click
// has started a native drag, Windows maximizes on the second click by itself, and a separate
// dblclick handler then toggled it straight back — the window flickered and the
// maximize/restore button showed the wrong state.
function dragWindow(e: React.MouseEvent): void {
  if (e.button !== 0 || (e.target as HTMLElement).closest(NO_DRAG)) return
  if (useStore.getState().win?.mode === 'dropdown') return
  if (e.detail === 2) window.api.win.toggleMaximize()
  else void invoke('win_start_drag')
}

export function TitleBar(): React.JSX.Element {
  const root = useStore((s) => s.root)
  const recent = useStore((s) => s.recent)
  const [menu, setMenu] = useState(false)
  const t = useT()

  useEffect(() => {
    if (!menu) return
    const close = (): void => setMenu(false)
    window.addEventListener('mousedown', close)
    return () => window.removeEventListener('mousedown', close)
  }, [menu])

  return (
    <div className={window.api.platform === 'darwin' ? 'titlebar mac' : 'titlebar'} onMouseDown={dragWindow}>
      <div className="titlebar-left">
        <Logo size={18} />
        <span className="app-name">VIBE <b>CODE</b></span>
        {root && (
          <div className="folder-switch" onMouseDown={(e) => e.stopPropagation()}>
            <button className="folder-btn" onClick={() => setMenu(!menu)}>
              <FolderOpen size={13} />
              {basename(root)}
              <ChevronDown size={12} />
            </button>
            {menu && (
              <div className="menu">
                <button
                  className="menu-item"
                  onClick={() => {
                    setMenu(false)
                    openFolder()
                  }}
                >
                  <FolderOpen size={14} /> {t('Open folder…', 'Mở thư mục…')}
                </button>
                {recent.length > 1 && <div className="menu-sep">{t('Recent', 'Gần đây')}</div>}
                {recent
                  .filter((r) => r !== root)
                  .map((r) => (
                    <button
                      key={r}
                      className="menu-item"
                      onClick={() => {
                        setMenu(false)
                        openFolder(r)
                      }}
                    >
                      <Clock size={14} />
                      <span className="menu-item-main">{basename(r)}</span>
                      <span className="menu-item-sub">{r}</span>
                    </button>
                  ))}
              </div>
            )}
          </div>
        )}
      </div>
      {root && (
        <button className="search-box" onClick={() => useStore.setState({ quickOpen: true })}>
          <Search size={13} />
          <span>{t(`Search files in ${basename(root)}`, `Tìm tệp trong ${basename(root)}`)}</span>
          <kbd>Ctrl+P</kbd>
        </button>
      )}
      <div className="titlebar-right">
        <button className="icon-btn" title={t('Toggle sidebar (Ctrl+B)', 'Bật/tắt thanh bên (Ctrl+B)')} onClick={() => useStore.setState((s) => ({ sidebarOpen: !s.sidebarOpen }))}>
          <PanelLeft size={15} />
        </button>
        <button className="icon-btn" title={t('Toggle terminal (Ctrl+`)', 'Bật/tắt terminal (Ctrl+`)')} onClick={() => toggleBottom()}>
          <PanelBottom size={15} />
        </button>
        <button className="icon-btn" title={t('Open browser', 'Mở trình duyệt')} onClick={() => openBrowser()}>
          <Globe size={15} />
        </button>
        <CaptureButton />
        <ThemeToggle />
        <LangToggle />
        <OpacityControl />
        <ModeSwitch />
      </div>
      <WindowControls />
    </div>
  )
}

/** Screen capture: pick a region, mark it up, and it lands in the active chat (and the clipboard). */
function CaptureButton(): React.JSX.Element | null {
  const t = useT()
  useEffect(
    () =>
      window.api.app.onCaptured((path) => {
        const id = useStore.getState().activeChatId
        if (id) giveFiles(id, [path])
      }),
    []
  )
  if (window.api.platform !== 'win32') return null
  return (
    <button className="icon-btn" title={t('Capture what is behind VIBE CODE: pick a region, mark it up, send it to chat (Ctrl+Alt+Z captures the screen as it is, VIBE CODE included)', 'Chụp màn hình phía sau VIBE CODE: chọn vùng, đánh dấu, gửi vào chat (Ctrl+Alt+Z chụp nguyên màn hình, có cả VIBE CODE)')} onClick={() => void window.api.app.capture(true)}>
      <SquareDashedPlus size={15} />
    </button>
  )
}

/** Light ↔ dark. */
function ThemeToggle(): React.JSX.Element {
  const light = useStore((s) => s.themeResolved === 'light')
  const t = useT()
  return (
    <button className="icon-btn" title={light ? t('Switch to dark theme', 'Chuyển sang giao diện tối') : t('Switch to light theme', 'Chuyển sang giao diện sáng')} onClick={() => toggleTheme()}>
      {light ? <Moon size={15} /> : <Sun size={15} />}
    </button>
  )
}

/** English ↔ Tiếng Việt: shows the language in use, a click switches to the other one. */
function LangToggle(): React.JSX.Element {
  const lang = useStore((s) => s.lang)
  const t = useT()
  return (
    <button className="icon-btn lang-btn" title={t('Language: English — click for Tiếng Việt', 'Ngôn ngữ: Tiếng Việt — bấm để chuyển sang English')} onClick={() => void setLang(lang === 'vi' ? 'en' : 'vi')}>
      {lang === 'vi' ? 'VI' : 'EN'}
    </button>
  )
}

/** Window opacity: a button that opens a slider (20–100%). */
function OpacityControl(): React.JSX.Element {
  const saved = useStore((s) => s.settings?.dropOpacity ?? 1)
  const seeThrough = useStore((s) => !!s.settings?.seeThrough)
  const [pending, setPending] = useState(false)
  const [open, setOpen] = useState(false)
  const [val, setVal] = useState(saved)
  const ref = useRef<HTMLDivElement>(null)
  const t = useT()
  // while the slider is open it shows what you drag, not a (possibly older) saved answer
  useEffect(() => {
    if (!open) setVal(saved)
  }, [saved, open])
  const saveSeq = useRef(0)
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    window.addEventListener('mousedown', close)
    return () => window.removeEventListener('mousedown', close)
  }, [open])
  const save = async (v: number): Promise<void> => {
    setVal(v)
    const my = ++saveSeq.current
    const settings = await window.api.app.setSettings({ dropOpacity: v }).catch(() => null)
    // answers to earlier drags come back late: only the last one counts
    if (settings && my === saveSeq.current) useStore.setState({ settings })
  }
  return (
    <div className="opacity-ctl" ref={ref}>
      <button className={`icon-btn${open ? ' active' : ''}`} title={t(`Window opacity: ${Math.round(val * 100)}%`, `Độ mờ cửa sổ: ${Math.round(val * 100)}%`)} onClick={() => setOpen(!open)}>
        <Droplet size={15} />
      </button>
      {open && (
        <div className="menu opacity-pop">
          <button
            className={`see-through${seeThrough ? ' on' : ''}`}
            onClick={async () => {
              const next = !seeThrough
              const msg = next
                ? t(
                    'See-through: the background turns transparent and text stays sharp, like a Linux overlay terminal.\n\nVIBE CODE has to restart. Open chats close; reopen them from Chats.',
                    'Xuyên thấu: nền trở nên trong suốt, chữ vẫn sắc nét, như terminal overlay trên Linux.\n\nVIBE CODE cần khởi động lại. Các chat đang mở sẽ đóng; mở lại chúng từ danh sách Chat.'
                  )
                : t(
                    'Turn off see-through? VIBE CODE has to restart. Open chats close; reopen them from Chats.',
                    'Tắt xuyên thấu? VIBE CODE cần khởi động lại. Các chat đang mở sẽ đóng; mở lại chúng từ danh sách Chat.'
                  )
              if (!(await window.api.ask(msg))) return
              const settings = await window.api.app.setSettings({ seeThrough: next }).catch(() => null)
              if (settings) useStore.setState({ settings })
              if (!(await window.api.app.relaunch())) setPending(true)
            }}
          >
            <span className="see-through-box">{seeThrough && <Check size={11} />}</span>
            {t('See-through (Linux overlay)', 'Xuyên thấu (overlay Linux)')}
          </button>
          {pending && <div className="opacity-note">{t('Dev mode: stop and rerun npm run dev to apply.', 'Chế độ dev: dừng rồi chạy lại npm run dev để áp dụng.')}</div>}
          <div className="opacity-row">
            <span>{seeThrough ? t('Background', 'Nền') : t('Opacity', 'Độ mờ')}</span>
            <b>{Math.round(val * 100)}%</b>
          </div>
          <input type="range" min={seeThrough ? 5 : 20} max={100} step={1} value={Math.round(val * 100)} onChange={(e) => save(Number(e.target.value) / 100)} />
          <div className="opacity-presets">
            {[0.3, 0.5, 0.75, 1].map((p) => (
              <button key={p} className={`chip${Math.abs(val - p) < 0.005 ? ' on' : ''}`} onClick={() => save(p)}>
                {Math.round(p * 100)}%
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

function ModeSwitch(): React.JSX.Element | null {
  const win = useStore((s) => s.win)
  const t = useT()
  if (!win) return null
  const drop = win.mode === 'dropdown'
  return (
    <button
      className={`mode-switch${drop ? ' on' : ''}`}
      title={drop ? t('Switch to a normal window', 'Chuyển sang cửa sổ thường') : t(`Drop-down mode: ${win.hotkey} slides VIBE CODE over any app`, `Chế độ thả xuống: ${win.hotkey} trượt VIBE CODE xuống trên mọi ứng dụng`)}
      onClick={() => window.api.win.setMode(drop ? 'window' : 'dropdown')}
    >
      <ArrowDownToLine size={13} />
      <span>{drop ? t('Drop-down', 'Thả xuống') : 'Guake'}</span>
      {win.hotkeyOk && <kbd>{win.hotkey}</kbd>}
    </button>
  )
}

function WindowControls(): React.JSX.Element | null {
  const win = useStore((s) => s.win)
  const t = useT()
  if (!win) return null
  // macOS draws its own traffic lights (top-left) — ours would be a second set
  if (window.api.platform === 'darwin' && win.mode !== 'dropdown') return null
  if (win.mode === 'dropdown') {
    return (
      <div className="win-controls">
        <button className="win-btn" title={t(`Hide (${win.hotkey})`, `Ẩn (${win.hotkey})`)} onClick={() => window.api.win.hide()}>
          <ChevronUp size={16} />
        </button>
      </div>
    )
  }
  return (
    <div className="win-controls">
      <button className="win-btn" title={t('Minimize', 'Thu nhỏ')} onClick={() => window.api.win.minimize()}>
        <Minus size={15} />
      </button>
      <button className="win-btn" title={win.maximized ? t('Restore', 'Khôi phục') : t('Maximize', 'Phóng to')} onClick={() => window.api.win.toggleMaximize()}>
        {win.maximized ? <Copy size={12} style={{ transform: 'scaleX(-1)' }} /> : <Square size={12} />}
      </button>
      <button className="win-btn close" title={t('Close', 'Đóng')} onClick={() => window.api.win.close()}>
        <X size={16} />
      </button>
    </div>
  )
}

/* ================================ Activity bar ================================ */

export function ActivityBar(): React.JSX.Element {
  const view = useStore((s) => s.sidebarView)
  const open = useStore((s) => s.sidebarOpen)
  const attention = useStore((s) => s.chats.filter((c) => c.attention).length)
  const working = useStore((s) => s.chats.some((c) => c.status === 'working'))
  const changes = useStore((s) => s.git.files.length)
  const t = useT()

  const item = (v: SidebarView, icon: React.ReactNode, title: string, badge?: React.ReactNode): React.JSX.Element => (
    <button
      className={`activity-item${view === v && open ? ' active' : ''}`}
      title={title}
      onClick={() => useStore.setState((s) => (s.sidebarView === v && s.sidebarOpen ? { sidebarOpen: false } : { sidebarView: v, sidebarOpen: true }))}
    >
      {icon}
      {badge}
    </button>
  )

  return (
    <div className="activity-bar">
      <SlidePill />
      {item(
        'chats',
        <MessagesSquare size={20} strokeWidth={1.7} />,
        t('Chats', 'Chat'),
        attention > 0 ? <span className="badge accent">{attention}</span> : working ? <span className="badge-pulse" /> : null
      )}
      {item('explorer', <Files size={20} strokeWidth={1.7} />, 'Explorer (Ctrl+Shift+E)')}
      {item('changes', <GitCompare size={20} strokeWidth={1.7} />, t('Changes (Ctrl+Shift+G)', 'Thay đổi (Ctrl+Shift+G)'), changes > 0 ? <span className="badge">{changes > 99 ? '99+' : changes}</span> : null)}
    </div>
  )
}

/* ================================ Status bar ================================ */

/** "1:00 PM" today, "Fri 3:00 AM" later in the week. */
function resetLabel(iso: string | null, t: T): string {
  if (!iso) return ''
  const d = new Date(iso)
  const locale = t('en-US', 'vi-VN')
  const time = d.toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' })
  return d.toDateString() === new Date().toDateString() ? time : `${d.toLocaleDateString(locale, { weekday: 'short' })} ${time}`
}

/** The limit's name ("5-hour", "Weekly", "Weekly · Opus" from the backend) in the UI language. */
function limitLabel(l: UsageLimit, t: T): string {
  if (l.kind === 'session') return t('5-hour', '5 giờ')
  return l.label.replace(/^Weekly/, t('Weekly', 'Tuần'))
}

/** Plan usage limits (same as Claude's "Plan usage limits" panel), refreshed every 2 minutes. */
function UsageMeters(): React.JSX.Element | null {
  const [limits, setLimits] = useState<UsageLimit[] | null>(null)
  const t = useT()
  useEffect(() => {
    let live = true
    const load = (): void => {
      // optional call: an app started before this feature has no `usage` bridge until it restarts
      window.api.claude.usage?.().then((l) => live && l && setLimits(l)).catch(() => {})
    }
    load()
    const timer = setInterval(load, 120000)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [])
  return (
    <div className="usage-meters">
      {limits?.map((l) => (
        <div key={l.kind + l.label} className={`usage-meter sev-${l.severity}`} title={t(`${limitLabel(l, t)}: ${l.percent}% used · resets ${resetLabel(l.resetsAt, t)}`, `${limitLabel(l, t)}: đã dùng ${l.percent}% · đặt lại lúc ${resetLabel(l.resetsAt, t)}`)}>
          <span className="usage-label">{limitLabel(l, t)}</span>
          <span className="usage-bar">
            <span style={{ width: `${Math.min(100, l.percent)}%` }} />
          </span>
          <span className="usage-pct">{l.percent}%</span>
          {l.resetsAt && <span className="usage-reset">↻ {resetLabel(l.resetsAt, t)}</span>}
        </div>
      ))}
      <RamMeter />
      <TempMeter />
      <SoundMeter />
    </div>
  )
}

/** Machine-wide RAM in use, refreshed every 5 seconds. */
function RamMeter(): React.JSX.Element | null {
  const [mem, setMem] = useState<{ usedBytes: number; totalBytes: number } | null>(null)
  const t = useT()
  useEffect(() => {
    let live = true
    const load = (): void => {
      window.api.claude.memory?.().then((m) => live && setMem(m)).catch(() => {})
    }
    load()
    const timer = setInterval(load, 5000)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [])
  if (!mem?.totalBytes) return null
  const percent = Math.round((mem.usedBytes / mem.totalBytes) * 100)
  const gb = (b: number): string => (b / 1024 ** 3).toFixed(1)
  const severity = percent >= 90 ? 'critical' : percent >= 75 ? 'warning' : 'normal'
  return (
    <div className={`usage-meter sev-${severity}`} title={t(`RAM: ${gb(mem.usedBytes)} GB of ${gb(mem.totalBytes)} GB in use`, `RAM: đang dùng ${gb(mem.usedBytes)} GB / ${gb(mem.totalBytes)} GB`)}>
      <span className="usage-label">RAM</span>
      <span className="usage-bar">
        <span style={{ width: `${Math.min(100, percent)}%` }} />
      </span>
      <span className="usage-pct">{percent}%</span>
      <span className="usage-reset">
        {gb(mem.usedBytes)}/{gb(mem.totalBytes)} GB
      </span>
    </div>
  )
}

export function StatusBar(): React.JSX.Element {
  const git = useStore((s) => s.git)
  const claude = useStore((s) => s.claude)
  const working = useStore((s) => s.chats.filter((c) => c.status === 'working').length)
  const total = useStore((s) => s.chats.length)
  const tab = useStore((s) => s.tabs.find((t) => t.id === s.activeTabId))
  const t = useT()

  return (
    <div className="statusbar">
      <div className="statusbar-left">
        {git.isRepo && (
          <button className="sb-item" onClick={() => useStore.setState({ centerView: 'code' })}>
            <GitBranch size={12} /> {git.branch}
            {git.files.length > 0 && <span className="sb-muted">· {t(`${git.files.length} changed`, `${git.files.length} thay đổi`)}</span>}
          </button>
        )}
        <UpdateButton />
        {total > 0 && (
          <button className="sb-item" onClick={() => useStore.setState({ sidebarView: 'chats', sidebarOpen: true })}>
            {working > 0 ? <Loader2 size={12} className="spin" /> : <MessagesSquare size={12} />}
            {working > 0 ? t(`${working} working`, `${working} đang chạy`) : t(`${total} chat${total > 1 ? 's' : ''}`, `${total} chat`)}
          </button>
        )}
      </div>
      <UsageMeters />
      <div className="statusbar-right">
        {tab && <span className="sb-item">{languageOf(tab.path)}</span>}
        {tab && <span className="sb-item">UTF-8</span>}
        <RemoteButton />
        {claude && <AgentPicker />}
      </div>
    </div>
  )
}

/**
 * Shown when GitHub has a newer release: a full-window popup with its notes as soon as it is
 * published (checked every few minutes), and a status-bar button that reopens it after "Later".
 */
function UpdateButton(): React.JSX.Element | null {
  const [update, setUpdate] = useState<{ version: string; notes: string } | null>(null)
  const [dismissed, setDismissed] = useState<string | null>(null)
  const [state, setState] = useState<'idle' | 'busy' | 'failed'>('idle')
  const t = useT()

  useEffect(() => {
    const check = (): void => void window.api.app.checkUpdate().then(setUpdate, () => {})
    check()
    const timer = setInterval(check, 5 * 60 * 1000)
    return () => clearInterval(timer)
  }, [])

  if (!update) return null
  const { version, notes } = update
  const install = (): void => {
    setState('busy')
    window.api.app.installUpdate().catch(() => setState('failed'))
  }
  const label = state === 'busy' ? t('Updating…', 'Đang cập nhật…') : state === 'failed' ? t('Update failed · retry', 'Cập nhật lỗi · thử lại') : t(`Update v${version}`, `Cập nhật v${version}`)
  return (
    <>
      <button className="sb-item sb-update" onClick={() => setDismissed(null)} title={t(`See what's new in v${version}`, `Xem có gì mới trong v${version}`)}>
        {state === 'busy' ? <Loader2 size={12} className="spin" /> : <ArrowDownToLine size={12} />}
        {label}
      </button>
      {dismissed !== version && (
        <div className="overlay update-overlay">
          <div className="update-card">
            <div className="update-head">
              <ArrowDownToLine size={18} />
              <div>
                <div className="update-title">{t(`Update available · v${version}`, `Có bản cập nhật · v${version}`)}</div>
                <div className="update-sub">{t("What's new in this version", 'Có gì mới trong phiên bản này')}</div>
              </div>
            </div>
            <div className="update-notes">{notes || t('Bug fixes and improvements.', 'Sửa lỗi và cải tiến.')}</div>
            <div className="update-actions">
              <button className="btn" disabled={state === 'busy'} onClick={() => setDismissed(version)}>
                {t('Later', 'Để sau')}
              </button>
              <button className="btn btn-primary" disabled={state === 'busy'} onClick={install}>
                {state === 'busy' && <Loader2 size={13} className="spin" />}
                {state === 'busy' ? t('Updating…', 'Đang cập nhật…') : state === 'failed' ? t('Retry update', 'Thử cập nhật lại') : t('Update now', 'Cập nhật ngay')}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  )
}

/** Status-bar "AI in use" picker — a plain New chat starts with the agent chosen here. */
function AgentPicker(): React.JSX.Element {
  const claude = useStore((s) => s.claude)
  useStore((s) => s.agents)
  useStore((s) => s.preferredAgent)
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const list = installedAgents()
  const cur = defaultAgent()
  const t = useT()

  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('mousedown', close, true)
    window.addEventListener('keydown', esc, true)
    return () => {
      window.removeEventListener('mousedown', close, true)
      window.removeEventListener('keydown', esc, true)
    }
  }, [open])

  if (!cur)
    return (
      <span className="sb-item warn" title={claude?.path ?? ''}>
        <CircleAlert size={12} /> {t('No AI agent found', 'Không tìm thấy AI agent')}
      </span>
    )
  return (
    <div className="sb-agent" ref={ref}>
      <button className="sb-item ok" title={t('AI in use — New chat starts with this agent', 'AI đang dùng — Chat mới sẽ bắt đầu với agent này')} onClick={() => setOpen((o) => !o)}>
        <CircleCheck size={12} /> {agentDef(cur).label}
        {list.length > 1 && <ChevronUp size={11} />}
      </button>
      {open && list.length > 0 && (
        <div className="menu sb-agent-menu">
          <div className="menu-sep">{t('AI in use', 'AI đang dùng')}</div>
          {list.map((id) => {
            const a = agentDef(id)
            return (
              <button
                key={id}
                className="menu-item"
                onClick={() => {
                  setDefaultAgent(id)
                  setOpen(false)
                }}
              >
                <span className="menu-item-main">{a.label}</span>
                {id === cur ? <Check size={12} /> : <span className="menu-item-sub">{a.cmd}</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

/* ================================ Quick open ================================ */

/** `q` and `t` already lower-cased. */
function fuzzy(q: string, t: string): number {
  if (!q) return 1
  const name = t.slice(t.lastIndexOf('/') + 1)
  if (name.startsWith(q)) return 1000 - name.length
  if (name.includes(q)) return 800 - name.length
  if (t.includes(q)) return 500 - t.length
  let ti = 0
  let score = 0
  for (const ch of q) {
    const idx = t.indexOf(ch, ti)
    if (idx < 0) return -1
    score += idx === ti ? 3 : 1
    ti = idx + 1
  }
  return score
}

/**
 * Ctrl+P: files. With ">" first (Ctrl+Shift+P / F1): every command and its shortcut.
 * "@" jumps to a symbol in the open file, ":" to a line.
 */
export function QuickOpen(): React.JSX.Element {
  const root = useStore((s) => s.root)
  const [files, setFiles] = useState<string[]>([])
  const [q, setQ] = useState(() => useStore.getState().quickOpenQuery)
  const [sel, setSel] = useState(0)
  const listRef = useRef<HTMLDivElement>(null)
  const commandMode = q.startsWith('>')
  const t = useT()

  useEffect(() => {
    if (root) window.api.fs.listFiles(root).then(setFiles)
  }, [root])

  // lower-cased once per project, not once per file per keystroke
  const lower = useMemo(() => files.map((f) => f.toLowerCase()), [files])
  // typing stays responsive in big projects: the list catches up a frame later
  const dq = useDeferredValue(q)
  const fileHits = useMemo(() => {
    if (dq.startsWith('>')) return []
    const needle = dq.trim().toLowerCase()
    if (!needle) return files.slice(0, 60)
    const hits: { f: string; s: number }[] = []
    for (let i = 0; i < files.length; i++) {
      const sc = fuzzy(needle, lower[i])
      if (sc >= 0) hits.push({ f: files[i], s: sc })
    }
    return hits
      .sort((a, b) => b.s - a.s)
      .slice(0, 60)
      .map((x) => x.f)
  }, [files, lower, dq])
  const commandHits = useMemo(() => {
    if (!commandMode) return []
    const needle = q.slice(1).trim().toLowerCase()
    if (!needle) return COMMANDS
    return COMMANDS.map((c) => ({ c, s: fuzzy(needle, t(...c.label).toLowerCase()) }))
      .filter((x) => x.s >= 0)
      .sort((a, b) => b.s - a.s)
      .map((x) => x.c)
  }, [commandMode, q, t])
  const count = commandMode ? commandHits.length : fileHits.length

  useEffect(() => setSel(0), [q])
  useEffect(() => {
    revealIn(listRef.current, listRef.current?.children[sel], { block: 'nearest' })
  }, [sel])

  const close = (): void => useStore.setState({ quickOpen: false, quickOpenQuery: '' })
  const pickFile = (rel: string): void => {
    if (!root) return
    const sep = window.api.platform === 'win32' ? '\\' : '/'
    openFile(root.replace(/[\\/]$/, '') + sep + rel.replace(/[\\/]/g, sep))
    close()
  }
  const runCommand = (c: Command): void => {
    close()
    // after the palette is gone, so focus lands where the command puts it
    setTimeout(c.run)
  }
  const pick = (i: number): void => {
    if (commandMode) {
      if (commandHits[i]) runCommand(commandHits[i])
    } else if (fileHits[i]) pickFile(fileHits[i])
  }

  return (
    <div className="overlay" onMouseDown={close}>
      <div className="palette" onMouseDown={(e) => e.stopPropagation()}>
        <div className="palette-input">
          <Search size={15} />
          <input
            autoFocus
            placeholder={commandMode ? t('Type a command…', 'Nhập lệnh…') : t('Search files by name…  (> commands · @ symbol · : line)', 'Tìm tệp theo tên…  (> lệnh · @ ký hiệu · : dòng)')}
            value={q}
            onChange={(e) => {
              const v = e.target.value
              // "@" → symbols in the open file, ":" → go to line (as in VS Code)
              if (v === '@' || v === ':') {
                close()
                setTimeout(() => window.dispatchEvent(new Event(v === '@' ? 'go-to-symbol' : 'go-to-line')))
              } else setQ(v)
            }}
            onKeyDown={(e) => {
              if (e.key === 'Escape') close()
              if (e.key === 'ArrowDown') {
                e.preventDefault()
                setSel((s) => Math.min(s + 1, count - 1))
              }
              if (e.key === 'ArrowUp') {
                e.preventDefault()
                setSel((s) => Math.max(s - 1, 0))
              }
              if (e.key === 'Enter') pick(sel)
            }}
          />
        </div>
        <div className="palette-list" ref={listRef}>
          {commandMode
            ? commandHits.map((c, i) => (
                <div key={c.id} className={`palette-row${i === sel ? ' sel' : ''}`} onMouseEnter={() => setSel(i)} onClick={() => runCommand(c)}>
                  <span className="palette-name">{t(...c.label)}</span>
                  {c.keys && <kbd className="palette-keys">{c.keys}</kbd>}
                </div>
              ))
            : fileHits.map((r, i) => {
                const name = r.split('/').pop()!
                return (
                  <div key={r} className={`palette-row${i === sel ? ' sel' : ''}`} onMouseEnter={() => setSel(i)} onClick={() => pickFile(r)}>
                    <FileIcon name={name} />
                    <span className="palette-name">{name}</span>
                    <span className="palette-dir">{r.slice(0, -name.length - 1)}</span>
                  </div>
                )
              })}
          {count === 0 && (
            <div className="palette-empty">{commandMode ? t('No matching commands', 'Không có lệnh phù hợp') : !root ? t('Open a folder first', 'Hãy mở một thư mục trước') : files.length ? t('No matching files', 'Không có tệp phù hợp') : t('Indexing…', 'Đang lập chỉ mục…')}</div>
          )}
        </div>
      </div>
    </div>
  )
}

/* ================================ Welcome (no folder) ================================ */

export function Welcome(): React.JSX.Element {
  const claude = useStore((s) => s.claude)
  useStore((s) => s.agents)
  useStore((s) => s.preferredAgent)
  const agents = installedAgents()
  const agent = defaultAgent()
  const projects = useStore((s) => s.projects)
  // whose history the list below shows
  const sources = ['Claude', ...AGENTS.filter((a) => projects.some((g) => g.sessions.some((s) => s.agent === a.id))).map((a) => a.label)].join(' · ')
  const byRecent = [...projects].sort((a, b) => b.updated - a.updated)
  const totalChats = projects.reduce((n, g) => n + g.sessions.length, 0)
  const t = useT()
  return (
    <div className="welcome">
      <div className="welcome-bg" />
      <div className="welcome-grid">
        <div className="welcome-inner">
          <div className="glow-orb big">
            <Logo size={84} />
          </div>
          <h1>
            VIBE <span className="h1-accent">CODE</span>
          </h1>
          <p className="welcome-sub">
            {t(
              'A home for Claude Code, Codex and other coding agents. Parallel chats, a real editor, and every change one click away.',
              'Ngôi nhà cho Claude Code, Codex và các coding agent khác. Nhiều chat song song, một trình soạn thảo thực thụ, mọi thay đổi chỉ cách một cú bấm.'
            )}
          </p>
          {agents.length > 1 && (
            <div className="welcome-agents" title={t('New chats start with this agent', 'Chat mới sẽ bắt đầu với agent này')}>
              <span className="welcome-agents-label">{t('Chat with', 'Chat với')}</span>
              {agents.map((id) => (
                <button key={id} className={`welcome-agent${id === agent ? ' on' : ''}`} onClick={() => setDefaultAgent(id)}>
                  {id === agent && <Check size={12} />} {agentDef(id).label}
                </button>
              ))}
            </div>
          )}
          <button className="btn btn-primary btn-lg" onClick={() => openFolder()}>
            <FolderOpen size={17} /> {t('Open a project folder', 'Mở thư mục dự án')}
          </button>
          {/* another agent alone is enough to chat: only a PC with none is told what to install */}
          {claude && agents.length === 0 && (
            <p className="welcome-warn">
              <CircleAlert size={14} />{' '}
              {t(
                "No coding agent (Claude Code, Codex…) was found on this machine. You'll get install steps after opening a folder.",
                'Không tìm thấy coding agent nào (Claude Code, Codex…) trên máy này. Hướng dẫn cài đặt sẽ hiện sau khi bạn mở một thư mục.'
              )}
            </p>
          )}
        </div>

        {projects.length > 0 && (
          <div className="claude-projects">
            <div className="cp-head">
              <span className="cp-title">
                <Link2 size={13} /> {t(`From ${sources}`, `Từ ${sources}`)}
              </span>
              <span className="cp-sub">
                {t(`${projects.length} projects · ${totalChats} chats`, `${projects.length} dự án · ${totalChats} chat`)}
              </span>
            </div>
            <div className="cp-list">
              {byRecent.map((g) => (
                <div key={g.key} className="cp-proj">
                  <button className="cp-proj-row" onClick={() => openFolder(g.cwd, { autoChat: false })} title={g.cwd}>
                    <FolderOpen size={15} />
                    <span className="cp-name">{g.name}</span>
                    <span className="cp-count">{g.sessions.length}</span>
                    <span className="cp-path">{g.cwd}</span>
                  </button>
                  {g.sessions.slice(0, 2).map((s) => (
                    <button key={s.id} className="cp-sess" onClick={() => openSession(s)} title={t(`Resume: ${s.title}`, `Tiếp tục: ${s.title}`)}>
                      <MessagesSquare size={12} />
                      <span className="cp-sess-title">{s.title}</span>
                      {s.agent && <span className="sess-agent">{agentDef(s.agent).label}</span>}
                      <span className="cp-sess-time">{ago(s.updated, t)}</span>
                    </button>
                  ))}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function ago(time: number, t: T): string {
  const m = Math.floor((Date.now() - time) / 60000)
  if (m < 60) return t(`${Math.max(1, m)}m`, `${Math.max(1, m)} phút`)
  const h = Math.floor(m / 60)
  if (h < 24) return t(`${h}h`, `${h} giờ`)
  return t(`${Math.floor(h / 24)}d`, `${Math.floor(h / 24)} ngày`)
}
