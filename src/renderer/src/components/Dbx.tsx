import { useCallback, useEffect, useRef, useState } from 'react'
import { Database, Download, Loader2, RefreshCw } from 'lucide-react'
import { useStore } from '../store'
import { usePlacedPage } from './Browser'
import { useT } from '../i18n'

/*
 * dbX tab: DBX (github.com/t8y2/dbx), a database client for 100+ databases, run by the app
 * (dbx.zig) and shown in a native page like a Web tab. Claude uses the same connections through
 * the vibe-dbx tools.
 */

type State =
  | { kind: 'checking' }
  | { kind: 'absent'; size: number }
  | { kind: 'downloading'; done: number; total: number }
  | { kind: 'starting' }
  | { kind: 'ready'; origin: string; run: number }
  | { kind: 'error'; message: string }

const errText = (e: unknown): string => (e instanceof Error ? e.message : String(e))
const mb = (n: number): number => Math.round(n / 1048576)

export function DbxPane(): React.JSX.Element {
  const t = useT()
  const shown = useStore((s) => s.centerView === 'db')
  const [state, setState] = useState<State>({ kind: 'checking' })

  const start = useCallback(async () => {
    try {
      const r = await window.api.dbx.start()
      // same run: the page is still logged in, keep the object (no re-render of the page)
      setState((s) => (s.kind === 'ready' && s.origin === r.origin && s.run === r.run ? s : { kind: 'ready', ...r }))
    } catch (e) {
      setState({ kind: 'error', message: errText(e) })
    }
  }, [])

  const install = async (): Promise<void> => {
    setState({ kind: 'downloading', done: 0, total: 0 })
    try {
      await window.api.dbx.install()
    } catch (e) {
      return setState({ kind: 'error', message: errText(e) })
    }
    setState({ kind: 'starting' })
    await start()
  }

  useEffect(() => window.api.dbx.onProgress((done, total) => setState({ kind: 'downloading', done, total })), [])

  useEffect(() => {
    void window.api.dbx
      .status()
      .then((s) => {
        if (!s.installed) return setState({ kind: 'absent', size: s.downloadSize })
        setState({ kind: 'starting' })
        return start()
      })
      .catch((e) => setState({ kind: 'error', message: errText(e) }))
  }, [start])

  // back on the tab: DBX may have stopped meanwhile (it is started again, and the page logs in again)
  useEffect(() => {
    if (shown && state.kind === 'ready') void start()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shown])

  if (state.kind === 'ready') return <DbxPage origin={state.origin} run={state.run} live={shown} />
  return (
    <div className="dbx-state">
      <Database size={30} className="dbx-dim" />
      <b>DBX</b>
      {state.kind === 'absent' && (
        <>
          <p className="dbx-dim">
            {t(
              'A database client for SQL Server, PostgreSQL, MySQL, SQLite, Oracle, MongoDB, Redis and 100+ more: browse schemas, run queries, edit data, ER diagrams. Claude can query the same connections from any chat.',
              'Trình quản lý cơ sở dữ liệu cho SQL Server, PostgreSQL, MySQL, SQLite, Oracle, MongoDB, Redis và hơn 100 loại khác: duyệt schema, chạy truy vấn, sửa dữ liệu, sơ đồ ER. Claude truy vấn được chính các kết nối này từ mọi chat.'
            )}
          </p>
          <button className="btn btn-primary" onClick={() => void install()}>
            <Download size={14} /> {t(`Download DBX (${mb(state.size)} MB, first time only)`, `Tải DBX (${mb(state.size)} MB, chỉ lần đầu)`)}
          </button>
          <p className="dbx-dim dbx-small">
            {t('Open source (Apache-2.0), github.com/t8y2/dbx. It runs on this computer only; your SQL Server connections from the old Database tab are added to it.', 'Mã nguồn mở (Apache-2.0), github.com/t8y2/dbx. Chỉ chạy trên máy này; các kết nối SQL Server của tab Database cũ được thêm vào nó.')}
          </p>
        </>
      )}
      {state.kind === 'downloading' && (
        <>
          <progress max={state.total || 1} value={state.done} />
          <p className="dbx-dim">
            {state.total ? `${mb(state.done)} / ${mb(state.total)} MB` : t('Downloading…', 'Đang tải…')}
          </p>
        </>
      )}
      {(state.kind === 'checking' || state.kind === 'starting') && (
        <p className="dbx-dim">
          <Loader2 size={14} className="spin" /> {state.kind === 'starting' ? t('Starting DBX…', 'Đang khởi động DBX…') : ''}
        </p>
      )}
      {state.kind === 'error' && (
        <>
          <p className="dbx-error">{state.message}</p>
          <button
            className="btn btn-ghost"
            onClick={() => {
              setState({ kind: 'checking' })
              void window.api.dbx.status().then((s) => (s.installed ? (setState({ kind: 'starting' }), start()) : setState({ kind: 'absent', size: s.downloadSize })))
            }}
          >
            <RefreshCw size={14} /> {t('Try again', 'Thử lại')}
          </button>
        </>
      )}
    </div>
  )
}

let labelSeq = 0

/** DBX's page. It first opens a small page of DBX (its login check), logs in there, then goes to DBX itself. */
function DbxPage({ origin, run, live }: { origin: string; run: number; live: boolean }): React.JSX.Element {
  const t = useT()
  const viewRef = useRef<HTMLDivElement>(null)
  const [label] = useState(() => `dbx-${++labelSeq}`)
  const [ready, setReady] = useState(false)
  const [error, setError] = useState('')
  const dark = useStore((s) => s.themeResolved !== 'light')
  const darkRef = useRef(dark)
  darkRef.current = dark
  const check = `${origin}/api/auth/check`

  useEffect(() => {
    void window.api.browser.open(label, '__dbx', check).catch((e) => setError(errText(e)))
    return () => window.api.browser.close(label)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [label])

  // once per load of the check page (it reports itself loaded more than once; a second login
  // would race the first one's navigation)
  const loggingIn = useRef(false)

  // DBX restarted (new password): log in again
  const firstRun = useRef(run)
  useEffect(() => {
    if (run === firstRun.current) return
    firstRun.current = run
    loggingIn.current = false
    setReady(false)
    void window.api.browser.navigate(label, check).catch(() => {})
  }, [run, label, check])

  useEffect(
    () =>
      window.api.browser.onNav((l, n) => {
        if (l !== label || n.loading || !n.url) return
        if (n.url.startsWith(check)) {
          if (loggingIn.current) return
          loggingIn.current = true
          setError('')
          void window.api.dbx.login(label, darkRef.current).catch((e) => {
            loggingIn.current = false
            setError(errText(e))
          })
        } else if (n.url.startsWith(origin)) {
          loggingIn.current = false
          setReady(true)
        }
      }),
    [label, check, origin]
  )

  usePlacedPage(viewRef, label, live, live, 1, !ready)

  return (
    <div className="dbx-page">
      <div ref={viewRef} className="dbx-view" />
      {!ready && (
        <div className="dbx-state">
          {error ? (
            <>
              <p className="dbx-error">{error}</p>
              <button className="btn btn-ghost" onClick={() => void window.api.browser.navigate(label, check).catch(() => {})}>
                <RefreshCw size={14} /> {t('Try again', 'Thử lại')}
              </button>
            </>
          ) : (
            <p className="dbx-dim">
              <Loader2 size={14} className="spin" /> {t('Opening DBX…', 'Đang mở DBX…')}
            </p>
          )}
        </div>
      )}
    </div>
  )
}
