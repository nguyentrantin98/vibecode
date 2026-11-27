import * as monaco from 'monaco-editor'
import { loader } from '@monaco-editor/react'
import EditorWorker from 'monaco-editor/editor/editor.worker?worker'
import JsonWorker from 'monaco-editor/languages/features/json/json.worker?worker'
import CssWorker from 'monaco-editor/languages/features/css/css.worker?worker'
import HtmlWorker from 'monaco-editor/languages/features/html/html.worker?worker'
import TsWorker from 'monaco-editor/languages/features/typescript/ts.worker?worker'
import { registerFallbackSymbols } from './symbols'

self.MonacoEnvironment = {
  getWorker(_id: string, label: string) {
    if (label === 'json') return new JsonWorker()
    if (label === 'css' || label === 'scss' || label === 'less') return new CssWorker()
    if (label === 'html' || label === 'handlebars' || label === 'razor') return new HtmlWorker()
    if (label === 'typescript' || label === 'javascript') return new TsWorker()
    return new EditorWorker()
  }
}

// We only want to *view and edit* files, not type-check a whole project we can't see.
monaco.typescript.typescriptDefaults.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: false })
monaco.typescript.javascriptDefaults.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: false })
monaco.typescript.typescriptDefaults.setCompilerOptions({
  jsx: monaco.typescript.JsxEmit.Preserve,
  target: monaco.typescript.ScriptTarget.ESNext,
  allowNonTsExtensions: true
})

monaco.editor.defineTheme('studio-dark', {
  base: 'vs-dark',
  inherit: true,
  rules: [
    // syntax colours after Xcode's default dark theme
    { token: 'comment', foreground: '7f8c98', fontStyle: 'italic' },
    { token: 'keyword', foreground: 'ff7ab2' },
    { token: 'string', foreground: 'ff8170' },
    { token: 'number', foreground: 'd9c97c' },
    { token: 'type', foreground: '6bdfff' },
    { token: 'type.identifier', foreground: '6bdfff' },
    { token: 'function', foreground: '67b7a4' },
    { token: 'variable', foreground: 'e5e5ea' },
    { token: 'tag', foreground: 'ff7ab2' },
    { token: 'attribute.name', foreground: 'd9c97c' },
    { token: 'delimiter', foreground: 'a1a1a6' }
  ],
  colors: {
    // the editor surface is --bg-2 in styles.css
    'editor.background': '#1e1e20',
    'editor.foreground': '#e5e5ea',
    'editorLineNumber.foreground': '#5c5c61',
    'editorLineNumber.activeForeground': '#c7c7cc',
    'editor.lineHighlightBackground': '#29292c',
    'editor.lineHighlightBorder': '#00000000',
    'editor.selectionBackground': '#0a84ff47',
    'editor.inactiveSelectionBackground': '#0a84ff26',
    'editorCursor.foreground': '#0a84ff',
    'editorIndentGuide.background1': '#2c2c2e',
    'editorIndentGuide.activeBackground1': '#48484a',
    'editorWhitespace.foreground': '#3a3a3c',
    'editorGutter.background': '#1e1e20',
    'editorWidget.background': '#2a2a2c',
    'editorWidget.border': '#3a3a3c',
    'editorSuggestWidget.background': '#2a2a2c',
    'editorSuggestWidget.selectedBackground': '#3a3a3c',
    'editorHoverWidget.background': '#2a2a2c',
    'scrollbarSlider.background': '#ffffff14',
    'scrollbarSlider.hoverBackground': '#ffffff24',
    'scrollbarSlider.activeBackground': '#ffffff30',
    'minimap.background': '#1e1e20',
    'diffEditor.insertedTextBackground': '#2ea04333',
    'diffEditor.removedTextBackground': '#f8514933',
    'diffEditor.insertedLineBackground': '#2ea0431a',
    'diffEditor.removedLineBackground': '#f851491a',
    'diffEditor.diagonalFill': '#ffffff08',
    'editorOverviewRuler.border': '#00000000'
  }
})

monaco.editor.defineTheme('studio-light', {
  base: 'vs',
  inherit: true,
  rules: [
    // syntax colours after Xcode's default light theme
    { token: 'comment', foreground: '5d6c79', fontStyle: 'italic' },
    { token: 'keyword', foreground: '9b2393' },
    { token: 'string', foreground: 'c41a16' },
    { token: 'number', foreground: '1c00cf' },
    { token: 'type', foreground: '0b4f79' },
    { token: 'type.identifier', foreground: '0b4f79' },
    { token: 'function', foreground: '326d74' },
    { token: 'variable', foreground: '1d1d1f' },
    { token: 'tag', foreground: '9b2393' },
    { token: 'attribute.name', foreground: '815f03' },
    { token: 'delimiter', foreground: '6e6e73' }
  ],
  colors: {
    'editor.background': '#ffffff',
    'editor.foreground': '#1d1d1f',
    'editorLineNumber.foreground': '#c7c7cc',
    'editorLineNumber.activeForeground': '#6e6e73',
    'editor.lineHighlightBackground': '#f2f2f7',
    'editor.lineHighlightBorder': '#00000000',
    'editor.selectionBackground': '#007aff38',
    'editor.inactiveSelectionBackground': '#007aff1f',
    'editorCursor.foreground': '#007aff',
    'editorIndentGuide.background1': '#ececf0',
    'editorIndentGuide.activeBackground1': '#d1d1d6',
    'editorGutter.background': '#ffffff',
    'editorWidget.background': '#ffffff',
    'editorWidget.border': '#d9d9de',
    'editorSuggestWidget.background': '#ffffff',
    'editorSuggestWidget.selectedBackground': '#e8e8ed',
    'editorHoverWidget.background': '#ffffff',
    'scrollbarSlider.background': '#00000018',
    'scrollbarSlider.hoverBackground': '#00000028',
    'scrollbarSlider.activeBackground': '#00000034',
    'minimap.background': '#ffffff',
    'diffEditor.insertedTextBackground': '#2f8a4e2e',
    'diffEditor.removedTextBackground': '#c53a322e',
    'diffEditor.insertedLineBackground': '#2f8a4e14',
    'diffEditor.removedLineBackground': '#c53a3214',
    'diffEditor.diagonalFill': '#1f1e1d0a',
    'editorOverviewRuler.border': '#00000000'
  }
})

loader.config({ monaco })
registerFallbackSymbols(monaco)

const extMap = new Map<string, string>()
const nameMap = new Map<string, string>()
/** File extensions / names → language; run again after editor extensions register languages (the first one to claim an extension keeps it). */
export function indexLanguages(): void {
  for (const lang of monaco.languages.getLanguages()) {
    for (const ext of lang.extensions ?? []) if (!extMap.has(ext.toLowerCase())) extMap.set(ext.toLowerCase(), lang.id)
    for (const n of lang.filenames ?? []) if (!nameMap.has(n.toLowerCase())) nameMap.set(n.toLowerCase(), lang.id)
  }
}
indexLanguages()

export function languageFor(path: string): string {
  const name = path.split(/[\\/]/).pop()?.toLowerCase() ?? ''
  if (name === 'dockerfile') return 'dockerfile'
  if (nameMap.has(name)) return nameMap.get(name)!
  const dot = name.lastIndexOf('.')
  if (dot < 0) return 'plaintext'
  return extMap.get(name.slice(dot)) ?? 'plaintext'
}

export const editorOptions: monaco.editor.IStandaloneEditorConstructionOptions = {
  fontFamily: '"JetBrains Mono", "Cascadia Code", Consolas, monospace',
  fontSize: 12,
  lineHeight: 18,
  fontLigatures: true,
  minimap: { enabled: true, scale: 1, renderCharacters: false, showSlider: 'mouseover' },
  smoothScrolling: true,
  cursorSmoothCaretAnimation: 'on',
  cursorBlinking: 'smooth',
  renderLineHighlight: 'all',
  scrollBeyondLastLine: false,
  padding: { top: 14, bottom: 14 },
  bracketPairColorization: { enabled: true },
  guides: { bracketPairs: 'active', indentation: true },
  stickyScroll: { enabled: true },
  automaticLayout: true,
  scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10, useShadows: false },
  overviewRulerBorder: false,
  renderWhitespace: 'selection',
  tabSize: 2
}

export { monaco }
