import { useEffect, useState } from 'react'
import { Bot, Download, ExternalLink, FileSpreadsheet, FileText, FileType2, FolderOpen, Loader2, Presentation, RefreshCw, Trash2, X } from 'lucide-react'
import type { OfficeStatus, RecentFile } from '../../../shared/types'
import { openMenu } from './ContextMenu'
import { newChatFromOfficeFile } from '../actions'
import { useT } from '../i18n'
import './office.css'

const RELEASES = 'https://github.com/genspark-ai/genoffice/releases/latest'

const fileName = (p: string): string => p.split(/[\\/]/).pop() ?? p
const folderOf = (p: string): string => p.slice(0, Math.max(0, p.length - fileName(p).length - 1))
const errText = (err: unknown): string => (err instanceof Error ? err.message : String(err)).replace(/^Error: /, '')

function kindIcon(path: string, size = 18): React.ReactNode {
  const ext = fileName(path).split('.').pop()?.toLowerCase() ?? ''
  if (['docx', 'doc', 'odt', 'rtf', 'md', 'html'].includes(ext)) return <FileText size={size} className="of-ic-doc" />
  if (['xlsx', 'xls', 'ods', 'csv'].includes(ext)) return <FileSpreadsheet size={size} className="of-ic-sheet" />
  if (['pptx', 'ppt', 'odp'].includes(ext)) return <Presentation size={size} className="of-ic-slide" />
  if (ext === 'pdf') return <FileType2 size={size} className="of-ic-pdf" />
  return <FileText size={size} />
}

function bytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

/**
 * Office tab: Word, Excel, PowerPoint and PDF files open in GenOffice (github.com/genspark-ai/genoffice),
 * a separate app. Here: installing it, opening files in it, the recent files, and handing a file to
 * Claude, whose chats get GenOffice's own MCP tools (src-zig/src/mcp.zig).
 */
export function OfficePane(): React.JSX.Element {
  const t = useT()
  const [status, setStatus] = useState<OfficeStatus | null>(null)
  const [recent, setRecent] = useState<RecentFile[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState<{ phase: string; done: number; total: number } | null>(null)
  const [error, setError] = useState('')

  const loadRecent = (): void => void window.api.office.recent().then(setRecent, () => setRecent([]))
  const loadStatus = (): void => void window.api.office.status().then(setStatus, () => setStatus(null))
  useEffect(() => {
    loadRecent()
    loadStatus()
    // installed meanwhile (by hand, or the files changed): look again when the window comes back
    const onFocus = (): void => {
      loadStatus()
      loadRecent()
    }
    window.addEventListener('focus', onFocus)
    const off = window.api.office.onInstall(setProgress)
    return () => {
      window.removeEventListener('focus', onFocus)
      off()
    }
  }, [])

  const run = (p: () => Promise<unknown>): void => {
    setBusy(true)
    setError('')
    p()
      .catch((err: unknown) => setError(errText(err)))
      .finally(() => {
        setBusy(false)
        loadRecent()
      })
  }
  const open = (path?: string): void => run(() => window.api.office.open(path))
  const pick = (): void =>
    run(async () => {
      const p = await window.api.office.pick()
      if (p) await window.api.office.open(p)
    })
  const install = (): void =>
    run(async () => {
      try {
        setStatus(await window.api.office.install())
      } finally {
        setProgress(null)
        loadStatus()
      }
    })
  const forget = (path: string): void => void window.api.office.recentAdd(path, true).then(loadRecent)

  const ready = !!status?.installed
  const installing = busy && !!progress
  const pct = progress && progress.total ? Math.round((progress.done / progress.total) * 100) : 0

  return (
    <div className="of-root">
      <div className="of-home">
        {status && !ready && (
          <div className="of-gen">
            <h2>{t('Office files open in GenOffice', 'Tệp Office mở bằng GenOffice')}</h2>
            <p className="of-dim">
              {t(
                'GenOffice is a free, open-source office suite (Word, Excel, PowerPoint, PDF) that keeps the real file formats. It is a separate app: install it once, then files open in it from here, and Claude chats get its tools to read and edit .docx, .xlsx, .pptx and .pdf files.',
                'GenOffice là bộ office mã nguồn mở, miễn phí (Word, Excel, PowerPoint, PDF), giữ nguyên định dạng file gốc. Đây là app riêng: cài một lần, sau đó file mở bằng nó từ đây, và các chat Claude có công cụ của nó để đọc, sửa file .docx, .xlsx, .pptx, .pdf.'
              )}
            </p>
            {status.can_install ? (
              <div className="of-home-actions">
                <button className="of-open" disabled={busy || status.installing} onClick={install}>
                  {installing || status.installing ? <Loader2 size={16} className="of-spin" /> : <Download size={16} />}{' '}
                  {t('Download and install GenOffice (about 170 MB)', 'Tải và cài GenOffice (khoảng 170 MB)')}
                </button>
                <button className="of-action" onClick={() => void window.api.app.openExternal(RELEASES)}>
                  <ExternalLink size={16} /> {t('Release page', 'Trang phát hành')}
                </button>
              </div>
            ) : (
              <div className="of-home-actions">
                <button className="of-open" onClick={() => void window.api.app.openExternal(RELEASES)}>
                  <ExternalLink size={16} /> {t('Download GenOffice', 'Tải GenOffice')}
                </button>
                <button className="of-action" onClick={loadStatus}>
                  <RefreshCw size={16} /> {t('I installed it', 'Tôi đã cài xong')}
                </button>
              </div>
            )}
            {progress && (
              <div className="of-progress">
                <progress value={progress.phase === 'download' ? pct : undefined} max={100} />
                <span className="of-dim">
                  {progress.phase === 'download'
                    ? t(`Downloading… ${pct}% of ${bytes(progress.total)}`, `Đang tải… ${pct}% của ${bytes(progress.total)}`)
                    : progress.phase === 'install'
                      ? t('Installing GenOffice…', 'Đang cài GenOffice…')
                      : t('Installed.', 'Đã cài xong.')}
                </span>
              </div>
            )}
          </div>
        )}
        {ready && (
          <div className="of-home-actions">
            <button className="of-open" disabled={busy} onClick={pick}>
              {busy ? <Loader2 size={16} className="of-spin" /> : <FolderOpen size={16} />} {t('Open a file…', 'Mở tệp…')}
            </button>
            <button className="of-action" disabled={busy} onClick={() => open()} title={status?.app ?? ''}>
              <ExternalLink size={16} /> {t('Open GenOffice (new document, sheet, deck…)', 'Mở GenOffice (tạo tài liệu, bảng tính, trình chiếu…)')}
            </button>
          </div>
        )}
        {error && (
          <p className="of-error of-pad" onClick={() => setError('')} title={t('Click to hide', 'Bấm để ẩn')}>
            {error}
          </p>
        )}
        <div className="of-recent-head">
          <h2>{t('Recent', 'Gần đây')}</h2>
          <button className="of-tb" title={t('Refresh', 'Tải lại')} onClick={loadRecent}>
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
          {recent === null && <p className="of-dim of-pad">{t('Loading…', 'Đang tải…')}</p>}
          {recent !== null && recent.length === 0 && (
            <p className="of-dim of-pad">{t('No files yet. Files you open from here are listed for next time.', 'Chưa có file nào. File bạn mở từ đây sẽ được liệt kê cho lần sau.')}</p>
          )}
          {recent?.map((f) => (
            <div
              key={f.path}
              className={'of-recent-row' + (f.exists ? '' : ' gone')}
              title={f.exists ? f.path : t(`The file is no longer at ${f.path}`, `Không còn file ở ${f.path}`)}
              onClick={() => f.exists && ready && open(f.path)}
              onContextMenu={(e) =>
                openMenu(e, [
                  f.exists && ready && { label: t('Open in GenOffice', 'Mở bằng GenOffice'), icon: <ExternalLink size={14} />, action: () => open(f.path) },
                  f.exists && { label: t('Give to Claude', 'Giao cho AI'), icon: <Bot size={14} />, action: () => void newChatFromOfficeFile(f.path) },
                  f.exists && { label: t('Open containing folder', 'Mở thư mục chứa'), icon: <FolderOpen size={14} />, action: () => window.api.fs.reveal(f.path) },
                  { label: t('Remove from list', 'Xoá khỏi danh sách'), icon: <Trash2 size={14} />, action: () => forget(f.path) }
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
                  forget(f.path)
                }}
              >
                <X size={13} />
              </button>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
