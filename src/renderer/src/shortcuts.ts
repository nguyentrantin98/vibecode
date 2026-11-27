/**
 * Every app command with its keyboard shortcut, in one table: the global key handler and the
 * command palette (Ctrl+Shift+P / F1) both read it, so a shortcut shown in the palette is always
 * the one that works.
 *
 * Bindings follow VS Code (and Windows Terminal for the terminal keys). Keys that mean something
 * inside a terminal — readline (Ctrl+W, Ctrl+L…) and Claude Code (Ctrl+B background, Ctrl+O
 * transcript, Ctrl+J newline, Ctrl+T todos…) — go to the terminal when it has the cursor; the app
 * only takes them elsewhere.
 */
import { useStore } from './store'
import {
  closeChat,
  closeTab,
  cycleChat,
  cycleTab,
  defaultAgent,
  newChat,
  newShell,
  openBrowser,
  openFolder,
  reopenClosedTab,
  selectChat,
  toggleBottom,
  toggleTheme
} from './actions'
import { focusTerm } from './terminals'
import { saveFile } from './fileModelsLite'
import { setLang } from './i18n'

export interface Command {
  id: string
  /** [English, Vietnamese]: the palette shows and searches the one of the current language */
  label: [en: string, vi: string]
  /** shown in the palette, e.g. "Ctrl+Shift+P" */
  keys?: string
  run: () => void
}

const st = useStore.getState

const activeFile = (): { path: string; dirty: boolean } | null => {
  const s = st()
  const t = s.tabs.find((x) => x.id === s.activeTabId)
  return t?.kind === 'file' ? { path: t.path, dirty: t.dirty } : null
}

const showCode = (): void => useStore.setState({ centerView: 'code' })
const palette = (query: string): void => useStore.setState({ quickOpen: true, quickOpenQuery: query })

export const COMMANDS: Command[] = [
  { id: 'palette', label: ['Show all commands', 'Hiện tất cả lệnh'], keys: 'Ctrl+Shift+P', run: () => palette('>') },
  { id: 'quickOpen', label: ['Go to file…', 'Đi tới tệp…'], keys: 'Ctrl+P', run: () => st().root && palette('') },
  { id: 'symbol', label: ['Go to symbol in file…', 'Đi tới ký hiệu trong tệp…'], keys: 'Ctrl+Shift+O', run: () => window.dispatchEvent(new Event('go-to-symbol')) },
  { id: 'line', label: ['Go to line…', 'Đi tới dòng…'], keys: 'Ctrl+G', run: () => window.dispatchEvent(new Event('go-to-line')) },
  { id: 'openFolder', label: ['Open folder…', 'Mở thư mục…'], keys: 'Ctrl+O', run: () => void openFolder(null, { autoChat: false }) },

  { id: 'newChat', label: ['New chat', 'Chat mới'], keys: 'Ctrl+Shift+N', run: () => void (defaultAgent() && newChat()) },
  { id: 'nextChat', label: ['Next chat', 'Chat tiếp theo'], keys: 'Ctrl+Alt+→', run: () => cycleChat(1) },
  { id: 'prevChat', label: ['Previous chat', 'Chat trước'], keys: 'Ctrl+Alt+←', run: () => cycleChat(-1) },
  { id: 'focusChat', label: ['Focus chat', 'Chuyển tới chat'], keys: 'Ctrl+Shift+L', run: () => focusActiveChat() },
  {
    id: 'closeChat',
    label: ['Close chat', 'Đóng chat'],
    run: () => {
      const id = st().activeChatId
      if (id) closeChat(id)
    }
  },

  { id: 'save', label: ['Save file', 'Lưu tệp'], keys: 'Ctrl+S', run: () => saveActive() },
  { id: 'closeTab', label: ['Close editor tab', 'Đóng tab soạn thảo'], keys: 'Ctrl+W', run: () => closeActiveTab() },
  { id: 'reopenTab', label: ['Reopen closed editor tab', 'Mở lại tab soạn thảo vừa đóng'], keys: 'Ctrl+Shift+T', run: () => reopenClosedTab() },
  { id: 'nextTab', label: ['Next editor tab', 'Tab soạn thảo tiếp theo'], keys: 'Ctrl+Tab', run: () => cycleTab(1) },
  { id: 'prevTab', label: ['Previous editor tab', 'Tab soạn thảo trước'], keys: 'Ctrl+Shift+Tab', run: () => cycleTab(-1) },

  { id: 'explorer', label: ['Show Explorer (files)', 'Hiện Explorer (tệp)'], keys: 'Ctrl+Shift+E', run: () => showCode() },
  { id: 'changes', label: ['Show Source Control (changes)', 'Hiện Source Control (thay đổi)'], keys: 'Ctrl+Shift+G', run: () => showCode() },
  { id: 'chats', label: ['Show chats sidebar', 'Hiện thanh bên chat'], keys: 'Ctrl+Shift+C', run: () => useStore.setState({ sidebarView: 'chats', sidebarOpen: true }) },
  { id: 'sidebar', label: ['Toggle sidebar', 'Bật/tắt thanh bên'], keys: 'Ctrl+B', run: () => useStore.setState({ sidebarOpen: !st().sidebarOpen }) },
  { id: 'terminal', label: ['Toggle terminal', 'Bật/tắt terminal'], keys: 'Ctrl+`', run: () => toggleBottom() },
  { id: 'panel', label: ['Toggle bottom panel', 'Bật/tắt bảng dưới'], keys: 'Ctrl+J', run: () => toggleBottom() },
  { id: 'newTerminal', label: ['New terminal', 'Terminal mới'], keys: 'Ctrl+Shift+`', run: () => newShell() },

  { id: 'viewCode', label: ['Show Source code tab', 'Hiện tab Source code'], keys: 'Ctrl+1', run: () => useStore.setState({ centerView: 'code' }) },
  { id: 'viewWeb', label: ['Show Web tab', 'Hiện tab Web'], keys: 'Ctrl+2', run: () => openBrowser() },
  { id: 'viewDb', label: ['Show dbX tab (databases)', 'Hiện tab dbX (cơ sở dữ liệu)'], keys: 'Ctrl+3', run: () => useStore.setState({ centerView: 'db' }) },
  { id: 'viewZalo', label: ['Show Zalo tab', 'Hiện tab Zalo'], keys: 'Ctrl+4', run: () => useStore.setState({ centerView: 'zalo' }) },
  { id: 'viewGmail', label: ['Show Gmail tab', 'Hiện tab Gmail'], keys: 'Ctrl+5', run: () => useStore.setState({ centerView: 'gmail' }) },
  { id: 'viewOffice', label: ['Show Office tab', 'Hiện tab Office'], keys: 'Ctrl+6', run: () => useStore.setState({ centerView: 'office' }) },
  { id: 'viewFiles', label: ['Show This PC (browse the whole computer)', 'Hiện This PC (duyệt toàn bộ máy tính)'], run: () => useStore.setState({ centerView: 'files' }) },

  { id: 'theme', label: ['Toggle light / dark theme', 'Bật/tắt giao diện sáng / tối'], run: () => void toggleTheme() },
  {
    id: 'language',
    label: ['Change language: English / Tiếng Việt', 'Đổi ngôn ngữ: English / Tiếng Việt'],
    run: () => void setLang(st().lang === 'vi' ? 'en' : 'vi')
  }
]

const byId = new Map(COMMANDS.map((c) => [c.id, c]))
const run = (id: string): void => byId.get(id)!.run()

function focusActiveChat(): void {
  const id = st().activeChatId
  if (id) focusTerm(id)
}

function saveActive(): void {
  const f = activeFile()
  if (f) void saveFile(f.path)
}

function closeActiveTab(): void {
  const id = st().activeTabId
  if (id && st().centerView === 'code') closeTab(id)
}

/** The cursor is in a terminal (a chat or a shell). */
const inTerminal = (): boolean => !!(document.activeElement as HTMLElement | null)?.closest?.('.xterm')
/** The cursor is in a text field of the page (not Monaco, which handles its own keys). */
const inTextField = (): boolean => {
  const el = document.activeElement as HTMLElement | null
  return !!el && !el.closest('.monaco-editor') && !el.closest('.xterm') && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)
}

/**
 * The command a key press means, or null to let it through. `e.code` is used for keys whose
 * character changes with the keyboard layout (` and digits).
 */
function commandFor(e: KeyboardEvent): string | null {
  const ctrl = e.ctrlKey || e.metaKey
  const { shiftKey: shift, altKey: alt } = e
  const k = e.key.toLowerCase()
  const term = inTerminal()

  if (e.key === 'F1' && !ctrl && !alt) return 'palette'
  // Alt+1…9: switch chat
  if (alt && !ctrl && !shift && /^Digit[1-9]$/.test(e.code)) return `chat:${e.code.slice(5)}`
  if (!ctrl) return null

  if (alt && !shift) {
    if (e.key === 'ArrowRight') return 'nextChat'
    if (e.key === 'ArrowLeft') return 'prevChat'
    return null
  }
  if (alt) return null

  if (e.code === 'Backquote') return shift ? 'newTerminal' : 'terminal'
  if (e.key === 'Tab') return shift ? 'prevTab' : 'nextTab'
  if (e.key === 'PageDown' && !shift) return 'nextTab'
  if (e.key === 'PageUp' && !shift) return 'prevTab'
  if (e.key === 'F4' && !shift) return term ? null : 'closeTab'

  if (shift) {
    switch (k) {
      case 'p':
        return 'palette'
      case 'n':
        return 'newChat'
      case 'o':
        return 'symbol'
      case 'e':
        return 'explorer'
      case 'g':
        return 'changes'
      case 't':
        return 'reopenTab'
      case 'l':
        return 'focusChat'
      // Ctrl+Shift+C in a terminal copies (Windows Terminal / VS Code)
      case 'c':
        return term ? null : 'chats'
    }
    return null
  }

  // Ctrl+1…4: the center tabs (in a terminal too: shells don't use them)
  if (/^Digit[1-6]$/.test(e.code)) return ['viewCode', 'viewWeb', 'viewDb', 'viewZalo', 'viewGmail', 'viewOffice'][Number(e.code.slice(5)) - 1]
  if (k === 'p') return 'quickOpen'
  // the rest mean something to readline / Claude Code: theirs while a terminal has the cursor
  if (term) return null
  switch (k) {
    case 'b':
      return 'sidebar'
    case 'j':
      return 'panel'
    case 'o':
      return 'openFolder'
    case 'w':
      return 'closeTab'
    case 'g':
      // Monaco opens its own "go to line" when it has the cursor
      return document.activeElement?.closest('.monaco-editor') ? null : 'line'
    case 's':
      // nothing unsaved: leave the key alone
      return activeFile()?.dirty ? 'save' : null
  }
  return null
}

/** The page is a web view: its reload keys would wipe every chat's screen. */
function isReload(e: KeyboardEvent): boolean {
  const ctrl = e.ctrlKey || e.metaKey
  return e.key === 'F5' || (ctrl && e.key.toLowerCase() === 'r')
}

export function onGlobalKey(e: KeyboardEvent): void {
  if (e.defaultPrevented) return
  if (isReload(e) && !inTerminal()) {
    // Ctrl+Shift+R still reloads while developing
    if (!(import.meta.env.DEV && e.shiftKey)) e.preventDefault()
    return
  }
  const id = commandFor(e)
  if (!id) return
  // typing in a field (address bar, search box…): only app-wide combos, not plain Ctrl+letters it edits with
  if (inTextField() && ['closeTab', 'line', 'openFolder', 'sidebar', 'panel'].includes(id)) return
  e.preventDefault()
  e.stopPropagation()
  if (id.startsWith('chat:')) {
    const c = st().chats[Number(id.slice(5)) - 1]
    if (c) selectChat(c.id)
    return
  }
  run(id)
}
