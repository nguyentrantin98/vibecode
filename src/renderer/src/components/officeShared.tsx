/**
 * What the Office tab's workspaces (Word, Excel, PowerPoint, PDF: one ONLYOFFICE workspace each)
 * share: path helpers, the file tab strip, autosave with its status label, and the handle the
 * Office shell drives them through.
 */
import { useEffect, useRef, useState } from 'react'
import { CloudAlert, CloudCheck, Loader2, Plus, X } from 'lucide-react'
import type { OfficeRequest } from '../../../shared/types'
import { useT } from '../i18n'

export type Kind = 'doc' | 'sheet' | 'slide' | 'pdf'

/** what each workspace opens; the first one is what it creates */
export const EXTS: Record<Kind, string[]> = {
  doc: ['docx', 'doc', 'odt', 'rtf'],
  sheet: ['xlsx', 'xls', 'ods', 'csv'],
  slide: ['pptx', 'ppt', 'odp'],
  pdf: ['pdf']
}

export const fileName = (p: string): string => p.split(/[\\/]/).pop() ?? p
export const folderOf = (p: string): string => p.slice(0, Math.max(0, p.length - fileName(p).length - 1))
export const samePath = (a: string, b: string): boolean => a.replace(/\//g, '\\').toLowerCase() === b.replace(/\//g, '\\').toLowerCase()
export const extOf = (p: string): string => (fileName(p).includes('.') ? (p.split('.').pop()?.toLowerCase() ?? '') : '')

export function kindOf(path: string): Kind | null {
  const ext = extOf(path)
  return (Object.keys(EXTS) as Kind[]).find((k) => EXTS[k].includes(ext)) ?? null
}

export function toBase64(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf)
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

/** waits (up to `ms`) for an editor's state to catch up with API calls */
export async function until(ok: () => boolean, ms = 3000): Promise<void> {
  const end = Date.now() + ms
  while (!ok() && Date.now() < end) await new Promise((r) => setTimeout(r, 30))
}

export const errText = (err: unknown): string => (err instanceof Error ? err.message : String(err))

/** What the Office shell asks of a workspace. */
export interface Workspace {
  /** open a file (or show it when open), `create`: make it new and empty first */
  open(path: string, create?: boolean): Promise<void>
  /** run one of Claude's tools for this kind */
  tool(req: OfficeRequest): Promise<string>
  /** one block per open file, for office_status */
  status(): string[]
}

export type WorkspaceProps = {
  /** shown: this workspace is the Office tab's current view */
  shown: boolean
  /** the open files changed (the shell shows its home page when there are none) */
  onFiles: (paths: string[]) => void
  /** the file tab strip's "+" */
  onAdd: (e: React.MouseEvent) => void
}

/* ================================ autosave ================================ */

export type SaveInfo = { state: 'saving' | 'saved' | 'error'; msg?: string; at?: number; backup?: string }

/**
 * Saves a file about a second after its edits stop, right away when the window loses focus, and
 * again every 5 s while it fails. A change made during a save keeps the file dirty for the next
 * one. Before a file that existed is first overwritten, a copy goes to the app's backup folder.
 */
export function useAutosave(o: { write: (path: string) => Promise<void>; isOpen: (path: string) => boolean; setDirty: (path: string, dirty: boolean) => void; delay?: number }) {
  const [saveState, setSaveState] = useState<Record<string, SaveInfo>>({})
  const opts = useRef(o)
  opts.current = o
  const version = useRef(new Map<string, number>())
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>())
  const saving = useRef(new Map<string, Promise<void>>())
  /** files already copied aside (or created here: nothing to keep) */
  const backedUp = useRef(new Set<string>())

  const schedule = (path: string, ms = opts.current.delay ?? 1000): void => {
    clearTimeout(timers.current.get(path))
    timers.current.set(
      path,
      setTimeout(() => void saveNow(path).catch(() => {}), ms)
    )
  }
  /** writes the file now (with `write` instead of the workspace's own writer, e.g. from a snapshot) */
  const saveNow = (path: string, write?: () => Promise<void>): Promise<void> => {
    clearTimeout(timers.current.get(path))
    timers.current.delete(path)
    const prev = saving.current.get(path) ?? Promise.resolve()
    const p = prev
      .catch(() => {})
      .then(async () => {
        if (!opts.current.isOpen(path)) return // closed meanwhile
        const v = version.current.get(path) ?? 0
        setSaveState((m) => ({ ...m, [path]: { ...m[path], state: 'saving' } }))
        try {
          let backup: string | undefined
          if (!backedUp.current.has(path)) {
            backup = await window.api.office.backup(path).catch(() => undefined)
            backedUp.current.add(path)
          }
          await (write ? write() : opts.current.write(path))
          if ((version.current.get(path) ?? 0) === v) opts.current.setDirty(path, false)
          setSaveState((m) => ({ ...m, [path]: { state: 'saved', at: Date.now(), backup: backup ?? m[path]?.backup } }))
        } catch (err) {
          setSaveState((m) => ({ ...m, [path]: { ...m[path], state: 'error', msg: errText(err) } }))
          schedule(path, 5000)
          throw err
        }
      })
    saving.current.set(path, p)
    return p
  }
  /** the user or Claude changed a file */
  const changed = (path: string): void => {
    version.current.set(path, (version.current.get(path) ?? 0) + 1)
    opts.current.setDirty(path, true)
    schedule(path)
  }
  /** a file closed: nothing more to save for it */
  const forget = (path: string): void => {
    clearTimeout(timers.current.get(path))
    timers.current.delete(path)
  }
  /** a file created here: there is no original to back up */
  const created = (path: string): void => void backedUp.current.add(path)
  const pending = (path: string): boolean => timers.current.has(path)

  useEffect(() => {
    const flush = (): void => {
      for (const path of [...timers.current.keys()]) void saveNow(path).catch(() => {})
    }
    window.addEventListener('blur', flush)
    window.addEventListener('pagehide', flush)
    return () => {
      window.removeEventListener('blur', flush)
      window.removeEventListener('pagehide', flush)
    }
  }, [])

  return { saveState, saveNow, changed, forget, created, pending }
}

/** "Đang lưu… / Đã lưu / Chưa lưu được" next to the Save button */
export function SaveStatus({ dirty, s, note }: { dirty: boolean; s?: SaveInfo; note?: string }): React.JSX.Element | null {
  const t = useT()
  if (s?.state === 'error')
    return (
      <span className="of-save err" title={`${s.msg ?? ''}\n${t('Retrying every 5 seconds; your data is still in the app.', 'Đang thử lưu lại mỗi 5 giây; dữ liệu vẫn còn trong app.')}`}>
        <CloudAlert size={14} /> {t('Not saved', 'Chưa lưu được')}
      </span>
    )
  if (dirty || s?.state === 'saving')
    return (
      <span className="of-save" title={t('Saves automatically about 1 second after you stop editing', 'Tự động lưu khoảng 1 giây sau khi ngừng sửa')}>
        <Loader2 size={14} className="of-spin" /> {t('Saving…', 'Đang lưu…')}
      </span>
    )
  if (!s) return null
  const lines = [`${t('Autosaved at', 'Tự động lưu lúc')} ${new Date(s.at ?? 0).toLocaleTimeString(t('en-US', 'vi-VN'))}`]
  if (s.backup) lines.push(t(`The original before editing is kept at: ${s.backup}`, `Bản gốc trước khi sửa được giữ ở: ${s.backup}`))
  if (note) lines.push(note)
  return (
    <span className="of-save ok" title={lines.join('\n')}>
      <CloudCheck size={14} /> {t('Saved', 'Đã lưu')}
    </span>
  )
}

/* ================================ file tabs ================================ */

export function FileTabs(p: {
  files: { path: string; dirty: boolean }[]
  active: string | null
  icon: React.ReactNode
  onShow: (path: string) => void
  onClose: (path: string) => void
  onAdd: (e: React.MouseEvent) => void
  addTitle: string
  children?: React.ReactNode
}): React.JSX.Element {
  const t = useT()
  return (
    <div className="of-files">
      {p.files.map((f) => (
        <div
          key={f.path}
          className={'of-filetab' + (f.path === p.active ? ' on' : '')}
          title={f.path}
          onClick={() => p.onShow(f.path)}
          onMouseDown={(e) => {
            if (e.button === 1) {
              e.preventDefault()
              p.onClose(f.path)
            }
          }}
        >
          {p.icon}
          <span className="of-filename">{fileName(f.path)}</span>
          {f.dirty && <span className="of-dirty" title={t('Unsaved changes', 'Có thay đổi chưa lưu')} />}
          <button
            className="of-fileclose"
            title={t('Close file', 'Đóng file')}
            onClick={(e) => {
              e.stopPropagation()
              p.onClose(f.path)
            }}
          >
            <X size={13} />
          </button>
        </div>
      ))}
      <button className="of-tool of-addfile" title={p.addTitle} onClick={p.onAdd}>
        <Plus size={15} />
      </button>
      <span className="of-fill" />
      {p.children}
    </div>
  )
}

/** Finds an open file by path or file name (default: the one on screen); Claude's `file` argument. */
export function findOpen<F extends { path: string }>(files: F[], active: string | null, name: unknown, what: string): F {
  const f =
    typeof name === 'string' && name
      ? files.find((x) => samePath(x.path, name) || fileName(x.path).toLowerCase() === name.toLowerCase())
      : (files.find((x) => x.path === active) ?? files[0])
  if (!f) throw new Error(typeof name === 'string' && name ? `"${name}" is not open in the Office tab (office_status lists open files)` : `No ${what} is open in the Office tab. Use office_open.`)
  return f
}
