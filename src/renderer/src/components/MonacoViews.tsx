import { useEffect, useMemo, useRef, useState } from 'react'
import Editor, { type OnMount } from '@monaco-editor/react'
import { Braces, Columns2, FileText, GitCompare, Rows2 } from 'lucide-react'
import { openFile } from '../actions'
import { SlidePill } from './motion'
import { fileUri, useStore, type EditorTab } from '../store'
import { editorOptions, languageFor, monaco } from '../monaco'
import { ensureModel, getModel, isDirty, markTab, saveModel } from '../fileModels'
import { loadEditorExtensions } from '../editorExtensions'
import { FileIcon } from './icons'
import { useEditorFont } from './EditorFont'
import { IMAGE_RE, imagePreview } from '../attachments'
import { tr, useT } from '../i18n'

/* Everything that needs Monaco: loaded the first time a file or diff tab opens. */

void loadEditorExtensions()

function Breadcrumbs({ path }: { path: string }): React.JSX.Element {
  const t = useT()
  const root = useStore((s) => s.root) ?? ''
  const rel = path.toLowerCase().startsWith(root.toLowerCase()) ? path.slice(root.length).replace(/^[\\/]/, '') : path
  const parts = rel.split(/[\\/]/)
  return (
    <div className="breadcrumbs">
      {parts.map((p, i) => (
        <span key={i} className={i === parts.length - 1 ? 'crumb last' : 'crumb'}>
          {i === parts.length - 1 && <FileIcon name={p} size={13} />}
          {p}
          {i < parts.length - 1 && <span className="crumb-sep">›</span>}
        </span>
      ))}
      <button className="crumb-symbols" title={t('Go to function / symbol (Ctrl+Shift+O)', 'Đi tới hàm / ký hiệu (Ctrl+Shift+O)')} onClick={() => window.dispatchEvent(new Event('go-to-symbol'))}>
        <Braces size={13} /> {t('Symbols', 'Ký hiệu')}
      </button>
    </div>
  )
}

/* ================================ File editor ================================ */

// a theme from an installed extension, once Monaco has it; else the app's light / dark
const useMonacoTheme = (): string =>
  useStore((s) => (s.editorTheme && s.editorTheme === s.editorThemeLoaded ? s.editorTheme : s.themeResolved === 'light' ? 'studio-light' : 'studio-dark'))

export function FileEditor({ tab }: { tab: Extract<EditorTab, { kind: 'file' }> }): React.JSX.Element {
  const theme = useMonacoTheme()
  const font = useEditorFont()
  // a new object on every render made Monaco re-apply all its options each time
  const options = useMemo(() => ({ ...editorOptions, ...font }), [font])
  const onScreen = useStore((s) => s.activeTabId === tab.id)
  // One editor for every file tab: switching tabs swaps its model (Monaco keeps each file's scroll
  // and cursor) instead of tearing the whole editor down and building a new one.
  const [loaded, setLoaded] = useState<{ path: string; error?: string } | null>(null)

  const image = IMAGE_RE.test(tab.path)
  useEffect(() => {
    if (image) return
    let live = true
    ensureModel(tab.path).then((r) => live && setLoaded({ path: tab.path, error: r.error }))
    return () => {
      live = false
    }
  }, [tab.path, image])

  const mine = loaded?.path === tab.path ? loaded : null
  // The file on screen: this tab's as soon as its model exists (an already-open file switches in
  // the same frame); while a new file is still being read, the previous one stays up.
  const path = mine ? (mine.error ? null : tab.path) : getModel(tab.path) ? tab.path : loaded && !loaded.error ? loaded.path : null

  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null)
  // what the editor's commands act on (they are registered once, the file changes)
  const pathRef = useRef(path)
  useEffect(() => {
    pathRef.current = path
    if (onScreen) editorRef.current?.focus()
  }, [path, onScreen])

  // Ctrl+Shift+O, "@" in Ctrl+P or the breadcrumb button → "Go to Symbol" in the open file
  useEffect(() => {
    const go = (): void => {
      const ed = editorRef.current
      if (!ed || useStore.getState().activeTabId !== tab.id) return
      ed.focus()
      ed.trigger('vibe', 'editor.action.quickOutline', null)
    }
    // Ctrl+G from outside the editor, or ":" in Ctrl+P
    const line = (): void => {
      const ed = editorRef.current
      if (!ed || useStore.getState().activeTabId !== tab.id) return
      ed.focus()
      ed.trigger('vibe', 'editor.action.gotoLine', null)
    }
    window.addEventListener('go-to-symbol', go)
    window.addEventListener('go-to-line', line)
    return () => {
      window.removeEventListener('go-to-symbol', go)
      window.removeEventListener('go-to-line', line)
    }
  }, [tab.id])

  const onMount: OnMount = (editor) => {
    editorRef.current = editor
    editor.onDidDispose(() => editorRef.current === editor && (editorRef.current = null))
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      if (pathRef.current) void saveModel(pathRef.current)
    })
    editor.onDidChangeModelContent(() => {
      // Once the edit has settled: during an undo, or a reload from disk, this event fires before
      // the model is back at its saved version — reading it right away left a false "unsaved" dot.
      queueMicrotask(() => {
        const m = editor.getModel()
        if (m && pathRef.current) markTab(pathRef.current, isDirty(m))
      })
    })
    editor.focus()
  }

  if (image) return <ImageFile path={tab.path} />
  if (mine?.error) return <div className="editor-message">{mine.error}</div>
  if (!path) return <div className="editor-message" />
  return (
    <>
      <Breadcrumbs path={path} />
      <div className="monaco-wrap">
        <Editor
          path={fileUri(path)}
          language={languageFor(path)}
          theme={theme}
          options={options}
          keepCurrentModel
          onMount={onMount}
        />
      </div>
    </>
  )
}

/** A picture opened as a file: shown instead of "binary file". */
function ImageFile({ path }: { path: string }): React.JSX.Element {
  const t = useT()
  const [src, setSrc] = useState<{ path: string; src?: string } | null>(null)
  useEffect(() => {
    let live = true
    imagePreview(path).then((s) => live && setSrc({ path, src: s }))
    return () => {
      live = false
    }
  }, [path])
  const mine = src?.path === path ? src : null
  return (
    <>
      <Breadcrumbs path={path} />
      {mine && !mine.src ? (
        <div className="editor-message">{t('This picture cannot be shown (missing, or larger than 15 MB).', 'Không hiển thị được ảnh này (không tồn tại, hoặc lớn hơn 15 MB).')}</div>
      ) : (
        <div className="image-file">{mine?.src && <img src={mine.src} alt={path} draggable={false} />}</div>
      )}
    </>
  )
}

/* ================================ Diff view ================================ */

/**
 * One diff editor for every diff tab (it stays mounted): switching files swaps its two models in a
 * single step instead of tearing the editor down and building a new one, and the previous diff
 * stays on screen until the next one has been read - no blank frame in between.
 */
export function DiffView({ tab }: { tab: Extract<EditorTab, { kind: 'diff' }> }): React.JSX.Element {
  const t = useT()
  const theme = useMonacoTheme()
  const font = useEditorFont()
  const gitRoot = useStore((s) => s.git.root)
  const file = useStore((s) => s.git.files.find((f) => f.abs.toLowerCase() === tab.path.toLowerCase()))
  const sideBySide = useStore((s) => s.diffSideBySide)
  const [texts, setTexts] = useState<{ id: string; original: string; modified: string } | null>(null)
  const [version, setVersion] = useState(0)
  const hostRef = useRef<HTMLDivElement>(null)
  const diffRef = useRef<monaco.editor.IStandaloneDiffEditor | null>(null)

  useEffect(() => {
    const onChange = (e: Event): void => {
      const paths = (e as CustomEvent<string[]>).detail
      if (paths.some((p) => p.toLowerCase() === tab.path.toLowerCase())) setVersion((v) => v + 1)
    }
    window.addEventListener('fs-changed', onChange)
    return () => window.removeEventListener('fs-changed', onChange)
  }, [tab.path])

  const commit = tab.commit
  // a commit changes HEAD, not the file: the status line changing re-reads the diff too
  const fileSig = commit ? '' : file ? `${file.status}:${file.added}:${file.deleted}` : '-'
  useEffect(() => {
    if (!gitRoot) return
    let live = true
    Promise.all(
      commit
        ? [window.api.git.show(gitRoot, commit.hash + '^', tab.rel), window.api.git.show(gitRoot, commit.hash, tab.rel)]
        : [
            window.api.git.original(gitRoot, tab.rel),
            window.api.fs
              .readFile(tab.path)
              .then((r) => (r.binary ? tr('[binary file]', '[tệp nhị phân]') : r.content))
              .catch(() => '')
          ]
    ).then(([original, modified]) => live && setTexts({ id: tab.id, original, modified }))
    return () => {
      live = false
    }
  }, [gitRoot, tab.id, tab.rel, tab.path, commit, version, fileSig])

  const options = useMemo<monaco.editor.IDiffEditorConstructionOptions>(
    () => ({
      ...editorOptions,
      ...font,
      readOnly: true,
      originalEditable: false,
      renderSideBySide: sideBySide,
      useInlineViewWhenSpaceIsLimited: true,
      ignoreTrimWhitespace: false,
      renderOverviewRuler: true,
      hideUnchangedRegions: { enabled: true, contextLineCount: 4, minimumLineCount: 6, revealLineCount: 20 },
      diffWordWrap: 'off',
      minimap: { enabled: false },
      stickyScroll: { enabled: false }
    }),
    [font, sideBySide]
  )
  const optionsRef = useRef(options)
  optionsRef.current = options

  // created once; its models go with it
  useEffect(() => {
    const d = monaco.editor.createDiffEditor(hostRef.current!, optionsRef.current)
    diffRef.current = d
    return () => {
      const m = d.getModel()
      d.dispose()
      m?.original.dispose()
      m?.modified.dispose()
      diffRef.current = null
    }
  }, [])
  useEffect(() => diffRef.current?.updateOptions(options), [options])
  useEffect(() => monaco.editor.setTheme(theme), [theme])

  // the texts just read → the diff on screen
  const shownId = useRef<string | null>(null)
  useEffect(() => {
    const d = diffRef.current
    if (!d || !texts || texts.id !== tab.id) return
    const prev = d.getModel()
    // same tab, file changed on disk: update in place (keeps the scroll position)
    if (prev && shownId.current === tab.id) {
      const pairs: [monaco.editor.ITextModel, string][] = [
        [prev.original, texts.original],
        [prev.modified, texts.modified]
      ]
      for (const [m, text] of pairs) {
        if (m.getValue() !== text) m.pushEditOperations([], [{ range: m.getFullModelRange(), text }], () => null)
      }
      return
    }
    // throwaway models (Monaco names them): never mixed up with the file editor's models
    const lang = languageFor(tab.path)
    const original = monaco.editor.createModel(texts.original, lang)
    const modified = monaco.editor.createModel(texts.modified, lang)
    d.setModel({ original, modified })
    shownId.current = tab.id
    prev?.original.dispose()
    prev?.modified.dispose()
  }, [texts, tab.id, tab.path])

  const label = commit
    ? `${commit.short} · ${commit.subject}`
    : file?.status === '?' || file?.status === 'A'
      ? t('New file', 'Tệp mới')
      : file?.status === 'D'
        ? t('Deleted', 'Đã xoá')
        : t('Working tree ↔ HEAD', 'Thư mục làm việc ↔ HEAD')

  return (
    <>
      <div className="diff-header">
        <div className="diff-title">
          <GitCompare size={14} color="#5aa9ff" />
          <span className="diff-path">{tab.rel}</span>
          <span className="diff-label">{label}</span>
          {file && !commit && (
            <span className="diff-stats">
              <span className="add">+{file.added}</span>
              <span className="del">−{file.deleted}</span>
            </span>
          )}
        </div>
        <div className="diff-actions">
          <div className="seg">
            <SlidePill />
            <button className={sideBySide ? 'on' : ''} onClick={() => useStore.setState({ diffSideBySide: true })} title={t('Side by side', 'Hai bên')}>
              <Columns2 size={14} />
            </button>
            <button className={!sideBySide ? 'on' : ''} onClick={() => useStore.setState({ diffSideBySide: false })} title={t('Inline', 'Cùng dòng')}>
              <Rows2 size={14} />
            </button>
          </div>
          {(commit || file?.status !== 'D') && (
            <button className="btn btn-ghost btn-sm" onClick={() => openFile(tab.path)}>
              <FileText size={13} /> {t('Open file', 'Mở tệp')}
            </button>
          )}
        </div>
      </div>
      <div className="monaco-wrap" ref={hostRef} />
    </>
  )
}

