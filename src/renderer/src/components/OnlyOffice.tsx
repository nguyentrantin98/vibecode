import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react'
import { Bot, FileOutput, FileSpreadsheet, FileText, FileType2, Loader2, Presentation, RefreshCw } from 'lucide-react'
import type { OfficeRequest } from '../../../shared/types'
import { FileTabs, SaveStatus, type Kind, type Workspace, type WorkspaceProps, EXTS, errText, extOf, fileName, findOpen, samePath, toBase64, until, useAutosave } from './officeShared'
import { docText, pageList, pdfPages, sheetText, slideTexts, unzip } from '../ooxmlText'
import { newChatFromOfficeFile } from '../actions'
import { type T, tr, useT } from '../i18n'

/** Old binary formats: x2t reads them but writes only their OOXML sibling, so they open read-only. */
const LEGACY: Record<string, string> = { doc: 'docx', xls: 'xlsx', ppt: 'pptx' }
const legacyTarget = (path: string): string | undefined => LEGACY[extOf(path)]
/** PDFs open read-only too: they are viewed, not rewritten */
const readonlyOf = (path: string): boolean => !!legacyTarget(path) || extOf(path) === 'pdf'
const note = (t: T): string =>
  t('Opened with ONLYOFFICE: keeps full Word / Excel / PowerPoint formatting. Saves itself a few seconds after each edit.', 'Mở bằng ONLYOFFICE: giữ đầy đủ định dạng Word / Excel / PowerPoint. Tự lưu vài giây sau khi sửa.')

export const KIND_ICON: Record<Kind, (size: number) => React.ReactNode> = {
  doc: (s) => <FileText size={s} className="of-ic-doc" />,
  sheet: (s) => <FileSpreadsheet size={s} className="of-ic-sheet" />,
  slide: (s) => <Presentation size={s} className="of-ic-slide" />,
  pdf: (s) => <FileType2 size={s} className="of-ic-pdf" />
}
/** what Claude's read tools get the file as: the editor's own OOXML export (a PDF's as .docx) */
const READ_AS: Record<Kind, string> = { doc: 'DOCX', sheet: 'XLSX', slide: 'PPTX', pdf: 'DOCX' }
const WHAT: Record<Kind, string> = { doc: 'document', sheet: 'spreadsheet', slide: 'presentation', pdf: 'PDF' }

type OpenFile = {
  path: string
  dirty: boolean
  state: 'loading' | 'ready' | 'error'
  error?: string
  /** bumped to load the editor again after an error */
  gen: number
  /** the editor's UI language, fixed when the file opens (changing it would reload the editor) */
  locale: string
  /** made here: the editor starts empty, and the file is written once it is up */
  create?: boolean
}
type Waiting = { resolve: (payload: Record<string, unknown>) => void; reject: (err: Error) => void; timer: ReturnType<typeof setTimeout> }

let seq = 0

/**
 * One workspace of the Office tab (Word, Excel, PowerPoint or PDF): the ONLYOFFICE editors
 * (onlyoffice.rs downloads them once and serves them from this machine). Each open file has its
 * own editor iframe, driven through the editor's embed API: the file's bytes go in with
 * `document:open-buffer` (no bytes: a new, empty file); once edits stop, `document:save` hands back
 * the new file, written over the original (which is first copied to the backup folder).
 * Claude's read tools get the editor's current content the same way, as OOXML (ooxmlText.ts).
 */
export const OnlyOfficeWorkspace = forwardRef<Workspace, WorkspaceProps & { kind: Kind }>(function OnlyOfficeWorkspace({ kind, shown, onFiles, onAdd }, ref) {
  const [files, setFiles] = useState<OpenFile[]>([])
  const [active, setActive] = useState<string | null>(null)
  const [origin, setOrigin] = useState<string | null>(null)
  const [install, setInstall] = useState<{ done: number; total: number } | { error: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const filesRef = useRef(files)
  filesRef.current = files
  const originRef = useRef(origin)
  const installing = useRef(false)
  const frames = useRef(new Map<string, HTMLIFrameElement>())
  const waiting = useRef(new Map<string, Waiting>())
  const file = files.find((f) => f.path === active) ?? null
  useEffect(() => onFiles(files.map((f) => f.path)), [files.length])

  const patch = (path: string, p: Partial<OpenFile>): void => {
    filesRef.current = filesRef.current.map((f) => (f.path === path ? { ...f, ...p } : f))
    setFiles(filesRef.current)
  }

  /** one embed API command to a file's editor; resolves with its answer's payload */
  const call = (path: string, type: string, payload: Record<string, unknown>, ms: number, transfer: Transferable[] = []): Promise<Record<string, unknown>> =>
    new Promise((resolve, reject) => {
      const win = frames.current.get(path)?.contentWindow
      if (!win || !originRef.current) return reject(new Error(tr('ONLYOFFICE is not ready yet', 'ONLYOFFICE chưa sẵn sàng')))
      const id = `vibe-${++seq}`
      const timer = setTimeout(() => {
        waiting.current.delete(id)
        reject(new Error(tr('ONLYOFFICE did not answer in time', 'ONLYOFFICE không trả lời kịp')))
      }, ms)
      waiting.current.set(id, { resolve, reject, timer })
      win.postMessage({ id, type, payload }, { targetOrigin: originRef.current, transfer })
    })

  /** the editor of `path` is up: give it the file */
  const load = async (path: string): Promise<void> => {
    const create = filesRef.current.find((f) => f.path === path)?.create
    try {
      const bytes = create ? new ArrayBuffer(0) : await window.api.office.readFile(path)
      await call(path, 'document:open-buffer', { fileName: fileName(path), buffer: bytes, readonly: readonlyOf(path) }, 180_000, [bytes])
      patch(path, { state: 'ready', error: undefined, create: undefined })
      if (create) {
        auto.created(path)
        void auto.saveNow(path).catch(() => {})
      }
    } catch (err) {
      patch(path, { state: 'error', error: tr(`Could not open ${fileName(path)}: ${errText(err)}`, `Không mở được ${fileName(path)}: ${errText(err)}`) })
    }
  }

  /** the editor answers one export at a time: they wait for each other, per file */
  const exporting = useRef(new Map<string, Promise<unknown>>())
  const oneAtATime = <R,>(path: string, run: () => Promise<R>): Promise<R> => {
    const p = (exporting.current.get(path) ?? Promise.resolve()).catch(() => {}).then(run)
    exporting.current.set(path, p)
    return p
  }
  const save = (path: string, targetExt?: string): Promise<{ file: Blob; dirty: boolean }> =>
    call(path, 'document:save', targetExt ? { targetExt } : {}, 300_000).then((p) => {
      if (!(p.file instanceof Blob) || p.file.size === 0) throw new Error(tr('ONLYOFFICE returned an empty file', 'ONLYOFFICE trả về file rỗng'))
      return { file: p.file, dirty: p.dirty === true }
    })
  /** the file as the editor has it now, in `targetExt` (default: its own format) */
  const exportFile = (path: string, targetExt?: string): Promise<{ data: string; dirty: boolean }> =>
    oneAtATime(path, async () => {
      const { file, dirty } = await save(path, targetExt)
      return { data: toBase64(await file.arrayBuffer()), dirty }
    })
  /** what Claude reads: the editor's content as OOXML (a read-only editor is opened up for the export) */
  const snapshot = (path: string): Promise<ArrayBuffer> =>
    oneAtATime(path, async () => {
      const ro = readonlyOf(path)
      if (ro) await call(path, 'document:set-readonly', { readonly: false }, 10_000)
      try {
        return await (await save(path, READ_AS[kind])).file.arrayBuffer()
      } finally {
        if (ro) await call(path, 'document:set-readonly', { readonly: true }, 10_000).catch(() => {})
      }
    })

  /** what was last written to each file (the same bytes are not written again) */
  const written = useRef(new Map<string, string>())
  /** files to export again later: the editor has edits no export holds yet */
  const recheck = useRef(new Map<string, ReturnType<typeof setTimeout>>())
  const stopRecheck = (path: string): void => {
    clearTimeout(recheck.current.get(path))
    recheck.current.delete(path)
  }
  const isOpen = (path: string): boolean => filesRef.current.some((f) => f.path === path)

  const auto = useAutosave({
    delay: 2000,
    write: async (path) => {
      stopRecheck(path)
      const { data, dirty } = await exportFile(path)
      const same = written.current.get(path) === data
      if (!same) {
        await window.api.office.writeFile(path, data)
        written.current.set(path, data)
      }
      if (!dirty) return
      // The editor still has edits these bytes lack: typed while the file was exported (saved
      // again right away), or a spreadsheet cell still being typed into, which no export holds
      // until it is committed (looked at again a little later, without writing the same bytes).
      if (!same) auto.changed(path)
      else
        recheck.current.set(
          path,
          setTimeout(() => {
            recheck.current.delete(path)
            if (isOpen(path)) auto.changed(path)
          }, 15_000)
        )
    },
    isOpen,
    setDirty: (path, dirty) => patch(path, { dirty })
  })

  const onMessage = (e: MessageEvent): void => {
    if (!originRef.current || e.origin !== originRef.current) return
    const path = [...frames.current].find(([, f]) => f.contentWindow === e.source)?.[0]
    const { id, type, payload = {} } = (e.data ?? {}) as { id?: string; type?: string; payload?: Record<string, unknown> }
    if (!path || typeof type !== 'string') return
    const w = id ? waiting.current.get(id) : undefined
    if (w) {
      clearTimeout(w.timer)
      waiting.current.delete(id!)
      if (type === 'document:error') w.reject(new Error(String(payload.message ?? tr('unknown error', 'lỗi không rõ'))))
      else w.resolve(payload)
      return
    }
    if (type === 'document:ready') void load(path)
    // a read-only file is never written (a PDF, a .doc / .xls / .ppt: their own format can't be)
    else if (type === 'document:dirty-changed' && payload.dirty === true && !readonlyOf(path)) auto.changed(path)
  }
  const onMessageRef = useRef(onMessage)
  onMessageRef.current = onMessage
  useEffect(() => {
    const handle = (e: MessageEvent): void => onMessageRef.current(e)
    window.addEventListener('message', handle)
    const off = window.api.onlyoffice.onProgress((done, total) => setInstall({ done, total }))
    return () => {
      window.removeEventListener('message', handle)
      off()
    }
  }, [])

  /** the editor's address, downloading it the first time */
  const ensureEditor = async (): Promise<void> => {
    if (originRef.current || installing.current) return
    installing.current = true
    try {
      let o = await window.api.onlyoffice.origin()
      if (!o) {
        setInstall({ done: 0, total: await window.api.onlyoffice.downloadSize() })
        o = await window.api.onlyoffice.install()
      }
      originRef.current = o
      setOrigin(o)
      setInstall(null)
    } catch (err) {
      setInstall({ error: errText(err) })
    } finally {
      installing.current = false
    }
  }

  const openPath = async (path: string, create?: boolean): Promise<void> => {
    const open = filesRef.current.find((f) => samePath(f.path, path))
    if (create && extOf(path) !== EXTS[kind][0])
      throw new Error(kind === 'pdf' ? tr("Can't create a new PDF: only existing PDFs can be opened", 'Không tạo được PDF mới: chỉ mở PDF có sẵn') : tr(`New files are .${EXTS[kind][0]}`, `File mới là .${EXTS[kind][0]}`))
    if (create && open) throw new Error(tr(`${fileName(path)} is open: close it first`, `${fileName(path)} đang mở: đóng nó trước`))
    if (!open) {
      filesRef.current = [...filesRef.current, { path, dirty: false, state: 'loading', gen: 0, locale: tr('en', 'vi'), create }]
      setFiles(filesRef.current)
    }
    setActive(open?.path ?? path)
    void ensureEditor()
  }

  const close = (path: string): void => {
    const f = filesRef.current.find((x) => x.path === path)
    if (!f) return
    const drop = (): void => {
      auto.forget(path)
      stopRecheck(path)
      written.current.delete(path)
      frames.current.delete(path)
      exporting.current.delete(path)
      const i = filesRef.current.findIndex((x) => x.path === path)
      const rest = filesRef.current.filter((x) => x.path !== path)
      filesRef.current = rest
      setFiles(rest)
      setActive((a) => (a === path ? (rest[Math.min(i, rest.length - 1)]?.path ?? null) : a))
    }
    if (!f.dirty && !recheck.current.has(path)) return drop()
    // the last edits are saved first; only a file that can't be written asks
    void (async () => {
      try {
        await auto.saveNow(path)
      } catch (err) {
        if (!(await window.api.ask(tr(`Could not save "${fileName(path)}":\n${errText(err)}\n\nClose anyway and discard the unsaved changes?`, `Không lưu được "${fileName(path)}":\n${errText(err)}\n\nVẫn đóng và bỏ các thay đổi chưa lưu?`)))) return
      }
      drop()
    })()
  }

  /** a .doc / .xls / .ppt saved as .docx / .xlsx / .pptx beside it, and opened for editing */
  const convert = (path: string, ext: string): void => {
    setBusy(true)
    setError('')
    void (async () => {
      const to = path.replace(/\.[^.\\/]+$/, `.${ext}`)
      const exists = await window.api.office.readFile(to).then(
        () => true,
        () => false
      )
      if (exists && !(await window.api.ask(tr(`"${fileName(to)}" already exists. Overwrite it?`, `Đã có file "${fileName(to)}". Ghi đè lên nó?`)))) return
      if (exists) await window.api.office.backup(to)
      // a read-only editor refuses to export; the tab closes right after
      await call(path, 'document:set-readonly', { readonly: false }, 10_000)
      await window.api.office.writeFile(to, (await exportFile(path, ext.toUpperCase())).data)
      await window.api.office.recentAdd(to).catch(() => {})
      close(path)
      await openPath(to)
    })()
      .catch((err: unknown) => setError(tr(`Could not convert ${fileName(path)}: ${errText(err)}`, `Không chuyển được ${fileName(path)}: ${errText(err)}`)))
      .finally(() => setBusy(false))
  }

  /* ---------- Claude's read tools ---------- */
  const tool = async (req: OfficeRequest): Promise<string> => {
    const f = findOpen(filesRef.current, active, req.args.file, WHAT[kind])
    // a file just opened (office_open) is read once its editor is up
    await until(() => filesRef.current.find((x) => x.path === f.path)?.state !== 'loading', 100_000)
    const now = filesRef.current.find((x) => x.path === f.path)
    if (!now) throw new Error(`${f.path} was closed`)
    if (now.state !== 'ready') throw new Error(now.error ?? `${fileName(f.path)} is still opening, try again`)
    const z = await unzip(await snapshot(f.path))
    const str = (k: string): string | undefined => (typeof req.args[k] === 'string' && req.args[k] ? (req.args[k] as string) : undefined)
    switch (req.tool) {
      case 'doc_read':
        return (await docText(z)) || `${fileName(f.path)} has no text.`
      case 'sheet_read':
        return sheetText(z, str('sheet'), str('range'))
      case 'slide_read': {
        const slides = await slideTexts(z)
        return [`${fileName(f.path)}: ${slides.length} slides`, ...pageList(str('slides'), slides.length).map((n) => `--- Slide ${n} ---\n${slides[n - 1] || '(no text)'}`)].join('\n')
      }
      case 'pdf_read': {
        const pages = await pdfPages(z)
        return [`${fileName(f.path)}: ${pages.length} pages`, ...pageList(str('pages'), pages.length).map((n) => `--- Page ${n} ---\n${pages[n - 1] || '(no text on this page: a scanned image?)'}`)].join('\n')
      }
    }
    throw new Error(`unknown tool ${req.tool}`)
  }

  useImperativeHandle(ref, () => ({
    open: openPath,
    tool,
    status: () =>
      filesRef.current.map(
        (f) => `${f.path === active ? '[on screen] ' : ''}${f.path}${f.dirty ? ' (unsaved changes)' : ''}${readonlyOf(f.path) ? ' (read-only)' : ''}${f.state === 'loading' ? ' (opening…)' : f.state === 'error' ? ` (could not open: ${f.error})` : ''}`
      )
  }))

  const t = useT()
  if (!file) return null
  const legacy = legacyTarget(file.path)
  const failed = install && 'error' in install ? install.error : null
  return (
    <div className={'of-ws' + (shown ? ' on' : '')}>
      <FileTabs
        files={files}
        active={active}
        icon={KIND_ICON[kind](13)}
        onShow={setActive}
        onClose={close}
        onAdd={onAdd}
        addTitle={kind === 'pdf' ? t('Open another PDF', 'Mở PDF khác') : t('Open another file / create new', 'Mở file khác / tạo mới')}
      >
        {busy && <Loader2 size={15} className="of-spin of-dim" />}
        <button className="of-tool of-ai" title={t('Open a Claude chat that works on this file', 'Mở chat Claude làm việc với file này')} onClick={() => void newChatFromOfficeFile(file.path)}>
          <Bot size={15} /> {t('Hand to AI', 'Giao cho AI')}
        </button>
        {legacy ? (
          <button
            className="of-tool"
            title={t(`The old .${extOf(file.path)} format is view-only. Save a .${legacy} copy beside it to edit.`, `Định dạng cũ .${extOf(file.path)} chỉ xem được. Lưu một bản .${legacy} cạnh nó để sửa.`)}
            disabled={busy || file.state !== 'ready'}
            onClick={() => convert(file.path, legacy)}
          >
            <FileOutput size={15} /> {t(`Save as .${legacy} to edit`, `Lưu thành .${legacy} để sửa`)}
          </button>
        ) : (
          kind !== 'pdf' && <SaveStatus dirty={file.dirty} s={auto.saveState[file.path]} note={note(t)} />
        )}
      </FileTabs>
      {error && (
        <p className="of-error of-pad" onClick={() => setError('')} title={t('Click to hide', 'Bấm để ẩn')}>
          {error}
        </p>
      )}
      <div className="of-oo">
        {origin &&
          files.map((f) => (
            <iframe
              key={`${f.path}#${f.gen}`}
              ref={(el) => {
                if (el) frames.current.set(f.path, el)
              }}
              className={f.path === active ? 'on' : ''}
              src={`${origin}/editor.html?embed=1&locale=${f.locale}`}
              title={fileName(f.path)}
            />
          ))}
        {!origin ? (
          <div className="of-oo-state">
            {failed ? (
              <>
                <p className="of-error">{failed}</p>
                <button className="of-action" onClick={() => void ensureEditor()}>
                  <RefreshCw size={15} /> {t('Try again', 'Thử lại')}
                </button>
              </>
            ) : install && 'total' in install ? (
              <>
                <b>{t('Downloading ONLYOFFICE (first time only)', 'Đang tải ONLYOFFICE (chỉ lần đầu)')}</b>
                <progress max={install.total} value={install.done} />
                <p className="of-dim">
                  {Math.round(install.done / 1048576)} / {Math.round(install.total / 1048576)} MB. {t('After that, files open without the internet.', 'Sau đó mở file không cần mạng.')}
                </p>
              </>
            ) : (
              <Loader2 size={22} className="of-spin of-dim" />
            )}
          </div>
        ) : file.state === 'loading' ? (
          <div className="of-oo-state">
            <Loader2 size={22} className="of-spin of-dim" />
            <p className="of-dim">{t(`Opening ${fileName(file.path)}…`, `Đang mở ${fileName(file.path)}…`)}</p>
          </div>
        ) : (
          file.state === 'error' && (
            <div className="of-oo-state">
              <p className="of-error">{file.error}</p>
              <button className="of-action" onClick={() => patch(file.path, { state: 'loading', error: undefined, gen: file.gen + 1 })}>
                <RefreshCw size={15} /> {t('Reopen', 'Mở lại')}
              </button>
            </div>
          )
        )}
      </div>
    </div>
  )
})
