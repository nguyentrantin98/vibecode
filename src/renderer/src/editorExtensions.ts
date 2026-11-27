/**
 * VS Code extensions the user installed for the code editor (from Open VSX or a .vsix file, kept by
 * src-zig/src/editorext.zig). Monaco has no extension host, so only what package.json declares is
 * used: color themes, TextMate grammars (syntax colours) with their language settings, and snippets.
 * Languages Monaco already knows keep their own colouring; extensions only add the ones it lacks.
 */
import { INITIAL, Registry, parseRawGrammar, type IGrammar, type StateStack } from 'vscode-textmate'
import { createOnigScanner, createOnigString, loadWASM } from 'vscode-oniguruma'
import onigWasm from 'vscode-oniguruma/release/onig.wasm?url'
import { indexLanguages, languageFor, monaco } from './monaco'
import { useStore, type EditorExtInfo } from './store'
import type { EditorExt } from '../../shared/types'

/** JSON as VS Code writes it: comments and trailing commas allowed. */
export function parseJsonc(text: string): any {
  let out = ''
  let i = 0
  while (i < text.length) {
    const ch = text[i]
    if (ch === '"') {
      const start = i++
      while (i < text.length && text[i] !== '"') i += text[i] === '\\' ? 2 : 1
      out += text.slice(start, ++i)
    } else if (ch === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++
    } else if (ch === '/' && text[i + 1] === '*') {
      const end = text.indexOf('*/', i + 2)
      i = end < 0 ? text.length : end + 2
    } else if (ch === ',' && /^\s*[}\]]/.test(text.slice(i + 1, i + 200))) {
      i++
    } else {
      out += ch
      i++
    }
  }
  return JSON.parse(out.replace(/^﻿/, ''))
}

const join = (dir: string, rel: string): string => dir.replace(/[\\/]+$/, '') + '/' + rel.replace(/^\.?[\\/]/, '')

async function readText(path: string): Promise<string | null> {
  const r = await window.api.fs.readFile(path).catch(() => null)
  return r && !r.binary && !r.tooLarge ? r.content : null
}

/* ---------------- themes ---------------- */

interface ThemeDef {
  label: string
  uiTheme: string
  path: string
  dir: string
}
const themes = new Map<string, ThemeDef>()

const themeId = (extId: string, label: string): string => ('ext-' + extId + '-' + label).toLowerCase().replace(/[^a-z0-9-]+/g, '-')

const HEX = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i
/** '#abc' / '#abcd' / '#aabbcc' / '#aabbccdd' → 'aabbcc' (Monaco's token rules take no alpha) */
function ruleColor(c: unknown): string | undefined {
  if (typeof c !== 'string' || !HEX.test(c)) return undefined
  const h = c.slice(1)
  return (h.length <= 4 ? [...h.slice(0, 3)].map((x) => x + x).join('') : h.slice(0, 6)).toLowerCase()
}

/** A theme file with the files it `include`s merged under it. */
async function readTheme(path: string, depth = 0): Promise<{ colors: Record<string, string>; tokenColors: any[] }> {
  const text = await readText(path)
  if (text == null) throw new Error('cannot read ' + path)
  const j = parseJsonc(text)
  const base = j.include && depth < 5 ? await readTheme(join(path.replace(/[\\/][^\\/]*$/, ''), j.include), depth + 1) : { colors: {}, tokenColors: [] }
  return {
    colors: { ...base.colors, ...(j.colors ?? {}) },
    tokenColors: [...base.tokenColors, ...(Array.isArray(j.tokenColors) ? j.tokenColors : [])]
  }
}

/** TextMate scopes → the token names Monaco's own (Monarch) colouring uses, so themes also colour the built-in languages. */
const MONARCH: [string, string[]][] = [
  ['comment', ['comment']],
  ['string', ['string']],
  ['string.regexp', ['regexp']],
  ['constant.numeric', ['number']],
  ['constant.language', ['keyword']],
  ['keyword', ['keyword']],
  ['storage', ['keyword']],
  ['storage.type', ['keyword']],
  ['keyword.operator', ['operator']],
  ['entity.name.type', ['type', 'type.identifier']],
  ['support.type', ['type']],
  ['entity.name.function', ['function']],
  ['variable', ['variable', 'identifier']],
  ['entity.name.tag', ['tag']],
  ['entity.other.attribute-name', ['attribute.name']],
  ['punctuation', ['delimiter']]
]

function toMonaco(def: ThemeDef, t: { colors: Record<string, string>; tokenColors: any[] }): monaco.editor.IStandaloneThemeData {
  const colors: Record<string, string> = {}
  for (const [k, v] of Object.entries(t.colors)) if (typeof v === 'string' && HEX.test(v)) colors[k] = v
  // every plain scope a rule names: a token here carries only its innermost scope, so selectors that
  // depend on the scopes around it ("a b", "a > b", "a - b") can't be honoured and are left out
  const entries: { scope: string; settings: any }[] = []
  for (const tc of t.tokenColors) {
    if (!tc?.settings) continue
    const scopes: string[] = Array.isArray(tc.scope) ? tc.scope : typeof tc.scope === 'string' ? tc.scope.split(',') : ['']
    for (const s of scopes.map((x) => String(x).trim())) if (!/\s/.test(s)) entries.push({ scope: s, settings: tc.settings })
  }
  const rule = (token: string, st: any): monaco.editor.ITokenThemeRule => ({
    token,
    foreground: ruleColor(st.foreground),
    background: ruleColor(st.background),
    fontStyle: typeof st.fontStyle === 'string' ? st.fontStyle : undefined
  })
  const rules: monaco.editor.ITokenThemeRule[] = []
  for (const [scope, tokens] of MONARCH) {
    // the rule that would colour this scope: the longest selector it starts with
    let best: { scope: string; settings: any } | undefined
    for (const e of entries) if (e.scope && (scope === e.scope || scope.startsWith(e.scope + '.')) && (!best || e.scope.length >= best.scope.length)) best = e
    if (best) for (const tok of tokens) rules.push(rule(tok, best.settings))
  }
  for (const e of entries) rules.push(rule(e.scope, e.settings))
  const base = def.uiTheme === 'vs' ? 'vs' : def.uiTheme === 'hc-black' ? 'hc-black' : def.uiTheme === 'hc-light' ? 'hc-light' : 'vs-dark'
  return { base, inherit: true, rules, colors }
}

/** Gives Monaco the theme picked in the store (read from disk the first time). */
async function loadPickedTheme(): Promise<void> {
  const id = useStore.getState().editorTheme
  if (!id || id === useStore.getState().editorThemeLoaded) return
  const def = themes.get(id)
  if (!def) return
  try {
    monaco.editor.defineTheme(id, toMonaco(def, await readTheme(join(def.dir, def.path))))
    if (useStore.getState().editorTheme === id) useStore.setState({ editorThemeLoaded: id })
  } catch (e) {
    console.warn('editor theme', id, e)
  }
}
useStore.subscribe((s, prev) => {
  if (s.editorTheme !== prev.editorTheme) void loadPickedTheme()
})

/* ---------------- grammars (TextMate) ---------------- */

const grammars = new Map<string, { dir: string; path: string }>()
/** scope → the grammars injected into it */
const injections = new Map<string, string[]>()

let registry: Registry | null = null
function getRegistry(): Registry {
  registry ??= new Registry({
    // the regex engine VS Code's grammars are written for, loaded the first time one is used
    onigLib: fetch(onigWasm)
      .then((r) => r.arrayBuffer())
      .then((buf) => loadWASM(buf))
      .then(() => ({ createOnigScanner, createOnigString })),
    loadGrammar: async (scope) => {
      const g = grammars.get(scope)
      const text = g ? await readText(join(g.dir, g.path)) : null
      return text == null ? null : parseRawGrammar(text, g!.path)
    },
    getInjections: (scope) => injections.get(scope)
  })
  return registry
}

class TmState implements monaco.languages.IState {
  constructor(readonly stack: StateStack) {}
  clone(): TmState {
    return new TmState(this.stack)
  }
  equals(other: monaco.languages.IState): boolean {
    return other instanceof TmState && other.stack.equals(this.stack)
  }
}

async function tokensProvider(scope: string): Promise<monaco.languages.TokensProvider> {
  const grammar: IGrammar | null = await getRegistry().loadGrammar(scope)
  if (!grammar) throw new Error('no grammar ' + scope)
  return {
    getInitialState: () => new TmState(INITIAL),
    tokenize: (line, state) => {
      const r = grammar.tokenizeLine(line, (state as TmState).stack, 500)
      // the innermost scope names the token; the theme colours it by its longest matching rule
      return { endState: new TmState(r.ruleStack), tokens: r.tokens.map((t) => ({ startIndex: t.startIndex, scopes: t.scopes[t.scopes.length - 1] })) }
    }
  }
}

/* ---------------- language settings ---------------- */

function regex(v: any): RegExp | undefined {
  try {
    if (typeof v === 'string') return new RegExp(v)
    if (v && typeof v.pattern === 'string') return new RegExp(v.pattern, v.flags)
  } catch {
    /* a pattern JavaScript can't read */
  }
  return undefined
}

function toConfig(j: any): monaco.languages.LanguageConfiguration {
  const pairs = (list: any): monaco.languages.IAutoClosingPair[] | undefined =>
    Array.isArray(list) ? list.map((p: any) => (Array.isArray(p) ? { open: p[0], close: p[1] } : { open: p.open, close: p.close })) : undefined
  const inc = regex(j.indentationRules?.increaseIndentPattern)
  const dec = regex(j.indentationRules?.decreaseIndentPattern)
  const start = regex(j.folding?.markers?.start)
  const end = regex(j.folding?.markers?.end)
  return {
    comments: j.comments,
    brackets: j.brackets,
    autoClosingPairs: pairs(j.autoClosingPairs),
    surroundingPairs: pairs(j.surroundingPairs),
    wordPattern: regex(j.wordPattern),
    indentationRules: inc && dec ? { increaseIndentPattern: inc, decreaseIndentPattern: dec } : undefined,
    folding: j.folding ? { offSide: j.folding.offSide, markers: start && end ? { start, end } : undefined } : undefined
  }
}

/* ---------------- snippets ---------------- */

interface Snippet {
  prefix: string
  body: string
  name: string
  description?: string
}

async function readSnippets(path: string): Promise<Snippet[]> {
  const text = await readText(path)
  if (text == null) return []
  const out: Snippet[] = []
  for (const [name, s] of Object.entries<any>(parseJsonc(text) ?? {})) {
    if (!s || s.body == null) continue
    const body = Array.isArray(s.body) ? s.body.join('\n') : String(s.body)
    const description = Array.isArray(s.description) ? s.description.join('\n') : s.description
    for (const prefix of Array.isArray(s.prefix) ? s.prefix : [s.prefix ?? name]) out.push({ prefix: String(prefix), body, name, description })
  }
  return out
}

function snippetProvider(path: string): monaco.languages.CompletionItemProvider {
  let list: Promise<Snippet[]> | null = null
  return {
    provideCompletionItems: async (model, pos) => {
      list ??= readSnippets(path).catch(() => [])
      const word = model.getWordUntilPosition(pos)
      const range = { startLineNumber: pos.lineNumber, endLineNumber: pos.lineNumber, startColumn: word.startColumn, endColumn: word.endColumn }
      return {
        suggestions: (await list).map((s) => ({
          label: s.prefix,
          kind: monaco.languages.CompletionItemKind.Snippet,
          detail: s.name,
          documentation: s.description,
          insertText: s.body,
          insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
          range
        }))
      }
    }
  }
}

/* ---------------- applying them ---------------- */

/** languages Monaco has by itself: extensions don't replace their colouring */
const builtin = new Set(monaco.languages.getLanguages().map((l) => l.id))
/** extension id → its manifest as applied, and what to undo when it's removed or updated */
const applied = new Map<string, { manifest: string; undo: monaco.IDisposable[] }>()
/** languages an extension registered (Monaco can't unregister one; it stays until a restart) */
const registered = new Set<string>()
const tokenized = new Set<string>()

function apply(ext: EditorExt): EditorExtInfo {
  const pkg = parseJsonc(ext.manifest)
  const c = pkg.contributes ?? {}
  const undo: monaco.IDisposable[] = []
  const info: EditorExtInfo = {
    id: ext.id,
    name: pkg.displayName || pkg.name || ext.id,
    publisher: pkg.publisher ?? '',
    version: pkg.version ?? '',
    description: pkg.description ?? '',
    themes: [],
    languages: [],
    snippets: 0
  }
  for (const t of Array.isArray(c.themes) ? c.themes : []) {
    if (typeof t?.path !== 'string') continue
    const label = t.label || t.id || t.path
    const id = themeId(ext.id, label)
    themes.set(id, { label, uiTheme: t.uiTheme ?? 'vs-dark', path: t.path, dir: ext.dir })
    info.themes.push({ id, label })
  }
  for (const l of Array.isArray(c.languages) ? c.languages : []) {
    if (typeof l?.id !== 'string' || builtin.has(l.id)) continue
    if (!registered.has(l.id)) {
      monaco.languages.register({ id: l.id, extensions: l.extensions, filenames: l.filenames, aliases: l.aliases, mimetypes: l.mimetypes })
      registered.add(l.id)
    }
    info.languages.push(l.aliases?.[0] ?? l.id)
    if (typeof l.configuration === 'string') {
      const path = join(ext.dir, l.configuration)
      void readText(path).then((text) => {
        if (text == null || !applied.has(ext.id)) return
        try {
          undo.push(monaco.languages.setLanguageConfiguration(l.id, toConfig(parseJsonc(text))))
        } catch (e) {
          console.warn('language configuration', path, e)
        }
      })
    }
  }
  for (const g of Array.isArray(c.grammars) ? c.grammars : []) {
    if (typeof g?.scopeName !== 'string' || typeof g.path !== 'string') continue
    grammars.set(g.scopeName, { dir: ext.dir, path: g.path })
    for (const target of Array.isArray(g.injectTo) ? g.injectTo : []) injections.set(target, [...(injections.get(target) ?? []), g.scopeName])
    const lang = g.language
    if (typeof lang !== 'string' || builtin.has(lang) || tokenized.has(lang) || !registered.has(lang)) continue
    tokenized.add(lang)
    // Monaco asks for it when a file of that language first opens: only then is the grammar read
    // and compiled (a promise made now would load every grammar at start-up)
    const scope = g.scopeName
    let loaded: Promise<monaco.languages.TokensProvider> | null = null
    const lazy = { then: (ok: any, fail: any) => (loaded ??= tokensProvider(scope)).then(ok, fail) } as PromiseLike<monaco.languages.TokensProvider>
    undo.push(monaco.languages.setTokensProvider(lang, lazy))
    undo.push({ dispose: () => tokenized.delete(lang) })
  }
  for (const s of Array.isArray(c.snippets) ? c.snippets : []) {
    if (typeof s?.path !== 'string') continue
    const langs = typeof s.language === 'string' ? [s.language] : monaco.languages.getLanguages().map((l) => l.id)
    const provider = snippetProvider(join(ext.dir, s.path))
    for (const lang of langs) undo.push(monaco.languages.registerCompletionItemProvider(lang, provider))
    info.snippets++
  }
  applied.set(ext.id, { manifest: ext.manifest, undo })
  return info
}

/** package.json with its "%key%" texts filled in from package.nls.json (VS Code's own extensions name their themes that way). */
async function localize(ext: EditorExt): Promise<EditorExt> {
  if (!/"%[^"%]+%"/.test(ext.manifest)) return ext
  const text = await readText(join(ext.dir, 'package.nls.json'))
  let nls: any = {}
  try {
    nls = text ? parseJsonc(text) : {}
  } catch {
    /* unreadable: keep the keys */
  }
  const value = (v: any): string | undefined => (typeof v === 'string' ? v : typeof v?.message === 'string' ? v.message : undefined)
  const manifest = ext.manifest.replace(/"%([^"%]+)%"/g, (m, k: string) => {
    const v = value(nls[k])
    return v === undefined ? m : JSON.stringify(v)
  })
  return { ...ext, manifest }
}

let loading: Promise<void> | null = null
let again = false

/** Reads the installed extensions and applies what changed (an install, an update, a removal). */
export function loadEditorExtensions(): Promise<void> {
  if (loading) {
    again = true
    return loading
  }
  loading = (async () => {
    const list = await Promise.all((await window.api.editorExt.list().catch(() => [] as EditorExt[])).map(localize))
    const infos: EditorExtInfo[] = []
    const keep = new Set(list.map((e) => e.id))
    for (const [id, a] of applied) {
      if (keep.has(id) && list.find((e) => e.id === id)!.manifest === a.manifest) continue
      a.undo.forEach((d) => d.dispose())
      applied.delete(id)
    }
    const prev = new Map(useStore.getState().editorExts.map((x) => [x.id, x]))
    for (const ext of list) {
      try {
        infos.push(applied.has(ext.id) && prev.has(ext.id) ? prev.get(ext.id)! : apply(ext))
      } catch (e) {
        console.warn('editor extension', ext.id, e)
      }
    }
    indexLanguages()
    // files opened before their language was known (a tab restored at start-up) get it now
    for (const m of monaco.editor.getModels()) {
      if (m.getLanguageId() !== 'plaintext' || m.uri.scheme !== 'file') continue
      const lang = languageFor(m.uri.path)
      if (lang !== 'plaintext') monaco.editor.setModelLanguage(m, lang)
    }
    const s = useStore.getState()
    const picked = s.editorTheme && !infos.some((x) => x.themes.some((t) => t.id === s.editorTheme)) ? '' : s.editorTheme
    useStore.setState({ editorExts: infos, editorTheme: picked, editorThemeLoaded: picked === s.editorThemeLoaded ? picked : '' })
    await loadPickedTheme()
  })().finally(() => {
    loading = null
    if (again) {
      again = false
      void loadEditorExtensions()
    }
  })
  return loading
}
