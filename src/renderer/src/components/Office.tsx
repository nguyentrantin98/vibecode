import { useEffect, useRef, useState } from 'react'
import { FilePlus2, FileText, FolderOpen, Home, Loader2, RefreshCw, Trash2, X } from 'lucide-react'
import type { OfficeRequest, RecentFile } from '../../../shared/types'
import { openMenu } from './ContextMenu'
import { KIND_ICON, OnlyOfficeWorkspace } from './OnlyOffice'
import { type Kind, type Workspace, EXTS, errText, fileName, folderOf, kindOf } from './officeShared'
import { setOfficeOpener } from '../actions'
import { type T, tr, useT } from '../i18n'
import './office.css'

type View = 'home' | Kind

const KINDS: { kind: Kind; label: string; what: (t: T) => string; new?: (t: T) => string }[] = [
  { kind: 'doc', label: 'Word', what: (t) => t('document', 'tài liệu'), new: (t) => t('New document', 'Tài liệu mới') },
  { kind: 'sheet', label: 'Excel', what: (t) => t('spreadsheet', 'bảng tính'), new: (t) => t('New spreadsheet', 'Bảng tính mới') },
  { kind: 'slide', label: 'PowerPoint', what: (t) => t('presentation', 'bản trình chiếu'), new: (t) => t('New presentation', 'Bản trình chiếu mới') },
  { kind: 'pdf', label: 'PDF', what: () => 'PDF' }
]
const info = (k: Kind): (typeof KINDS)[number] => KINDS.find((x) => x.kind === k)!
const kindIcon = (path: string, size = 18): React.ReactNode => {
  const k = kindOf(path)
  return k ? KIND_ICON[k](size) : <FileText size={size} />
}

function bytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

/**
 * Office tab: a WPS-like home (open, new, recent files) and four ONLYOFFICE workspaces — Word,
 * Excel, PowerPoint and PDF — each with its own file tabs. Workspaces stay mounted, so open files
 * keep their state while another view is shown. Claude's vibe-office tools come in here
 * (`office:request`) and go to the workspace of their kind; they only read.
 */
export function OfficePane(): React.JSX.Element {
  const [view, setView] = useState<View>('home')
  const [open, setOpen] = useState<Record<Kind, string[]>>({ doc: [], sheet: [], slide: [], pdf: [] })
  const [recent, setRecent] = useState<RecentFile[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const docs = useRef<Workspace>(null)
  const sheets = useRef<Workspace>(null)
  const slides = useRef<Workspace>(null)
  const pdfs = useRef<Workspace>(null)
  const ws = (k: Kind): Workspace => {
    const w = { doc: docs, sheet: sheets, slide: slides, pdf: pdfs }[k].current
    if (!w) throw new Error('Office tab is not ready')
    return w
  }

  const loadRecent = (): void => void window.api.office.recent().then(setRecent, () => setRecent([]))
  useEffect(loadRecent, [])

  /** opens (or `create`s) any supported file in the workspace of its kind and shows it */
  const openFile = async (path: string, create = false): Promise<Kind> => {
    const kind = kindOf(path)
    if (!kind) throw new Error(tr(`The Office tab can't open this kind of file: ${fileName(path)}`, `Tab Office chưa mở được loại file này: ${fileName(path)}`))
    await ws(kind).open(path, create)
    setView(kind)
    await window.api.office.recentAdd(path).catch(() => {})
    loadRecent()
    return kind
  }
  const run = (p: () => Promise<unknown>): void => {
    setBusy(true)
    setError('')
    p()
      .catch((err: unknown) => setError(errText(err)))
      .finally(() => setBusy(false))
  }
  const pickOpen = (kind?: Kind): void =>
    run(async () => {
      const p = await window.api.office.pick(false, kind)
      if (p) await openFile(p)
    })
  const pickNew = (kind: Kind): void =>
    run(async () => {
      let p = await window.api.office.pick(true, kind)
      if (!p) return
      if (kindOf(p) !== kind) p += `.${EXTS[kind][0]}`
      await openFile(p, true)
    })
  const addMenu = (kind: Kind) => (e: React.MouseEvent) =>
    openMenu(e, [
      { label: tr(`Open ${info(kind).what(tr)}…`, `Mở ${info(kind).what(tr)}…`), icon: <FolderOpen size={14} />, action: () => pickOpen(kind) },
      info(kind).new && { label: `${info(kind).new!(tr)}…`, icon: <FilePlus2 size={14} />, action: () => pickNew(kind) }
    ])

  /* ---------- Claude's tools: one at a time, in order ---------- */
  const tool = async (req: OfficeRequest): Promise<string> => {
    switch (req.tool) {
      case 'office_status': {
        const parts = KINDS.flatMap((k) => ws(k.kind).status().map((s) => `${k.label}: ${s}`))
        return parts.length ? `On screen: ${view === 'home' ? 'the Office home page' : info(view).label}\n${parts.join('\n')}` : 'No file is open in the Office tab. Use office_open.'
      }
      case 'office_open': {
        const path = typeof req.args.path === 'string' ? req.args.path : ''
        if (!path) throw new Error('missing `path`')
        const kind = await openFile(path, req.args.create === true)
        return `Opened ${path} in ${info(kind).label}${req.args.create === true ? ' (new, empty)' : ''}`
      }
      case 'doc_read':
        return ws('doc').tool(req)
      case 'sheet_read':
        return ws('sheet').tool(req)
      case 'slide_read':
        return ws('slide').tool(req)
      case 'pdf_read':
        return ws('pdf').tool(req)
    }
    throw new Error(`unknown tool ${String(req.tool)}`)
  }
  const toolRef = useRef(tool)
  toolRef.current = tool
  // files opened from Source code › This PC
  const openRef = useRef(openFile)
  openRef.current = openFile
  useEffect(() => setOfficeOpener((path) => run(() => openRef.current(path))), [])
  useEffect(() => {
    let chain = Promise.resolve()
    const seen = new Set<number>()
    const handle = (req: OfficeRequest): void => {
      if (seen.has(req.id)) return
      seen.add(req.id)
      chain = chain.then(() =>
        toolRef.current(req).then(
          (text) => window.api.office.reply(req.id, true, text),
          (err: unknown) => window.api.office.reply(req.id, false, errText(err))
        )
      )
    }
    const off = window.api.office.onRequest(handle)
    void window.api.office.pending().then((list) => list.forEach(handle))
    return off
  }, [])

  const filesChanged = (kind: Kind) => (paths: string[]) => setOpen((o) => ({ ...o, [kind]: paths }))
  const homeFor: Kind | null = view === 'home' ? null : view
  const showHome = view === 'home' || open[view].length === 0
  // sizes and dates change as files are saved: refresh the list whenever it comes back on screen
  useEffect(() => {
    if (showHome) loadRecent()
  }, [showHome, view])

  const t = useT()
  return (
    <div className="of-root of-shell">
      <nav className="of-rail">
        <button className={view === 'home' ? 'on' : ''} onClick={() => setView('home')} title={t('Home', 'Trang chủ')}>
          <Home size={20} />
          <span>{t('Home', 'Trang chủ')}</span>
        </button>
        {KINDS.map((k) => (
          <button key={k.kind} className={view === k.kind ? 'on' : ''} onClick={() => setView(k.kind)} title={k.label}>
            {KIND_ICON[k.kind](20)}
            <span>{k.label}</span>
            {open[k.kind].length > 0 && <i className="of-rail-count">{open[k.kind].length}</i>}
          </button>
        ))}
      </nav>
      <main className="of-main">
        <OnlyOfficeWorkspace ref={docs} kind="doc" shown={view === 'doc'} onFiles={filesChanged('doc')} onAdd={addMenu('doc')} />
        <OnlyOfficeWorkspace ref={sheets} kind="sheet" shown={view === 'sheet'} onFiles={filesChanged('sheet')} onAdd={addMenu('sheet')} />
        <OnlyOfficeWorkspace ref={slides} kind="slide" shown={view === 'slide'} onFiles={filesChanged('slide')} onAdd={addMenu('slide')} />
        <OnlyOfficeWorkspace ref={pdfs} kind="pdf" shown={view === 'pdf'} onFiles={filesChanged('pdf')} onAdd={addMenu('pdf')} />
        {showHome && (
          <OfficeHome
            kind={homeFor}
            recent={recent}
            busy={busy}
            error={error}
            onClearError={() => setError('')}
            onOpen={(p) => run(() => openFile(p))}
            onPick={() => pickOpen(homeFor ?? undefined)}
            onNew={pickNew}
            onRefresh={loadRecent}
            onForget={(p) => void window.api.office.recentAdd(p, true).then(loadRecent)}
          />
        )}
      </main>
    </div>
  )
}

/* ================================ home ================================ */

function OfficeHome(p: {
  kind: Kind | null
  recent: RecentFile[] | null
  busy: boolean
  error: string
  onClearError: () => void
  onOpen: (path: string) => void
  onPick: () => void
  onNew: (kind: Kind) => void
  onRefresh: () => void
  onForget: (path: string) => void
}): React.JSX.Element {
  const list = (p.recent ?? []).filter((f) => !p.kind || kindOf(f.path) === p.kind)
  const t = useT()
  const what = p.kind ? info(p.kind).what(t) : null
  return (
    <div className="of-home">
      <div className="of-home-actions">
        <button className="of-open" disabled={p.busy} onClick={p.onPick}>
          {p.busy ? <Loader2 size={16} className="of-spin" /> : <FolderOpen size={16} />} {t('Open', 'Mở')}{what ? ` ${what}` : ''}
        </button>
        {KINDS.filter((k) => k.new && (!p.kind || p.kind === k.kind)).map((k) => (
          <button key={k.kind} className="of-action" disabled={p.busy} onClick={() => p.onNew(k.kind)}>
            {KIND_ICON[k.kind](16)} {k.new!(t)}
          </button>
        ))}
      </div>
      {p.error && (
        <p className="of-error of-pad" onClick={p.onClearError} title={t('Click to hide', 'Bấm để ẩn')}>
          {p.error}
        </p>
      )}
      <div className="of-recent-head">
        <h2>{p.kind ? t(`Recent ${info(p.kind).label}`, `${info(p.kind).label} gần đây`) : t('Recent', 'Gần đây')}</h2>
        <button className="of-tb" title={t('Refresh', 'Tải lại')} onClick={p.onRefresh}>
          <RefreshCw size={15} />
        </button>
      </div>
      <div className="of-recent">
        <div className="of-recent-row of-recent-cols">
          <span>{t('Name', 'Tên file')}</span>
          <span>{t('Location', 'Vị trí')}</span>
          <span>{t('Date modified', 'Sửa lần cuối')}</span>
          <span className="of-num">{t('Size', 'Dung lượng')}</span>
          <span />
        </div>
        {p.recent === null && <p className="of-dim of-pad">{t('Loading…', 'Đang tải…')}</p>}
        {p.recent !== null && list.length === 0 && (
          <p className="of-dim of-pad">
            {t(
              `No ${what ?? 'file'}s yet. Click “Open${what ? ` ${what}` : ''}” to open a file on this computer${p.kind === 'pdf' ? '' : ' or create a new one'}.`,
              `Chưa có ${what ?? 'file'} nào. Bấm “Mở${what ? ` ${what}` : ''}” để mở file trên máy${p.kind === 'pdf' ? '' : ' hoặc tạo mới'}.`
            )}
          </p>
        )}
        {list.map((f) => (
          <div
            key={f.path}
            className={'of-recent-row' + (f.exists ? '' : ' gone')}
            title={f.exists ? f.path : t(`The file is no longer at ${f.path}`, `Không còn file ở ${f.path}`)}
            onClick={() => f.exists && p.onOpen(f.path)}
            onContextMenu={(e) =>
              openMenu(e, [
                f.exists && { label: t('Open', 'Mở'), action: () => p.onOpen(f.path) },
                f.exists && { label: t('Open containing folder', 'Mở thư mục chứa'), icon: <FolderOpen size={14} />, action: () => window.api.fs.reveal(f.path) },
                { label: t('Remove from list', 'Xoá khỏi danh sách'), icon: <Trash2 size={14} />, action: () => p.onForget(f.path) }
              ])
            }
          >
            <span className="of-recent-name">
              {kindIcon(f.path)}
              <b>{fileName(f.path)}</b>
              {!f.exists && <em>{t('no longer on this computer', 'không còn trên máy')}</em>}
            </span>
            <span className="of-dim of-ellipsis">{folderOf(f.path)}</span>
            <span className="of-dim">{f.modified ? new Date(f.modified).toLocaleDateString(t('en-US', 'vi-VN'), { day: '2-digit', month: '2-digit', year: 'numeric' }) : ''}</span>
            <span className="of-dim of-num">{f.exists ? bytes(f.size) : ''}</span>
            <button
              className="of-fileclose"
              title={t('Remove from list (does not delete the file)', 'Xoá khỏi danh sách (không xoá file)')}
              onClick={(e) => {
                e.stopPropagation()
                p.onForget(f.path)
              }}
            >
              <X size={13} />
            </button>
          </div>
        ))}
      </div>
    </div>
  )
}
