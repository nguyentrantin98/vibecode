import { Suspense, lazy, memo, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { Group, Panel, Separator, useDefaultLayout } from 'react-resizable-panels'
import { Code2, Columns2, Copy, Database, ExternalLink, FileDiff, FileSpreadsheet, FolderOpen, Rows2, X, Command, GitCompare, Globe, Mail, MessageCircle, MessageSquarePlus, Plus, Search } from 'lucide-react'
import { fileUri, useStore, type EditorTab } from '../store'
import { HOME_URL, browserKey, closeBrowserTab, closeTab, newBrowserTab, openBrowser, openFile, revealInApp, selectBrowserTab } from '../actions'
import { BrowserTab } from './Browser'
import { SlidePill } from './motion'
import { openMenu } from './ContextMenu'
import { ChangesView, ExplorerView } from './Sidebar'
import { FileIcon, Logo } from './icons'
import { SourceSwitch } from './SourceSwitch'
import { EditorFontButton } from './EditorFont'
import { EditorExtensionsButton } from './EditorExtensions'
// heavy parts load on first use: Monaco (~4 MB) only when a file or diff opens
const FileEditor = lazy(() => import('./MonacoViews').then((m) => ({ default: m.FileEditor })))
const DiffView = lazy(() => import('./MonacoViews').then((m) => ({ default: m.DiffView })))
const FileExplorerPane = lazy(() => import('./FileExplorer').then((m) => ({ default: m.FileExplorerPane })))
const DbxPane = lazy(() => import('./Dbx').then((m) => ({ default: m.DbxPane })))
const ZaloPane = lazy(() => import('./Zalo').then((m) => ({ default: m.ZaloPane })))
const GmailPane = lazy(() => import('./Gmail').then((m) => ({ default: m.GmailPane })))
const OfficePane = lazy(() => import('./Office').then((m) => ({ default: m.OfficePane })))
import type { ZaloTasksState } from '../../../shared/types'
import { revealIn } from '../scroll'
import { tr, useT } from '../i18n'

/**
 * The center tabs, as icons in the title bar: Source code (project files, diffs, and This PC: any
 * file on the computer), Web (built-in browser), dbX (DBX, databases), Zalo, Gmail, Office.
 */
export function CenterTabs(): React.JSX.Element {
  const t = useT()
  const view = useStore((s) => s.centerView)
  const fileCount = useStore((s) => s.tabs.length)
  // Source code holds two views (the project / This PC): its tab brings back the one used last
  const lastSource = useRef<'code' | 'files'>('code')
  useEffect(() => {
    if (view === 'code' || view === 'files') lastSource.current = view
  }, [view])
  const zaloBadge = useZaloBadge(view === 'zalo')
  return (
    <div className="center-switch" role="tablist">
      <SlidePill />
      <button
        role="tab"
        aria-selected={view === 'code' || view === 'files'}
        className={view === 'code' || view === 'files' ? 'on' : ''}
        title={t('Source code: project files, Git changes and This PC (Ctrl+1)', 'Mã nguồn: tệp dự án, thay đổi Git và This PC (Ctrl+1)')}
        onClick={() => useStore.setState({ centerView: lastSource.current })}
      >
        <Code2 size={15} />
        {fileCount > 0 && <span className="center-count">{fileCount}</span>}
      </button>
      <button role="tab" aria-selected={view === 'web'} className={view === 'web' ? 'on' : ''} title="Web (Ctrl+2)" onClick={() => openBrowser()}>
        <Globe size={15} />
      </button>
      <button role="tab" aria-selected={view === 'db'} className={view === 'db' ? 'on' : ''} title="dbX (Ctrl+3)" onClick={() => useStore.setState({ centerView: 'db' })}>
        <Database size={15} />
      </button>
      <button role="tab" aria-selected={view === 'zalo'} className={view === 'zalo' ? 'on' : ''} title="Zalo (Ctrl+4)" onClick={() => useStore.setState({ centerView: 'zalo' })}>
        <MessageCircle size={15} />
        {zaloBadge > 0 && (
          <span key={zaloBadge} className="center-count alert" title={t(`${zaloBadge} new / updated ${zaloBadge === 1 ? 'task' : 'tasks'}`, `${zaloBadge} việc mới / vừa cập nhật`)}>
            {zaloBadge > 99 ? '99+' : zaloBadge}
          </span>
        )}
      </button>
      <button role="tab" aria-selected={view === 'gmail'} className={view === 'gmail' ? 'on' : ''} title="Gmail (Ctrl+5)" onClick={() => useStore.setState({ centerView: 'gmail' })}>
        <Mail size={15} />
      </button>
      <button role="tab" aria-selected={view === 'office'} className={view === 'office' ? 'on' : ''} title="Office (Ctrl+6)" onClick={() => useStore.setState({ centerView: 'office' })}>
        <FileSpreadsheet size={15} />
      </button>
    </div>
  )
}

/** The pane of the open center tab. */
export function EditorArea(): React.JSX.Element {
  const view = useStore((s) => s.centerView)
  const key = useStore((s) => browserKey(s.activeChatId))
  const browsers = useStore((s) => s.browsers)
  // the dbX tab mounts on first visit, then stays (DBX keeps its page)
  const [filesSeen, setFilesSeen] = useState(view === 'files')
  const [dbSeen, setDbSeen] = useState(view === 'db')
  const [zaloSeen, setZaloSeen] = useState(view === 'zalo')
  const [gmailSeen, setGmailSeen] = useState(view === 'gmail')
  const [officeSeen, setOfficeSeen] = useState(view === 'office')
  useEffect(() => {
    if (view === 'files') setFilesSeen(true)
    if (view === 'db') setDbSeen(true)
    if (view === 'zalo') setZaloSeen(true)
    if (view === 'gmail') setGmailSeen(true)
    if (view === 'office') setOfficeSeen(true)
  }, [view])
  // switching chats while on Web: give that chat its own browser (before paint: no empty frame)
  useLayoutEffect(() => {
    if (view === 'web' && !browsers[key]) openBrowser()
  }, [view, key, browsers])
  return (
    <div className="center-area">
      {/*
        Panes stay mounted and laid out; only the open one (`on`) is visible. display:none would drop
        their scroll positions, make Monaco re-measure on return and replay every animation inside.
      */}
      {/* Source code: the whole project of the open chat — file tree on the left, files on the right */}
      <div className={`center-pane code-pane${view === 'code' ? ' on' : ''}`}>
        <CodeSide />
        <CodeArea />
      </div>
      {filesSeen && (
        <div className={`center-pane fx-host${view === 'files' ? ' on' : ''}`}>
          <Suspense fallback={null}>
            <FileExplorerPane />
          </Suspense>
        </div>
      )}
      {dbSeen && (
        <div className={`center-pane dbx-host${view === 'db' ? ' on' : ''}`}>
          <Suspense fallback={null}>
            <DbxPane />
          </Suspense>
        </div>
      )}
      {zaloSeen && (
        <div className={`center-pane zalo-host${view === 'zalo' ? ' on' : ''}`}>
          <Suspense fallback={null}>
            <ZaloPane />
          </Suspense>
        </div>
      )}
      {gmailSeen && (
        <div className={`center-pane gmail-host${view === 'gmail' ? ' on' : ''}`}>
          <Suspense fallback={null}>
            <GmailPane />
          </Suspense>
        </div>
      )}
      {officeSeen && (
        <div className={`center-pane office-host${view === 'office' ? ' on' : ''}`}>
          <Suspense fallback={null}>
            <OfficePane />
          </Suspense>
        </div>
      )}
      {/* one browser per chat, every tab kept alive so pages survive switching */}
      {Object.keys(browsers).map((k) => (
        <div key={k} className={`center-pane browser-host${view === 'web' && k === key ? ' on' : ''}`}>
          <WebTabs chatKey={k} />
        </div>
      ))}
    </div>
  )
}

/**
 * Zalo tab badge: tasks Claude created or changed that I haven't looked at.
 * Also tells main when the tab is on screen in a focused window (that clears the badge, and skips pop-ups).
 */
function useZaloBadge(onTab: boolean): number {
  const [n, setN] = useState(0)
  useEffect(() => {
    const count = (s: ZaloTasksState): void => {
      setN(Object.keys(s.unseen ?? {}).length)
      taskbarBadge(s.tasks.filter((t) => t.status !== 'done').length)
    }
    void window.api.zalo.tasks().then(count)
    return window.api.zalo.onTasks(count)
  }, [])
  useEffect(() => {
    const send = (): void => window.api.zalo.tasksViewing(onTab && document.hasFocus() && !document.hidden)
    send()
    window.addEventListener('focus', send)
    window.addEventListener('blur', send)
    document.addEventListener('visibilitychange', send)
    return () => {
      window.removeEventListener('focus', send)
      window.removeEventListener('blur', send)
      document.removeEventListener('visibilitychange', send)
    }
  }, [onTab])
  return n
}

/** Red number over the app's taskbar icon: my unfinished Zalo tasks. */
let lastBadge = -1
function taskbarBadge(n: number): void {
  if (n === lastBadge) return
  lastBadge = n
  if (n <= 0) return window.api.win.badge(null, '')
  const c = document.createElement('canvas')
  c.width = c.height = 32
  const g = c.getContext('2d')
  if (!g) return
  g.fillStyle = '#e5484d'
  g.beginPath()
  g.arc(16, 16, 16, 0, Math.PI * 2)
  g.fill()
  const text = n > 99 ? '99+' : String(n)
  g.fillStyle = '#fff'
  g.font = `bold ${text.length > 2 ? 13 : text.length > 1 ? 18 : 22}px "Segoe UI", sans-serif`
  g.textAlign = 'center'
  g.textBaseline = 'middle'
  g.fillText(text, 16, 17)
  window.api.win.badge(c.toDataURL('image/png'), tr(`${n} unfinished ${n === 1 ? 'task' : 'tasks'}`, `${n} việc chưa xong`))
}

/** A chat's browser: its tab strip and one page per tab. */
function WebTabs({ chatKey }: { chatKey: string }): React.JSX.Element | null {
  const tt = useT()
  const b = useStore((s) => s.browsers[chatKey])
  const shown = useStore((s) => s.centerView === 'web' && browserKey(s.activeChatId) === chatKey)
  const stripRef = useRef<HTMLDivElement>(null)
  // tabs on their way out: they shrink away first, then really close
  const [closing, setClosing] = useState<Set<string>>(new Set())
  const close = (id: string): void => {
    if (closing.has(id)) return
    setClosing((c) => new Set(c).add(id))
    setTimeout(() => {
      closeBrowserTab(chatKey, id)
      setClosing((c) => {
        const n = new Set(c)
        n.delete(id)
        return n
      })
    }, 200)
  }

  useEffect(() => {
    revealIn(stripRef.current, stripRef.current?.querySelector('.tab.active'), { inline: 'nearest', smooth: true })
  }, [b?.active, b?.tabs.length])

  if (!b) return null
  const activeIdx = b.tabs.findIndex((t) => t.id === b.active)
  return (
    <>
      <div className="tab-strip web-tab-strip" ref={stripRef} onWheel={(e) => (e.currentTarget.scrollLeft += e.deltaY)}>
        <SlidePill className="tab-pill" />
        {b.tabs.map((t) => (
          <div
            key={t.id}
            className={`tab${t.id === b.active ? ' active' : ''}${closing.has(t.id) ? ' closing' : ''}`}
            onClick={() => selectBrowserTab(chatKey, t.id)}
            onContextMenu={(e) =>
              openMenu(e, [
                { label: tt('Close tab', 'Đóng tab'), icon: <X size={14} />, action: () => close(t.id) },
                b.tabs.length > 1 && { label: tt('Close other tabs', 'Đóng các tab khác'), action: () => b.tabs.forEach((o) => o.id !== t.id && close(o.id)) },
                t.url !== HOME_URL && 'sep',
                t.url !== HOME_URL && { label: tt('Copy address', 'Sao chép địa chỉ'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(t.url) },
                t.url !== HOME_URL && { label: tt('Open in default browser', 'Mở bằng trình duyệt mặc định'), icon: <ExternalLink size={14} />, action: () => window.api.app.openExternal(t.url) }
              ])
            }
            onMouseDown={(e) => {
              if (e.button === 1) {
                e.preventDefault()
                close(t.id)
              }
            }}
            title={t.url === HOME_URL ? tt('New tab', 'Tab mới') : t.url}
          >
            <Globe size={13} />
            <span className="tab-title">{t.title || (t.url === HOME_URL ? tt('New tab', 'Tab mới') : t.url.replace(/^https?:\/\//, ''))}</span>
            <button
              className="tab-close"
              title={tt('Close tab', 'Đóng tab')}
              onClick={(e) => {
                e.stopPropagation()
                close(t.id)
              }}
            >
              <X size={13} />
            </button>
          </div>
        ))}
        <button className="icon-btn tab-strip-btn" title={tt('New tab', 'Tab mới')} onClick={() => newBrowserTab(chatKey)}>
          <Plus size={15} />
        </button>
        <div className="tab-strip-fill" />
      </div>
      {/* every page stays laid out (no display:none → no re-layout flash); the open one slides in */}
      <div className="browser-deck">
        {b.tabs.map((t, i) => (
          <div key={t.id} className={`browser-tab-pane ${i === activeIdx ? 'on' : i < activeIdx ? 'left' : 'right'}`}>
            <BrowserTab chatKey={chatKey} tabId={t.id} active={t.id === b.active} onScreen={shown} />
          </div>
        ))}
      </div>
    </>
  )
}

// a panel's own box scrolls by default: let the tree / change list inside do it (header and commit box stay put)
const partStyle = { overflow: 'hidden', display: 'flex', flexDirection: 'column' } as const

/** Left column of Source code: the project's files on top, its Git changes below (click one for the diff). */
// memo (no props): EditorArea re-renders whenever any web page changes its address or title
const CodeSide = memo(function CodeSide(): React.JSX.Element {
  const hasRoot = useStore((s) => !!s.root)
  const folded = useStore((s) => s.sourceFolded)
  const split = useDefaultLayout({ id: 'vibe-code-side-split', storage: localStorage })
  return (
    <div className={`sidebar code-tree${folded ? ' folded' : ''}`}>
      <SourceSwitch />
      {hasRoot && (
        <Group orientation="vertical" className="code-side-split" defaultLayout={split.defaultLayout} onLayoutChanged={split.onLayoutChanged}>
          <Panel id="files" defaultSize="55%" minSize="15%" className="code-side-part" style={partStyle}>
            <ExplorerView />
          </Panel>
          <Separator className="code-side-resize" />
          <Panel id="changes" minSize="15%" className="code-side-part" style={partStyle}>
            <ChangesView />
          </Panel>
        </Group>
      )}
    </div>
  )
})

/** Right-click on an editor tab. */
function tabMenu(e: React.MouseEvent, t: EditorTab): void {
  const { tabs, root } = useStore.getState()
  const others = tabs.filter((x) => x.id !== t.id)
  const right = tabs.slice(tabs.findIndex((x) => x.id === t.id) + 1)
  const rel = t.kind === 'diff' ? t.rel : root && t.path.toLowerCase().startsWith(root.toLowerCase()) ? t.path.slice(root.length).replace(/^[\\/]+/, '').replace(/\\/g, '/') : null
  openMenu(e, [
    { label: tr('Close', 'Đóng'), icon: <X size={14} />, hint: 'Ctrl+W', action: () => closeTab(t.id) },
    others.length > 0 && { label: tr('Close others', 'Đóng các tab khác'), action: () => others.forEach((x) => closeTab(x.id)) },
    right.length > 0 && { label: tr('Close to the right', 'Đóng các tab bên phải'), action: () => right.forEach((x) => closeTab(x.id)) },
    others.length > 0 && { label: tr('Close all', 'Đóng tất cả'), action: () => tabs.forEach((x) => closeTab(x.id)) },
    'sep',
    { label: tr('Copy path', 'Sao chép đường dẫn'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(t.path) },
    !!rel && { label: tr('Copy relative path', 'Sao chép đường dẫn tương đối'), icon: <Copy size={14} />, action: () => navigator.clipboard.writeText(rel) },
    { label: tr('Reveal in This PC', 'Hiện trong This PC'), icon: <FolderOpen size={14} />, action: () => revealInApp(t.path, false) }
  ])
}

const CodeArea = memo(function CodeArea(): React.JSX.Element {
  const tabs = useStore((s) => s.tabs)
  const activeId = useStore((s) => s.activeTabId)
  const active = tabs.find((t) => t.id === activeId) ?? null
  const stripRef = useRef<HTMLDivElement>(null)
  // The file editor and the diff view both stay mounted once used (the other one is just hidden):
  // going file ↔ diff no longer builds a new Monaco editor on every click.
  const fileId = useRef<string | null>(null)
  const diffId = useRef<string | null>(null)
  if (active?.kind === 'file') fileId.current = active.id
  if (active?.kind === 'diff') diffId.current = active.id
  const fileTab = tabs.find((t): t is Extract<EditorTab, { kind: 'file' }> => t.kind === 'file' && t.id === fileId.current)
  const diffTab = tabs.find((t): t is Extract<EditorTab, { kind: 'diff' }> => t.kind === 'diff' && t.id === diffId.current)

  useEffect(() => {
    revealIn(stripRef.current, stripRef.current?.querySelector('.tab.active'), { inline: 'nearest', smooth: true })
  }, [activeId])

  return (
    <div className="editor-area">
      {tabs.length > 0 && (
        <div className="tab-row">
        <div className="tab-strip" ref={stripRef} onWheel={(e) => (e.currentTarget.scrollLeft += e.deltaY)}>
          <SlidePill className="tab-pill" />
          {tabs.map((t) => (
            <div
              key={t.id}
              className={`tab${t.id === activeId ? ' active' : ''}${t.kind === 'diff' ? ' diff' : ''}`}
              onClick={() => useStore.setState({ activeTabId: t.id })}
              onContextMenu={(e) => tabMenu(e, t)}
              onMouseDown={(e) => {
                if (e.button === 1) {
                  e.preventDefault()
                  closeTab(t.id)
                }
              }}
              title={t.path}
            >
              {t.kind === 'diff' ? <FileDiff size={14} color="#5aa9ff" /> : <FileIcon name={t.title} size={14} />}
              <span className="tab-title">{t.title}</span>
              {t.kind === 'diff' && <span className="tab-tag">diff</span>}
              <button
                className={`tab-close${t.kind === 'file' && t.dirty ? ' dirty' : ''}`}
                onClick={(e) => {
                  e.stopPropagation()
                  closeTab(t.id)
                }}
              >
                <X size={13} />
              </button>
            </div>
          ))}
          <div className="tab-strip-fill" />
        </div>
        <EditorExtensionsButton />
        <EditorFontButton />
        </div>
      )}
      <div className="editor-body">
        {!active && <EmptyEditor />}
        <Suspense fallback={null}>
          {/* no key: one editor serves every file tab, one diff view every diff tab */}
          {fileTab && (
            <div className={`editor-layer${active === fileTab ? ' on' : ''}`} inert={active !== fileTab}>
              <FileEditor tab={fileTab} />
            </div>
          )}
          {diffTab && (
            <div className={`editor-layer${active === diffTab ? ' on' : ''}`} inert={active !== diffTab}>
              <DiffView tab={diffTab} />
            </div>
          )}
        </Suspense>
      </div>
    </div>
  )
})

/* ================================ Empty state ================================ */

function EmptyEditor(): React.JSX.Element {
  const t = useT()
  const rows: [React.ReactNode, string, string][] = [
    [<Search size={14} key="s" />, t('Go to file', 'Đi tới tệp'), 'Ctrl+P'],
    [<MessageSquarePlus size={14} key="n" />, t('New chat', 'Chat mới'), 'Ctrl+Shift+N'],
    [<GitCompare size={14} key="g" />, t('Show changes', 'Hiện thay đổi'), 'Ctrl+Shift+G'],
    [<Command size={14} key="t" />, t('Toggle terminal', 'Bật/tắt terminal'), 'Ctrl+`'],
    [<Command size={14} key="b" />, t('Toggle sidebar', 'Bật/tắt thanh bên'), 'Ctrl+B']
  ]
  return (
    <div className="empty-editor">
      <div className="empty-logo">
        <Logo size={64} />
      </div>
      <button className="btn btn-primary btn-lg" onClick={() => openBrowser()}>
        <Globe size={16} /> {t('Open browser', 'Mở trình duyệt')}
      </button>
      <div className="shortcut-list">
        {rows.map(([icon, label, key]) => (
          <div key={label} className="shortcut-row">
            <span className="shortcut-label">
              {icon} {label}
            </span>
            <kbd>{key}</kbd>
          </div>
        ))}
      </div>
    </div>
  )
}
