import { memo, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import { Collapse, SlidePill } from './motion'
import {
  Check,
  ChevronDown,
  ChevronRight,
  Loader2,
  FolderGit2,
  FolderPlus,
  PanelLeftClose,
  History,
  RefreshCw,
  RotateCcw,
  Sparkles,
  X,
  ChevronsDownUp,
  Copy,
  ExternalLink,
  FolderOpen,
  GitCommitHorizontal,
  GitBranch,
  Link2,
  Search,
  MessageSquare,
  Pencil,
  Plus,
  FilePlus,
  FileText,
  Scissors,
  ClipboardPaste,
  CopyPlus,
  Trash2,
  Undo2,
  FileDiff,
  ArrowDown,
  ArrowUp,
  CloudUpload
} from 'lucide-react'
import { basename, useStore, type Chat, type EditorTab } from '../store'
import {
  closeChat,
  closeTab,
  defaultAgent,
  loadSessions,
  openFolder,
  newChat,
  newChatIn,
  openCommitDiff,
  openDiff,
  openFile,
  openSession,
  refreshGit,
  renameChat,
  restartChat,
  revealInApp,
  selectChat
} from '../actions'
import { hasUnsaved } from '../fileModelsLite'
import { RenameInput, startRename, useRenaming } from './InlineRename'
import { openMenu } from './ContextMenu'
import { FileIcon, FolderIcon, StatusDot } from './icons'
import type { DirEntry, GitBranch as GitBranchInfo, GitCommit, GitCommitFile, GitFile, ProjectGroup, SessionInfo } from '../../../shared/types'
import { agentDef } from '../../../shared/agents'
import { NewChatMenu } from './AgentMenu'
import { ZaloSideGroup } from './zalo/ZaloSide'
import { tr, useT, type T } from '../i18n'

export function Sidebar(): React.JSX.Element {
  // files and git changes live in the Source code tab; the sidebar is just the chats
  return (
    <div className="sidebar">
      <ChatsView />
    </div>
  )
}

function SectionHeader({ title, children }: { title: string; children?: React.ReactNode }): React.JSX.Element {
  return (
    <div className="section-header">
      <span>{title}</span>
      <div className="section-actions">{children}</div>
    </div>
  )
}

/* ================================ Chats ================================ */

function useTick(ms: number): void {
  const [, force] = useState(0)
  useEffect(() => {
    const t = setInterval(() => force((n) => n + 1), ms)
    return () => clearInterval(t)
  }, [ms])
}

const normKey = (p: string): string => p.toLowerCase().replace(/[\\/]+$/, '')

function ChatsView(): React.JSX.Element {
  useTick(30000)
  const t = useT()
  // New chat lives on the + of each project (and Ctrl+Shift+N), so the list starts right away
  const disabled = !useStore((s) => !!s.claude?.found || s.agents.some((a) => a.found))
  return (
    <>
      <div className="scroll">
        <ProjectsTree />
      </div>
      <div className="sidebar-foot">
        <button
          className="icon-btn"
          disabled={disabled}
          title={t('New project: pick (or make) a folder and start a chat in it', 'Dự án mới: chọn (hoặc tạo) một thư mục và bắt đầu chat trong đó')}
          onClick={() => openFolder(null, { autoChat: true })}
        >
          <FolderPlus size={16} />
        </button>
        <button className="icon-btn" title={t('Hide sidebar (Ctrl+B)', 'Ẩn thanh bên (Ctrl+B)')} onClick={() => useStore.setState({ sidebarOpen: false })}>
          <PanelLeftClose size={16} />
        </button>
      </div>
    </>
  )
}

const EXPANDED_KEY = 'tinjs.expandedProjects'
function loadExpanded(): Set<string> {
  try {
    return new Set(JSON.parse(localStorage.getItem(EXPANDED_KEY) ?? '[]'))
  } catch {
    return new Set()
  }
}

const PAGE = 8

interface RecentItem {
  key: string
  title: string
  project: string
  updated: number
  /** open in this window */
  chat?: Chat
  /** in Claude's history (resumable) */
  session?: SessionInfo
}

/** A row of Recent; plain props, so it skips re-rendering while nothing about it changed. */
const RecentRow = memo(function RecentRow(props: {
  title: string
  project: string
  updated: number
  chatId?: string
  status?: Chat['status']
  attention?: boolean
  session?: SessionInfo
  active: boolean
}): React.JSX.Element {
  const { title, project, updated, chatId, status, attention, session, active } = props
  const t = useT()
  return (
    <div
      className={`sess-row${active ? ' active' : ''}`}
      onClick={() => (chatId ? selectChat(chatId) : session && void openSession(session))}
      onContextMenu={(e) => chatMenu(e, { chatId, session }, 'recent')}
      title={`${title}\n${project} · ${new Date(updated).toLocaleString(t('en-US', 'vi-VN'))}`}
    >
      {status ? <StatusDot status={status} attention={attention} /> : <span className="sess-bullet" />}
      <ChatTitle place="recent" chatId={chatId} title={title} />
      <span className="sess-time"><Ago t={updated} /></span>
    </div>
  )
})

/** The open chats of every project that are working right now, or finished while you looked elsewhere
 *  (unread); one drops out once its turn ends and you've opened it. */
function recentItems(projects: ProjectGroup[], chats: Chat[]): RecentItem[] {
  const sessions = new Map(projects.flatMap((g) => g.sessions.map((s) => [s.id, s] as const)))
  return chats
    .filter((c) => c.status === 'working' || c.attention)
    .map((c) => {
      const s = c.sessionId ? sessions.get(c.sessionId) : undefined
      return { key: c.id, title: c.pinnedTitle ? c.title : s?.title || c.title, project: basename(c.cwd), updated: s?.updated ?? c.createdAt, chat: c, session: s }
    })
    .sort((a, b) => b.updated - a.updated)
}

/** Every project + conversation from Claude Code's store — the same list the Claude app shows. */
function ProjectsTree(): React.JSX.Element {
  const t = useT()
  const projects = useStore((s) => s.projects)
  const root = useStore((s) => s.root)
  const chats = useStore((s) => s.chats)
  const activeChatId = useStore((s) => s.activeChatId)
  const [expanded, setExpanded] = useState<Set<string>>(loadExpanded)
  const [more, setMore] = useState<Set<string>>(new Set())
  const [q, setQ] = useState('')

  // the project you're in starts open
  useEffect(() => {
    if (!root) return
    const key = normKey(root)
    setExpanded((e) => (e.has(key) ? e : new Set(e).add(key)))
  }, [root])

  useEffect(() => {
    try {
      localStorage.setItem(EXPANDED_KEY, JSON.stringify([...expanded]))
    } catch {
      /* storage unavailable */
    }
  }, [expanded])

  const liveBySession = useMemo(() => new Map(chats.filter((c) => c.sessionId).map((c) => [c.sessionId!, c])), [chats])
  const activeSession = chats.find((c) => c.id === activeChatId)?.sessionId

  // Open chats the session store doesn't list (yet) go under their project, adding the project when
  // it has no Claude history: Codex / Grok / Gemini… chats, and new Claude chats until Claude writes
  // their transcript (only after the first message; a missed file event could delay it further).
  const slashKey = (p: string): string => normKey(p).replace(/\//g, '\\')
  const known = useMemo(() => new Set(projects.flatMap((g) => g.sessions.map((s) => s.id))), [projects])
  // (an agent's chat opened from its history is listed there already)
  const agentChats = chats.filter((c) => (agentDef(c.agent).id !== 'claude' ? !c.sessionId || !known.has(c.sessionId) : !!c.sessionId && !known.has(c.sessionId)))
  const allProjects: ProjectGroup[] = [...projects]
  for (const c of agentChats) {
    if (allProjects.some((g) => slashKey(g.key) === slashKey(c.cwd))) continue
    allProjects.unshift({ key: normKey(c.cwd), cwd: c.cwd, name: basename(c.cwd), updated: c.createdAt, sessions: [] })
  }
  const needle = q.trim().toLowerCase()
  // Opening a chat touches its transcript (resume, focus…), which would jump it to the top under
  // the cursor. Rows already listed keep their place; only chats newly entering the list go first.
  // A row is known by its session id and, once open, its chat id too: resuming a session or a new
  // chat getting its session id must not count as a new entry.
  const recentOrder = useRef(new Map<string, number>())
  const recent = useMemo(() => {
    const prev = recentOrder.current
    const ids = (it: RecentItem): string[] => [it.key, it.session?.id, it.chat?.id, it.chat?.sessionId].filter((x): x is string => !!x)
    const pos = (it: RecentItem): number | undefined => ids(it).map((k) => prev.get(k)).find((p) => p !== undefined)
    const top = recentItems(projects, chats)
    const kept = top.filter((it) => pos(it) !== undefined).sort((a, b) => pos(a)! - pos(b)!)
    const rows = [...top.filter((it) => pos(it) === undefined), ...kept]
    recentOrder.current = new Map(rows.flatMap((it, i) => ids(it).map((k) => [k, i] as const)))
    return rows
  }, [projects, chats])
  const agentRows = (g: ProjectGroup): typeof agentChats =>
    agentChats.filter(
      (c) => slashKey(c.cwd) === slashKey(g.key) && (!needle || g.name.toLowerCase().includes(needle) || c.title.toLowerCase().includes(needle))
    )
  const visible = needle
    ? allProjects
        .map((g) => ({
          ...g,
          sessions: g.name.toLowerCase().includes(needle) ? g.sessions : g.sessions.filter((s) => s.title.toLowerCase().includes(needle))
        }))
        .filter((g) => g.sessions.length > 0 || agentRows(g).length > 0)
    : allProjects

  const flip = (set: (f: (s: Set<string>) => Set<string>) => void, key: string): void =>
    set((e) => {
      const n = new Set(e)
      if (n.has(key)) n.delete(key)
      else n.add(key)
      return n
    })

  return (
    <div className="side-group">
      <SlidePill selector=".sess-row.active" className="sess-pill" />
      <div className="side-group-label">
        {t('Projects', 'Dự án')}
        <span className="sync-pill" title={t('Read live from ~/.claude/projects — the same store the Claude app uses', 'Đọc trực tiếp từ ~/.claude/projects — cùng kho dữ liệu mà ứng dụng Claude dùng')}>
          <Link2 size={10} /> Claude
        </span>
        <button className="icon-btn tiny" title={t('Refresh', 'Tải lại')} onClick={() => loadSessions()}>
          <RefreshCw size={12} />
        </button>
      </div>
      <div className="tree-filter">
        <Search size={12} />
        <input placeholder={t('Filter chats…', 'Lọc chat…')} value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Escape' && setQ('')} />
      </div>

      {/* chats working right now or finished unread, across every project */}
      {!needle && recent.length > 0 && (
        <div className="proj recent-group">
          <div className="proj-row recent-head">
            <span className="proj-name">{t('Running & unread', 'Đang chạy & chưa đọc')}</span>
          </div>
          {recent.map((it) => (
            <RecentRow
              key={it.key}
              title={it.title}
              project={it.project}
              updated={it.updated}
              chatId={it.chat?.id}
              status={it.chat?.status}
              attention={it.chat?.attention}
              session={it.session}
              active={!!it.chat && it.chat.id === activeChatId}
            />
          ))}
        </div>
      )}
      <ZaloSideGroup filter={q} />
      <div className="agent-groups-sep" />

      {visible.length === 0 && <div className="tree-empty">{projects.length ? t('No matching chats', 'Không có chat nào khớp') : t('No Claude Code history found yet.', 'Chưa tìm thấy lịch sử Claude Code nào.')}</div>}

      {visible.map((g) => {
        const open = needle ? true : expanded.has(g.key)
        const isRoot = !!root && normKey(root) === g.key
        const others = agentRows(g)
        const liveCount = g.sessions.filter((s) => liveBySession.has(s.id)).length + others.length
        const shown = needle || more.has(g.key) ? g.sessions : g.sessions.slice(0, PAGE)
        return (
          <div key={g.key} className="proj">
            <div className={`proj-row${isRoot ? ' current' : ''}`} onClick={() => flip(setExpanded, g.key)} onContextMenu={(e) => projectMenu(e, g)} title={g.cwd}>
              <span className="proj-name">{g.name}</span>
              <ChevronRight size={13} className={`proj-chev${open ? ' open' : ''}`} />
              {liveCount > 0 && <span className="proj-live" title={t(`${liveCount} open`, `${liveCount} đang mở`)} />}
              <span className="proj-spacer" />
              <NewChatMenu
                className="icon-btn tiny proj-add"
                size={14}
                title={t(`New chat in ${g.name} — right-click to pick another AI`, `Chat mới trong ${g.name} — chuột phải để chọn AI khác`)}
                onPick={(agent) => newChatIn(g.cwd, agent)}
              />
            </div>
            <Collapse open={open}>
            {others.map((c) => (
              <div
                key={c.id}
                className={`sess-row${c.id === activeChatId ? ' active' : ''}`}
                onClick={() => selectChat(c.id)}
                onContextMenu={(e) => chatMenu(e, { chatId: c.id }, 'tree')}
                title={`${c.title}\n${agentDef(c.agent).label} · ${c.cwd}`}
              >
                <StatusDot status={c.status} attention={c.attention} />
                <ChatTitle place="tree" chatId={c.id} title={c.title} />
                <span className="sess-time">{agentDef(c.agent).id === 'claude' ? <Ago t={c.createdAt} /> : agentDef(c.agent).label}</span>
              </div>
            ))}
            {shown.map((s) => {
              const live = liveBySession.get(s.id)
              return <SessRow key={s.id} s={s} active={activeSession === s.id} status={live?.status} attention={live?.attention} />
            })}
            {!needle && g.sessions.length > PAGE && (
              <button className="sess-more" onClick={() => flip(setMore, g.key)}>
                {more.has(g.key) ? t('Show less', 'Ẩn bớt') : t(`Show ${g.sessions.length - PAGE} more`, `Hiện thêm ${g.sessions.length - PAGE}`)}
              </button>
            )}
            </Collapse>
          </div>
        )
      })}
    </div>
  )
}

/**
 * One conversation under its project. Memoized: the tree re-renders on every sessions ping while a
 * chat works; rows whose session object loadSessions kept (unchanged) skip it.
 */
const SessRow = memo(function SessRow(props: { s: SessionInfo; active: boolean; status?: Chat['status']; attention?: boolean }): React.JSX.Element {
  const { s, active, status, attention } = props
  const t = useT()
  // primitives only: this row re-renders when they change, not on every chat update
  const liveId = useStore((st) => st.chats.find((c) => c.sessionId === s.id)?.id)
  const pinned = useStore((st) => {
    const c = st.chats.find((x) => x.sessionId === s.id)
    return c?.pinnedTitle ? c.title : undefined
  })
  return (
    <div
      className={`sess-row${active ? ' active' : ''}${s.cwdExists ? '' : ' gone'}`}
      onClick={() => openSession(s)}
      onContextMenu={(e) => chatMenu(e, { session: s }, 'tree')}
      title={`${s.title}\n${s.cwd}\n${t('Updated', 'Cập nhật')} ${new Date(s.updated).toLocaleString(t('en-US', 'vi-VN'))}`}
    >
      {status ? <StatusDot status={status} attention={attention} /> : <span className="sess-bullet" />}
      <ChatTitle place="tree" chatId={liveId} title={pinned ?? s.title} />
      {s.agent && <span className="sess-agent">{agentDef(s.agent).label}</span>}
      <span className="sess-time"><Ago t={s.updated} /></span>
    </div>
  )
})

/** A chat's name in a row; a text box while it's renamed from that row's menu. */
export function ChatTitle({ place, chatId, title, className = 'sess-title' }: { place: string; chatId?: string; title: string; className?: string }): React.JSX.Element {
  const editing = useRenaming((r) => !!chatId && r.key === `chat:${place}:${chatId}`)
  if (editing) return <RenameInput value={title} onCommit={(t) => renameChat(chatId!, t)} />
  return <span className={className}>{title}</span>
}

/**
 * Right-click on a chat: an open chat (`chatId`) and/or a session from the history. `place` names
 * the row it was opened on (the same chat is listed in several), so Rename edits that one.
 */
export function chatMenu(e: React.MouseEvent, ref: { chatId?: string; session?: SessionInfo }, place: string): void {
  const chats = useStore.getState().chats
  const chat = chats.find((c) => c.id === ref.chatId) ?? (ref.session ? chats.find((c) => c.sessionId === ref.session!.id) : undefined)
  const s = ref.session
  const title = chat?.title ?? s?.title ?? 'Chat'
  const cwd = chat?.cwd ?? s?.cwd
  const sessionId = chat?.sessionId ?? s?.id
  openMenu(e, [
    { label: tr('Open', 'Mở'), icon: <MessageSquare size={14} />, action: () => (chat ? selectChat(chat.id) : s && openSession(s)) },
    chat && {
      label: tr('Rename…', 'Đổi tên…'),
      icon: <Pencil size={14} />,
      action: () => startRename(`chat:${place}:${chat.id}`)
    },
    chat?.status === 'exited' && { label: tr('Restart', 'Khởi động lại'), icon: <RotateCcw size={14} />, action: () => restartChat(chat.id) },
    chat && { label: tr('Close chat', 'Đóng chat'), icon: <X size={14} />, action: () => closeChat(chat.id) },
    'sep',
    { label: tr('Copy title', 'Sao chép tiêu đề'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(title) },
    !!sessionId && { label: tr('Copy session ID', 'Sao chép ID phiên'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(sessionId) },
    !!cwd && { label: tr('Open folder in File Explorer', 'Mở thư mục trong File Explorer'), icon: <FolderOpen size={14} />, action: () => window.api.fs.openPath(cwd) },
    'sep',
    // another agent's history is its own to keep: only Claude's transcripts are deleted from here
    !(s?.agent && !chat) && {
      label: tr('Delete chat…', 'Xoá chat…'),
      icon: <Trash2 size={14} />,
      hint: tr('to Recycle Bin', 'vào Thùng rác'),
      action: async () => {
        const working =
          chat?.status === 'working'
            ? tr(`\n\n${agentDef(chat.agent).label} is still working — it will be stopped.`, `\n\n${agentDef(chat.agent).label} vẫn đang làm — sẽ bị dừng lại.`)
            : ''
        if (!(await window.api.ask(tr(`Delete chat "${title}"?\nIts history goes to the Recycle Bin.${working}`, `Xoá chat "${title}"?\nLịch sử của nó sẽ được chuyển vào Thùng rác.${working}`)))) return
        if (chat) {
          closeChat(chat.id)
          // let the process exit first, or its last write would bring the transcript back
          await new Promise((r) => setTimeout(r, 800))
        }
        // a chat that never sent a message has no saved history
        const saved = !!sessionId && useStore.getState().projects.some((g) => g.sessions.some((x) => x.id === sessionId && !x.agent))
        if (saved) await window.api.sessions.remove(sessionId).catch((err) => window.alert(String(err)))
        loadSessions()
      }
    }
  ])
}

/** Right-click on a project in the sidebar. */
function projectMenu(e: React.MouseEvent, g: ProjectGroup): void {
  const agent = defaultAgent()
  openMenu(e, [
    !!agent && { label: tr('New chat', 'Chat mới'), icon: <Plus size={14} />, action: () => newChatIn(g.cwd, agent) },
    { label: tr('Open as workspace', 'Mở làm không gian làm việc'), icon: <FolderGit2 size={14} />, action: () => openFolder(g.cwd, { autoChat: false }) },
    'sep',
    { label: tr('Open folder in File Explorer', 'Mở thư mục trong File Explorer'), icon: <FolderOpen size={14} />, action: () => window.api.fs.openPath(g.cwd) },
    { label: tr('Copy path', 'Sao chép đường dẫn'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(g.cwd) }
  ])
}

/** "now", "5m", "3h", "2d", then the date. */
export function shortAgo(at: number, t: T): string {
  const m = Math.floor((Date.now() - at) / 60000)
  if (m < 1) return t('now', 'vừa xong')
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h`
  const d = Math.floor(h / 24)
  if (d < 30) return `${d}d`
  return new Date(at).toLocaleDateString(t('en-US', 'vi-VN'), { day: 'numeric', month: 'short' })
}

/** One shared clock ticking every 30 s, so "now" / "5m" labels age while they stay on screen. */
const minuteTick = (() => {
  let now = Date.now()
  const subs = new Set<() => void>()
  setInterval(() => {
    now = Date.now()
    subs.forEach((f) => f())
  }, 30_000)
  return {
    subscribe: (f: () => void) => (subs.add(f), () => void subs.delete(f)),
    get: () => now
  }
})()

/** shortAgo(t) that re-renders on its own as time passes. */
function Ago({ t: at }: { t: number }): React.JSX.Element {
  const t = useT()
  useSyncExternalStore(minuteTick.subscribe, minuteTick.get)
  return <>{shortAgo(at, t)}</>
}

/* ================================ Explorer ================================ */

function useGitDecorations(): Map<string, GitFile['status']> {
  // only paths + statuses matter here; +/- counts change on every edit Claude makes, and a new map
  // re-rendered the whole tree each time
  const sig = useStore((s) => s.git.files.map((f) => f.status + f.abs).join('\n'))
  return useMemo(() => {
    const m = new Map<string, GitFile['status']>()
    const files = useStore.getState().git.files
    for (const f of files) {
      const abs = f.abs.replace(/\\/g, '/').toLowerCase()
      m.set(abs, f.status)
      // bubble up to parent folders
      let p = abs
      while (p.includes('/')) {
        p = p.slice(0, p.lastIndexOf('/'))
        if (!m.has(p)) m.set(p, 'M')
      }
    }
    return m
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sig])
}

export function ExplorerView(): React.JSX.Element | null {
  const root = useStore((s) => s.root)
  const [collapseKey, setCollapseKey] = useState(0)
  const deco = useGitDecorations()
  if (!root) return null
  return <ExplorerTree root={root} collapseKey={collapseKey} setCollapseKey={setCollapseKey} deco={deco} />
}

type OpenCtx = (e: React.MouseEvent, path: string, isDir: boolean) => void

function ExplorerTree(props: { root: string; collapseKey: number; setCollapseKey: (f: (k: number) => number) => void; deco: Map<string, string> }): React.JSX.Element {
  const { root, collapseKey, setCollapseKey, deco } = props
  const t = useT()
  // stable, so the memoized tree nodes don't all re-render with this one
  const openCtx = useCallback<OpenCtx>((e, path, isDir) => explorerMenu(e, path, isDir, root), [root])
  return (
    <>
      <SectionHeader title="Explorer">
        <button className="icon-btn" title={t('New file', 'Tệp mới')} onClick={() => createIn(root, false)}>
          <FilePlus size={14} />
        </button>
        <button className="icon-btn" title={t('New folder', 'Thư mục mới')} onClick={() => createIn(root, true)}>
          <FolderPlus size={14} />
        </button>
        <button className="icon-btn" title={t('Refresh', 'Tải lại')} onClick={() => useStore.setState((s) => ({ fsTick: s.fsTick + 1 }))}>
          <RefreshCw size={14} />
        </button>
        <button className="icon-btn" title={t('Collapse all', 'Thu gọn tất cả')} onClick={() => setCollapseKey((k) => k + 1)}>
          <ChevronsDownUp size={14} />
        </button>
      </SectionHeader>
      <div className="tree-root-label" onContextMenu={(e) => openCtx(e, root, true)}>
        {basename(root)}
      </div>
      {/* empty space below the files: the project folder's menu */}
      <div className="scroll tree" key={collapseKey} onContextMenu={(e) => openCtx(e, root, true)}>
        <DirChildren dir={root} depth={0} deco={deco} openCtx={openCtx} />
      </div>
    </>
  )
}

/** A file or folder copied / cut in the explorer, waiting for Paste. */
let fileClip: { path: string; cut: boolean } | null = null

const sepOf = (p: string): string => (p.includes('\\') ? '\\' : '/')
const dirOf = (p: string): string => p.slice(0, Math.max(p.lastIndexOf('\\'), p.lastIndexOf('/')))
const refreshTree = (): void => {
  useStore.setState((s) => ({ fsTick: s.fsTick + 1 }))
  refreshGit()
}
/** Run a file operation; a failure shows its message instead of vanishing. */
const fsOp = (f: () => Promise<unknown>) => async (): Promise<void> => {
  try {
    await f()
  } catch (err) {
    window.alert(String(err))
  }
  refreshTree()
}

/** New file / folder in `dir`: an empty row opens there for its name (see NewEntryRow). */
const createIn = (dir: string, isDir: boolean): void => startRename(`new:${isDir ? 'dir' : 'file'}:${dir}`)

/** Create the file / folder named in a new row (files open in the editor). */
async function createNamed(dir: string, isDir: boolean, name: string): Promise<void> {
  const path = dir + sepOf(dir) + name
  await window.api.fs.create(path, isDir)
  if (!isDir) openFile(path)
}

/** The row a new file / folder's name is typed into, at the top of its folder. */
function NewEntryRow({ dir, isDir, depth }: { dir: string; isDir: boolean; depth: number }): React.JSX.Element {
  return (
    <div className="tree-row" style={{ paddingLeft: 10 + depth * 12 }}>
      <span className="chev-spacer" />
      {isDir ? <FolderIcon open={false} /> : <FilePlus size={14} />}
      <RenameInput value="" onCommit={(name) => fsOp(() => createNamed(dir, isDir, name))()} />
    </div>
  )
}

/** Editor tabs of `path`, or of files inside it when it's a folder. */
function tabsUnder(path: string): EditorTab[] {
  const lower = path.toLowerCase()
  return useStore.getState().tabs.filter((t) => t.kind === 'file' && (t.path.toLowerCase() === lower || t.path.toLowerCase().startsWith(lower + sepOf(path))))
}

/** Rename a file / folder in place; its open editor tabs follow it. */
async function renamePath(path: string, next: string): Promise<void> {
  const open = tabsUnder(path)
  if (open.some((t) => hasUnsaved(t.path)) && !(await window.api.ask(tr('Unsaved changes in the open file will be lost. Rename anyway?', 'Các thay đổi chưa lưu trong tệp đang mở sẽ bị mất. Vẫn đổi tên?')))) return
  const to = dirOf(path) + sepOf(path) + next
  await window.api.fs.rename(path, to)
  for (const t of open) closeTab(t.id)
  for (const t of open) openFile(to + t.path.slice(path.length))
}

/** Right-click on a file or folder in the explorer. */
function explorerMenu(e: React.MouseEvent, path: string, isDir: boolean, root: string): void {
  const isRoot = path === root
  const rel = path.slice(root.length).replace(/^[\\/]+/, '').replace(/\\/g, '/') || '.'
  const name = basename(path)
  const into = isDir ? path : dirOf(path)
  openMenu(e, [
    !isDir && { label: tr('Open', 'Mở'), icon: <FileText size={14} />, action: () => openFile(path) },
    { label: tr('New file', 'Tệp mới'), icon: <FilePlus size={14} />, action: () => createIn(into, false) },
    { label: tr('New folder', 'Thư mục mới'), icon: <FolderPlus size={14} />, action: () => createIn(into, true) },
    'sep',
    !isRoot && { label: tr('Cut', 'Cắt'), icon: <Scissors size={14} />, action: () => void (fileClip = { path, cut: true }) },
    !isRoot && { label: tr('Copy', 'Sao chép'), icon: <Copy size={14} />, action: () => void (fileClip = { path, cut: false }) },
    {
      label: tr('Paste', 'Dán'),
      icon: <ClipboardPaste size={14} />,
      hint: fileClip ? basename(fileClip.path) : undefined,
      // what was copied here first, else files copied in Windows Explorer
      action: fsOp(async () => {
        if (fileClip?.cut) {
          const to = into + sepOf(into) + basename(fileClip.path)
          if (to.toLowerCase() !== fileClip.path.toLowerCase()) await window.api.fs.rename(fileClip.path, to)
          fileClip = null
        } else if (fileClip) await window.api.fs.copy(fileClip.path, into)
        else for (const p of await window.api.app.clipboardFiles()) await window.api.fs.copy(p, into)
      })
    },
    !isRoot && { label: tr('Duplicate', 'Nhân bản'), icon: <CopyPlus size={14} />, action: fsOp(() => window.api.fs.copy(path, dirOf(path))) },
    'sep',
    !isRoot && {
      label: tr('Rename…', 'Đổi tên…'),
      icon: <Pencil size={14} />,
      action: () => startRename('file:' + path)
    },
    !isRoot && {
      label: tr('Delete', 'Xoá'),
      icon: <Trash2 size={14} />,
      hint: tr('to Recycle Bin', 'vào Thùng rác'),
      action: fsOp(async () => {
        const ask = tr(`Move ${isDir ? 'folder' : 'file'} "${name}" to the Recycle Bin?`, `Chuyển ${isDir ? 'thư mục' : 'tệp'} "${name}" vào Thùng rác?`)
        if (!(await window.api.ask(ask))) return
        await window.api.fs.trash(path)
        for (const t of tabsUnder(path)) closeTab(t.id)
      })
    },
    'sep',
    isDir
      ? { label: tr('Open folder in This PC', 'Mở thư mục trong This PC'), icon: <FolderOpen size={14} />, action: () => revealInApp(path, true) }
      : { label: tr('Reveal in This PC', 'Hiện trong This PC'), icon: <FolderOpen size={14} />, action: () => revealInApp(path, false) },
    { label: tr('Copy path', 'Sao chép đường dẫn'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(path) },
    { label: tr('Copy relative path', 'Sao chép đường dẫn tương đối'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(rel) }
  ])
}

const normDir = (p: string): string => p.replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase()

/** Parent folder of `p`, normalized like normDir. */
const parentOf = (p: string): string => {
  const n = normDir(p)
  return n.slice(0, Math.max(0, n.lastIndexOf('/')))
}

/** Re-renders when a file event touches something directly inside `dir` (not on every change anywhere). */
function useDirChanges(dir: string): number {
  const [n, setN] = useState(0)
  useEffect(() => {
    const key = normDir(dir)
    let timer: ReturnType<typeof setTimeout> | undefined
    const onChange = (e: Event): void => {
      const paths = (e as CustomEvent<string[]>).detail
      if (!paths.some((p) => parentOf(p) === key)) return
      clearTimeout(timer)
      timer = setTimeout(() => setN((x) => x + 1), 100)
    }
    window.addEventListener('fs-changed', onChange)
    return () => {
      clearTimeout(timer)
      window.removeEventListener('fs-changed', onChange)
    }
  }, [dir])
  return n
}

const sameEntries = (a: DirEntry[] | null, b: DirEntry[]): boolean =>
  !!a && a.length === b.length && a.every((x, i) => x.path === b[i].path && x.isDir === b[i].isDir && x.name === b[i].name)

function DirChildren({ dir, depth, deco, openCtx }: { dir: string; depth: number; deco: Map<string, string>; openCtx: OpenCtx }): React.JSX.Element {
  const [items, setItems] = useState<DirEntry[] | null>(null)
  // the Refresh button bumps fsTick; file events only reach the folders they touch
  const tick = useStore((s) => s.fsTick)
  const changed = useDirChanges(dir)
  const creating = useRenaming((r) => (r.key === `new:file:${dir}` ? 'file' : r.key === `new:dir:${dir}` ? 'dir' : null))
  useEffect(() => {
    let live = true
    window.api.fs
      .readDir(dir)
      .then((r) => live && setItems((prev) => (sameEntries(prev, r) ? prev : r)))
      .catch(() => live && setItems([]))
    return () => {
      live = false
    }
  }, [dir, tick, changed])
  if (!items) return <div className="tree-loading" style={{ paddingLeft: 12 + depth * 12 }} />
  return (
    <>
      {creating && <NewEntryRow dir={dir} isDir={creating === 'dir'} depth={depth} />}
      {items.map((it) => (
        <TreeNode key={it.path} item={it} depth={depth} deco={deco} openCtx={openCtx} />
      ))}
    </>
  )
}

const TreeNode = memo(function TreeNode({ item, depth, deco, openCtx }: { item: DirEntry; depth: number; deco: Map<string, string>; openCtx: OpenCtx }): React.JSX.Element {
  const [open, setOpen] = useState(false)
  // a boolean: re-renders only when this row starts / stops being the open file
  const isActive = useStore((s) => s.activeTabId === 'f:' + item.path.toLowerCase())
  const status = deco.get(item.path.replace(/\\/g, '/').toLowerCase())
  const renaming = useRenaming((r) => r.key === 'file:' + item.path)
  // New file / folder inside it: open it so the name row shows
  const creatingIn = useRenaming((r) => r.key === 'new:file:' + item.path || r.key === 'new:dir:' + item.path)
  useEffect(() => {
    if (creatingIn) setOpen(true)
  }, [creatingIn])
  return (
    <>
      <div
        className={`tree-row${isActive ? ' active' : ''}${status ? ` git-${status === '?' ? 'U' : status}` : ''}`}
        style={{ paddingLeft: 10 + depth * 12 }}
        onClick={() => (item.isDir ? setOpen(!open) : openFile(item.path))}
        onContextMenu={(e) => openCtx(e, item.path, item.isDir)}
        title={item.path}
      >
        {item.isDir ? (
          <ChevronRight size={13} className={`chev${open ? ' open' : ''}`} />
        ) : (
          <span className="chev-spacer" />
        )}
        {item.isDir ? <FolderIcon open={open} /> : <FileIcon name={item.name} />}
        {renaming ? (
          <RenameInput value={item.name} stem={!item.isDir} onCommit={(next) => fsOp(() => renamePath(item.path, next))()} />
        ) : (
          <span className="tree-name">{item.name}</span>
        )}
        {status && !item.isDir && <span className="tree-status">{status === '?' ? 'U' : status}</span>}
        {status && item.isDir && <span className="tree-dot" />}
      </div>
      {item.isDir && open && <DirChildren dir={item.path} depth={depth + 1} deco={deco} openCtx={openCtx} />}
    </>
  )
})

/* ================================ Changes ================================ */

/** Discard (undo) the uncommitted changes of `files`, after asking. */
async function discard(files: GitFile[], root: string): Promise<void> {
  const what = files.length === 1 ? `"${files[0].rel}"` : tr(`all ${files.length} changed files`, `tất cả ${files.length} tệp đã thay đổi`)
  const gone = files.some((f) => f.status === '?' || f.status === 'A')
  const ask = tr(
    `Discard changes to ${what}?${gone ? '\nNew files will be deleted.' : ''}\nThis can't be undone.`,
    `Huỷ thay đổi của ${what}?${gone ? '\nCác tệp mới sẽ bị xoá.' : ''}\nKhông thể hoàn tác.`
  )
  if (!(await window.api.ask(ask))) return
  if (files.some((f) => hasUnsaved(f.abs)) && !(await window.api.ask(tr('A file with unsaved edits in the editor is included. Discard anyway?', 'Có một tệp đang có chỉnh sửa chưa lưu trong trình soạn thảo. Vẫn huỷ thay đổi?')))) return
  const failed: string[] = []
  for (const f of files) await window.api.git.discard(root, f.rel, f.status).catch((err) => failed.push(`${f.rel}: ${err}`))
  refreshGit()
  useStore.setState((s) => ({ fsTick: s.fsTick + 1 }))
  if (failed.length) window.alert(tr(`Couldn't discard:\n${failed.join('\n')}`, `Không huỷ thay đổi được:\n${failed.join('\n')}`))
}

/** Right-click on a changed file under Changes. */
function changeMenu(e: React.MouseEvent, f: GitFile, root: string): void {
  const all = useStore.getState().git.files
  openMenu(e, [
    { label: tr('Open changes', 'Mở thay đổi'), icon: <FileDiff size={14} />, action: () => openDiff(f.abs, f.rel) },
    f.status !== 'D' && { label: tr('Open file', 'Mở tệp'), icon: <FileText size={14} />, action: () => openFile(f.abs) },
    'sep',
    { label: tr('Discard changes', 'Huỷ thay đổi'), icon: <Undo2 size={14} />, action: () => discard([f], root) },
    all.length > 1 && { label: tr('Discard all changes…', 'Huỷ tất cả thay đổi…'), icon: <Undo2 size={14} />, action: () => discard(all, root) },
    'sep',
    { label: tr('Copy path', 'Sao chép đường dẫn'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(f.abs) },
    { label: tr('Copy relative path', 'Sao chép đường dẫn tương đối'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(f.rel) },
    f.status !== 'D' && { label: tr('Reveal in This PC', 'Hiện trong This PC'), icon: <FolderOpen size={14} />, action: () => revealInApp(f.abs, false) }
  ])
}

const statusName = (t: T): Record<string, string> => ({
  M: t('Modified', 'Đã sửa'),
  A: t('Added', 'Đã thêm'),
  D: t('Deleted', 'Đã xoá'),
  R: t('Renamed', 'Đã đổi tên'),
  U: t('Conflict', 'Xung đột'),
  '?': t('Untracked', 'Chưa theo dõi'),
  C: t('Copied', 'Đã sao chép')
})

export function ChangesView(): React.JSX.Element {
  const t = useT()
  const git = useStore((s) => s.git)
  const root = useStore((s) => s.root)!
  const activeTabId = useStore((s) => s.activeTabId)
  const totals = git.files.reduce((a, f) => ({ add: a.add + f.added, del: a.del + f.deleted }), { add: 0, del: 0 })

  if (!git.isRepo) {
    return (
      <>
        <SectionHeader title={t('Changes', 'Thay đổi')} />
        <div className="empty-state-small">
          <FolderGit2 size={30} strokeWidth={1.4} />
          <h4>{t('Not a Git repository', 'Không phải kho Git')}</h4>
          <p>{t('Initialize Git to see exactly what Claude changes, file by file.', 'Khởi tạo Git để xem chính xác Claude thay đổi gì, từng tệp một.')}</p>
          <button
            className="btn btn-primary"
            onClick={async () => {
              await window.api.git.init(root)
              refreshGit()
            }}
          >
            {t('Initialize repository', 'Khởi tạo kho')}
          </button>
        </div>
      </>
    )
  }

  return (
    <>
      <SectionHeader title={t('Changes', 'Thay đổi')}>
        <button className="icon-btn" title={t('Refresh', 'Tải lại')} onClick={() => refreshGit()}>
          <RefreshCw size={14} />
        </button>
      </SectionHeader>
      <div className="changes-summary">
        <BranchPicker root={git.root ?? root} branch={git.branch ?? ''} />
        <div className="changes-counts">
          <span>{t(`${git.files.length} ${git.files.length === 1 ? 'file' : 'files'}`, `${git.files.length} tệp`)}</span>
          <span className="add">+{totals.add}</span>
          <span className="del">−{totals.del}</span>
        </div>
      </div>
      <CommitBox root={git.root ?? root} />
      <div className="scroll">
        {git.files.length === 0 && (
          <div className="empty-hint">
            <Sparkles size={18} />
            <p>{t('Working tree clean. Changes Claude makes will show up here instantly.', 'Không có thay đổi. Những thay đổi Claude tạo ra sẽ hiện ở đây ngay lập tức.')}</p>
          </div>
        )}
        {git.files.map((f) => {
          const name = f.rel.split('/').pop()!
          const dir = f.rel.slice(0, -name.length - 1)
          const st = f.status === '?' ? 'U' : f.status
          const active = activeTabId === 'd:' + f.abs.toLowerCase()
          return (
            <div
              key={f.rel}
              className={`change-row${active ? ' active' : ''}`}
              onClick={() => openDiff(f.abs, f.rel)}
              onContextMenu={(e) => changeMenu(e, f, git.root ?? root)}
              title={`${statusName(t)[f.status]} — ${f.rel}`}
            >
              <input
                type="checkbox"
                className="change-stage"
                checked={f.staged}
                title={
                  f.staged
                    ? t('Staged: will be committed. Click to unstage', 'Đã stage: sẽ được commit. Bấm để unstage')
                    : t('Stage: commit only the ticked files (none ticked = commit all)', 'Stage: chỉ commit các tệp được đánh dấu (không đánh dấu tệp nào = commit tất cả)')
                }
                onClick={(e) => e.stopPropagation()}
                onChange={() => void stageFiles(git.root ?? root, [f.rel], !f.staged)}
              />
              <FileIcon name={name} />
              <span className={`change-name${f.status === 'D' ? ' deleted' : ''}`}>{name}</span>
              <span className="change-dir">{dir}</span>
              <span className="change-stats">
                {f.added > 0 && <span className="add">+{f.added}</span>}
                {f.deleted > 0 && <span className="del">−{f.deleted}</span>}
              </span>
              {f.status !== 'D' && (
                <button
                  className="icon-btn change-open"
                  title={t('Open file', 'Mở tệp')}
                  onClick={(e) => {
                    e.stopPropagation()
                    openFile(f.abs)
                  }}
                >
                  <ExternalLink size={13} />
                </button>
              )}
              <span className={`change-badge git-${st}`}>{st}</span>
            </div>
          )
        })}
        <HistoryList />
      </div>
    </>
  )
}

async function stageFiles(root: string, rels: string[], stage: boolean): Promise<void> {
  await window.api.git.stage(root, rels, stage).catch((e) => window.alert(tr(`Couldn't ${stage ? 'stage' : 'unstage'}:\n${e}`, `Không ${stage ? 'stage' : 'unstage'} được:\n${e}`)))
  refreshGit()
}

/** Commit message per repository, kept while you switch views. */
const commitDrafts = new Map<string, string>()

/** Message + Commit (staged files, or all when none are staged), then Pull / Push. */
function CommitBox({ root }: { root: string }): React.JSX.Element {
  const t = useT()
  const git = useStore((s) => s.git)
  const [msg, setMsg] = useState(() => commitDrafts.get(root) ?? '')
  const [busy, setBusy] = useState<'commit' | 'pull' | 'push' | null>(null)
  const [error, setError] = useState('')
  useEffect(() => setMsg(commitDrafts.get(root) ?? ''), [root])
  const edit = (v: string): void => {
    commitDrafts.set(root, v)
    setMsg(v)
  }
  const staged = git.files.filter((f) => f.staged).length
  const canCommit = !busy && msg.trim().length > 0 && git.files.length > 0
  const publish = !git.upstream
  const run = async (kind: 'commit' | 'pull' | 'push', f: () => Promise<void>): Promise<boolean> => {
    setBusy(kind)
    setError('')
    try {
      await f()
      return true
    } catch (e) {
      // git's own words: hook output, "diverged", "rejected", auth failures…
      setError(e instanceof Error ? e.message : String(e))
      return false
    } finally {
      setBusy(null)
      refreshGit()
    }
  }
  const commit = async (): Promise<void> => {
    if (!canCommit) return
    if (await run('commit', () => window.api.git.commit(root, msg.trim()))) edit('')
  }

  return (
    <div className="commit-box">
      <textarea
        className="commit-msg"
        rows={2}
        placeholder={t(`Message (Ctrl+Enter to commit on ${git.branch ?? 'HEAD'})`, `Thông điệp (Ctrl+Enter để commit lên ${git.branch ?? 'HEAD'})`)}
        value={msg}
        onChange={(e) => edit(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
            e.preventDefault()
            void commit()
          }
        }}
      />
      <div className="commit-actions">
        <button
          className="btn btn-primary btn-sm commit-btn"
          disabled={!canCommit}
          title={
            git.files.length === 0
              ? t('Nothing to commit', 'Không có gì để commit')
              : staged
                ? t(`Commit the ${staged} ticked ${staged === 1 ? 'file' : 'files'}`, `Commit ${staged} tệp đã đánh dấu`)
                : t('Commit all changes', 'Commit tất cả thay đổi')
          }
          onClick={() => void commit()}
        >
          {busy === 'commit' ? <Loader2 size={13} className="spin" /> : <Check size={13} />}
          {staged ? t(`Commit ${staged} staged`, `Commit ${staged} tệp đã stage`) : t('Commit all', 'Commit tất cả')}
        </button>
        {git.hasRemote && (
          <>
            <button
              className="btn btn-ghost btn-sm"
              disabled={!!busy || publish}
              title={
                publish
                  ? t('This branch is not on the remote yet', 'Nhánh này chưa có trên remote')
                  : t(
                      `Pull from ${git.upstream} (fast-forward only: your local work is never merged or overwritten)`,
                      `Pull từ ${git.upstream} (chỉ fast-forward: công việc cục bộ của bạn không bao giờ bị merge hay ghi đè)`
                    )
              }
              onClick={() => void run('pull', () => window.api.git.pull(root))}
            >
              {busy === 'pull' ? <Loader2 size={13} className="spin" /> : <ArrowDown size={13} />}
              {git.behind ? git.behind : null}
            </button>
            <button
              className="btn btn-ghost btn-sm"
              disabled={!!busy || (!publish && !git.ahead)}
              title={
                publish
                  ? t(`Publish ${git.branch} to the remote`, `Publish ${git.branch} lên remote`)
                  : git.ahead
                    ? t(`Push ${git.ahead} ${git.ahead === 1 ? 'commit' : 'commits'} to ${git.upstream}`, `Push ${git.ahead} commit lên ${git.upstream}`)
                    : t('Nothing to push', 'Không có gì để push')
              }
              onClick={() => void run('push', () => window.api.git.push(root))}
            >
              {busy === 'push' ? <Loader2 size={13} className="spin" /> : publish ? <CloudUpload size={13} /> : <ArrowUp size={13} />}
              {publish ? 'Publish' : git.ahead ? git.ahead : null}
            </button>
          </>
        )}
      </div>
      {error && <div className="branch-error">{error}</div>}
    </div>
  )
}

/** The current branch; click to switch to another one (remote-only branches get a local copy). */
function BranchPicker({ root, branch }: { root: string; branch: string }): React.JSX.Element {
  const t = useT()
  const [open, setOpen] = useState(false)
  const [list, setList] = useState<GitBranchInfo[] | null>(null)
  const [q, setQ] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState('')
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    setQ('')
    setError('')
    setList(null)
    let live = true
    window.api.git
      .branches(root)
      .then((b) => live && setList(b))
      .catch((e) => live && setError(String(e)))
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      live = false
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [open, root])

  const needle = q.trim().toLowerCase()
  const shown = (list ?? []).filter((b) => b.name.toLowerCase().includes(needle))
  const pick = async (b: GitBranchInfo): Promise<void> => {
    if (busy) return
    if (b.current) return setOpen(false)
    setBusy(b.name)
    setError('')
    try {
      await window.api.git.checkout(root, b.name, b.remote)
      setOpen(false)
      refreshGit()
    } catch (e) {
      // e.g. uncommitted changes that the other branch would overwrite: git's own words
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="branch-picker" ref={ref}>
      <button className={`changes-branch${open ? ' open' : ''}`} title={t('Switch branch', 'Chuyển nhánh')} onClick={() => setOpen(!open)}>
        <GitBranch size={13} />
        <span className="branch-name">{branch}</span>
        <ChevronDown size={12} className="branch-caret" />
      </button>
      {open && (
        <div className="branch-menu" role="menu">
          <input
            className="branch-filter"
            autoFocus
            placeholder={t('Find a branch…', 'Tìm nhánh…')}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && shown[0] && void pick(shown[0])}
          />
          <div className="branch-list">
            {!list && !error && (
              <div className="branch-note">
                <Loader2 size={12} className="spin" /> {t('Loading…', 'Đang tải…')}
              </div>
            )}
            {list && !shown.length && <div className="branch-note">{t('No branch matches.', 'Không có nhánh nào khớp.')}</div>}
            {shown.map((b) => (
              <button
                key={(b.remote ? 'r:' : 'l:') + b.name}
                role="menuitemradio"
                aria-checked={b.current}
                className={`branch-item${b.current ? ' on' : ''}`}
                disabled={!!busy}
                title={b.remote ? t(`Check out ${b.name} as a local branch`, `Check out ${b.name} thành nhánh cục bộ`) : t(`Switch to ${b.name}`, `Chuyển sang ${b.name}`)}
                onClick={() => void pick(b)}
              >
                {busy === b.name ? <Loader2 size={13} className="spin" /> : <Check size={13} className="branch-check" />}
                <span className="branch-item-name">{b.name}</span>
                {b.remote && <span className="branch-hint">remote</span>}
              </button>
            ))}
          </div>
          {error && <div className="branch-error">{error}</div>}
        </div>
      )}
    </div>
  )
}

/* ================================ History ================================ */

/** Commits on the current branch, newest first; click one to see the files it touched. */
function HistoryList(): React.JSX.Element | null {
  const t = useT()
  const gitRoot = useStore((s) => s.git.root)
  const branch = useStore((s) => s.git.branch)
  const [commits, setCommits] = useState<GitCommit[] | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  // a commit / pull / checkout moves HEAD or a ref even when the working tree status stays the same
  const [refs, setRefs] = useState(0)
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const onChange = (): void => {
      clearTimeout(timer)
      timer = setTimeout(() => setRefs((n) => n + 1), 300)
    }
    window.addEventListener('git-changed', onChange)
    return () => {
      clearTimeout(timer)
      window.removeEventListener('git-changed', onChange)
    }
  }, [])

  // refetch when HEAD / a ref moves (new commits, checkout, pull…), not on every working-tree change
  useEffect(() => {
    if (!gitRoot) return
    let live = true
    window.api.git.log(gitRoot).then((c) => live && setCommits(c))
    return () => {
      live = false
    }
  }, [gitRoot, branch, refs])

  if (!gitRoot || !commits) return null
  return (
    <>
      <SectionHeader title={`${t('History', 'Lịch sử')}${commits.length ? ` · ${commits.length}` : ''}`} />
      {commits.length === 0 && <div className="history-empty">{t('No commits yet.', 'Chưa có commit nào.')}</div>}
      {commits.map((c) => (
        <CommitRow key={c.hash} commit={c} gitRoot={gitRoot} open={open === c.hash} toggle={() => setOpen((o) => (o === c.hash ? null : c.hash))} />
      ))}
    </>
  )
}

function CommitRow({ commit, gitRoot, open, toggle }: { commit: GitCommit; gitRoot: string; open: boolean; toggle: () => void }): React.JSX.Element {
  const t = useT()
  const [files, setFiles] = useState<GitCommitFile[] | null>(null)
  const activeTabId = useStore((s) => s.activeTabId)
  useEffect(() => {
    if (!open || files) return
    let live = true
    window.api.git.commitFiles(gitRoot, commit.hash).then((f) => live && setFiles(f))
    return () => {
      live = false
    }
  }, [open, files, gitRoot, commit.hash])

  return (
    <>
      <div
        className={`commit-row${open ? ' open' : ''}`}
        onClick={toggle}
        title={`${commit.subject}\n${commit.short} · ${commit.author} · ${new Date(commit.date).toLocaleString(t('en-US', 'vi-VN'))}`}
      >
        <ChevronRight size={12} className={`chev${open ? ' open' : ''}`} />
        <GitCommitHorizontal size={13} className="commit-icon" />
        <div className="commit-text">
          <span className="commit-subject">{commit.subject}</span>
          <span className="commit-meta">
            <span className="commit-hash">{commit.short}</span> · {commit.author} · <Ago t={commit.date} />
          </span>
        </div>
      </div>
      {open && !files && <div className="tree-loading" />}
      {open && files?.length === 0 && <div className="history-empty">{t('No file changes.', 'Không có thay đổi tệp nào.')}</div>}
      {open &&
        files?.map((f) => {
          const name = f.rel.split('/').pop()!
          const dir = f.rel.slice(0, -name.length - 1)
          const active = activeTabId === `c:${commit.hash}:${f.rel}`
          return (
            <div
              key={f.rel}
              className={`change-row commit-file${active ? ' active' : ''}`}
              onClick={() => openCommitDiff(gitRoot, commit, f.rel)}
              title={`${statusName(t)[f.status]} — ${f.rel}`}
            >
              <FileIcon name={name} />
              <span className={`change-name${f.status === 'D' ? ' deleted' : ''}`}>{name}</span>
              <span className="change-dir">{dir}</span>
              <span className="change-stats">
                {f.added > 0 && <span className="add">+{f.added}</span>}
                {f.deleted > 0 && <span className="del">−{f.deleted}</span>}
              </span>
              <span className={`change-badge git-${f.status}`}>{f.status}</span>
            </div>
          )
        })}
    </>
  )
}
