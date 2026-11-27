import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Check, Download, FileUp, Loader, Palette, Puzzle, Search, Trash2 } from 'lucide-react'
import { useStore } from '../store'
import { useT } from '../i18n'

interface Found {
  id: string
  name: string
  publisher: string
  description: string
  version: string
  download: string
  icon?: string
}

/** Open VSX: the open registry of VS Code extensions (the Marketplace's terms don't allow other editors). */
async function searchOpenVsx(query: string): Promise<Found[]> {
  const r = await fetch(`https://open-vsx.org/api/-/search?query=${encodeURIComponent(query)}&size=30`)
  if (!r.ok) throw new Error(`Open VSX: HTTP ${r.status}`)
  const j = await r.json()
  return (j.extensions ?? [])
    .filter((x: any) => x.files?.download && !x.deprecated)
    .map((x: any) => ({
      id: `${x.namespace}.${x.name}`.toLowerCase(),
      name: x.displayName || x.name,
      publisher: x.namespace,
      description: x.description ?? '',
      version: x.version ?? '',
      download: x.files.download,
      icon: x.files.icon
    }))
}

const ext = (): Promise<typeof import('../editorExtensions')> => import('../editorExtensions')

/**
 * Puzzle button at the end of the editor tab bar: VS Code extensions for the code editor, searched on
 * Open VSX or installed from a .vsix file, and the color theme picked from them.
 */
export function EditorExtensionsButton(): React.JSX.Element {
  const t = useT()
  const exts = useStore((s) => s.editorExts)
  const picked = useStore((s) => s.editorTheme)
  const [at, setAt] = useState<{ left: number; top: number } | null>(null)
  const [query, setQuery] = useState('')
  const [found, setFound] = useState<Found[] | null>(null)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const ref = useRef<HTMLDivElement>(null)
  const menu = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!at) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node) && !menu.current?.contains(e.target as Node)) setAt(null)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setAt(null)
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [at])

  const run = async (key: string, fn: () => Promise<void>): Promise<void> => {
    setBusy(key)
    setError('')
    try {
      await fn()
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e).replace(/^Error: /, ''))
    } finally {
      setBusy('')
    }
  }

  const install = (key: string, source: string): Promise<void> =>
    run(key, async () => {
      const x = await window.api.editorExt.install(source)
      const m = await ext()
      await m.loadEditorExtensions()
      const info = useStore.getState().editorExts.find((e) => e.id === x.id)
      // nothing in it the editor can use: it only runs code (a language server, commands…)
      if (!info || (!info.themes.length && !info.languages.length && !info.snippets)) {
        await window.api.editorExt.remove(x.id)
        await m.loadEditorExtensions()
        throw new Error(
          t(
            `${info?.name ?? x.id} has no color theme, syntax colouring or snippets: it needs VS Code itself to run its code, so it does not work here.`,
            `${info?.name ?? x.id} không có theme màu, tô màu cú pháp hay snippet: nó cần chính VS Code để chạy code của nó, nên không dùng được ở đây.`
          )
        )
      }
      // a theme extension: show its first theme right away
      if (info.themes.length && !info.themes.some((th) => th.id === useStore.getState().editorTheme)) useStore.setState({ editorTheme: info.themes[0].id })
    })

  const search = (): Promise<void> =>
    run('search', async () => {
      setFound(await searchOpenVsx(query.trim()))
    })

  const themes = exts.flatMap((x) => x.themes)

  return (
    <div className="font-pick" ref={ref}>
      <button
        className={`font-pick-btn${at ? ' on' : ''}`}
        title={t('Editor extensions (VS Code themes, syntax colouring, snippets)', 'Extension cho editor (theme, tô màu cú pháp, snippet của VS Code)')}
        onClick={(e) => {
          if (at) return setAt(null)
          const r = e.currentTarget.getBoundingClientRect()
          setAt({ left: Math.max(8, Math.min(r.right - 380, window.innerWidth - 388)), top: r.bottom + 6 })
          setError('')
          void ext().then((m) => m.loadEditorExtensions())
        }}
      >
        <Puzzle size={14} />
      </button>
      {at &&
        createPortal(
          <div className="ext-menu edext-menu" ref={menu} style={at}>
            <div className="sb-menu-title">{t('Color theme', 'Theme màu')}</div>
            <button className={`edext-theme${picked ? '' : ' on'}`} onClick={() => useStore.setState({ editorTheme: '' })}>
              <Palette size={13} className="ext-icon" />
              <span className="ext-name">{t("Default (follows the app's light / dark)", 'Mặc định (theo sáng / tối của app)')}</span>
              {!picked && <Check size={13} />}
            </button>
            {themes.map((th) => (
              <button key={th.id} className={`edext-theme${picked === th.id ? ' on' : ''}`} onClick={() => useStore.setState({ editorTheme: th.id })}>
                <Palette size={13} className="ext-icon" />
                <span className="ext-name">{th.label}</span>
                {picked === th.id && <Check size={13} />}
              </button>
            ))}

            <div className="sb-menu-title">{t('Installed', 'Đã cài')}</div>
            {!exts.length && <div className="ext-empty">{t('None yet.', 'Chưa có.')}</div>}
            {exts.map((x) => {
              const what = [
                x.themes.length && t(`${x.themes.length} theme${x.themes.length > 1 ? 's' : ''}`, `${x.themes.length} theme`),
                ...x.languages,
                x.snippets && t(`${x.snippets} snippet file${x.snippets > 1 ? 's' : ''}`, `${x.snippets} tệp snippet`)
              ].filter(Boolean)
              return (
                <div key={x.id} className="ext-row">
                  <Puzzle size={14} className="ext-icon" />
                  <span className="ext-name" title={`${x.id} ${x.version}\n${x.description}`}>
                    {x.name}
                    <span className="edext-sub">{what.join(' · ')}</span>
                  </span>
                  <button
                    className="icon-btn"
                    title={t('Remove', 'Gỡ')}
                    disabled={!!busy}
                    onClick={async () => {
                      if (!(await window.api.ask(t(`Remove ${x.name}?`, `Gỡ ${x.name}?`)))) return
                      void run(x.id, async () => {
                        await window.api.editorExt.remove(x.id)
                        await (await ext()).loadEditorExtensions()
                      })
                    }}
                  >
                    {busy === x.id ? <Loader size={13} className="task-spin" /> : <Trash2 size={13} />}
                  </button>
                </div>
              )
            })}

            <form
              className="ext-add"
              onSubmit={(e) => {
                e.preventDefault()
                if (query.trim()) void search()
              }}
            >
              <input value={query} placeholder={t('Search Open VSX (e.g. dracula, zig, vue)', 'Tìm trên Open VSX (vd: dracula, zig, vue)')} spellCheck={false} onChange={(e) => setQuery(e.target.value)} />
              <button className="btn btn-primary btn-sm" disabled={!query.trim() || !!busy}>
                {busy === 'search' ? <Loader size={13} className="task-spin" /> : <Search size={13} />} {t('Search', 'Tìm')}
              </button>
            </form>
            {found?.length === 0 && <div className="ext-empty">{t('Nothing found.', 'Không tìm thấy.')}</div>}
            {found?.map((f) => {
              const have = exts.find((x) => x.id === f.id)
              return (
                <div key={f.id} className="ext-row edext-found">
                  {f.icon ? <img className="edext-icon" src={f.icon} alt="" loading="lazy" /> : <Puzzle size={14} className="ext-icon" />}
                  <span className="ext-name" title={f.description}>
                    {f.name}
                    <span className="edext-sub">
                      {f.publisher} · {f.description}
                    </span>
                  </span>
                  {have && have.version === f.version ? (
                    <span className="ext-tag">{t('installed', 'đã cài')}</span>
                  ) : (
                    <button className="btn btn-sm" disabled={!!busy} onClick={() => void install(f.id, f.download)}>
                      {busy === f.id ? <Loader size={13} className="task-spin" /> : <Download size={13} />} {have ? t('Update', 'Cập nhật') : t('Install', 'Cài')}
                    </button>
                  )}
                </div>
              )
            })}
            <button
              className="ext-folder"
              disabled={!!busy}
              onClick={async () => {
                const files = await window.api.app.pickFiles()
                if (!files.length) return
                const vsix = files.find((f) => f.toLowerCase().endsWith('.vsix'))
                if (vsix) void install('file', vsix)
                else setError(t('Pick a .vsix file.', 'Hãy chọn một tệp .vsix.'))
              }}
            >
              {busy === 'file' ? <Loader size={13} className="task-spin" /> : <FileUp size={13} />} {t('Install from a .vsix file…', 'Cài từ tệp .vsix…')}
            </button>
            {error && <div className="ext-error">{error}</div>}
            <div className="ext-note">
              {t(
                'Works: color themes, syntax colouring for new languages, snippets. Extensions that run code (ESLint, Prettier, Vim, language servers…) need VS Code itself and do not work here.',
                'Dùng được: theme màu, tô màu cú pháp cho ngôn ngữ mới, snippet. Extension cần chạy code (ESLint, Prettier, Vim, language server…) cần chính VS Code nên không chạy ở đây.'
              )}
            </div>
          </div>,
          document.body
        )}
    </div>
  )
}
