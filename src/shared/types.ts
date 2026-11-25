import type { AgentId } from './agents'

export interface DirEntry {
  name: string
  path: string
  isDir: boolean
}

export type GitFileStatus = 'M' | 'A' | 'D' | 'R' | 'U' | '?' | 'C'

export interface GitFile {
  /** path relative to repo root, forward slashes */
  rel: string
  /** absolute path on disk */
  abs: string
  status: GitFileStatus
  staged: boolean
  added: number
  deleted: number
}

export interface GitState {
  isRepo: boolean
  root: string | null
  branch: string | null
  files: GitFile[]
  /** e.g. `origin/master`; null when the branch isn't published */
  upstream?: string | null
  /** commits to push / to pull, as of the last fetch */
  ahead?: number
  behind?: number
  hasRemote?: boolean
}

export interface GitCommit {
  hash: string
  short: string
  author: string
  /** unix ms */
  date: number
  subject: string
}

export interface GitBranch {
  name: string
  current: boolean
  /** only on the remote (e.g. `origin/feature`): checking it out makes a local tracking branch */
  remote: boolean
}

export interface GitCommitFile {
  rel: string
  status: GitFileStatus
  added: number
  deleted: number
}

export interface PtySpawnOptions {
  id: string
  cwd: string
  kind: 'claude' | 'shell'
  /** which coding agent a chat terminal runs — default Claude Code */
  agent?: AgentId
  /** extra args for claude (or the chat's agent), e.g. ['--continue'] or ['--resume', id] */
  claudeArgs?: string[]
  cols: number
  rows: number
}

export interface SessionInfo {
  id: string
  title: string
  /** folder the session ran in — `claude --resume` must run from here */
  cwd: string
  /** repo the session belongs to (worktree sessions roll up to their repo) */
  projectCwd: string
  created: number
  updated: number
  cwdExists: boolean
  /** the coding agent whose chat this is, when it is not Claude Code (Codex's own history) */
  agent?: AgentId | null
}

export interface ProjectGroup {
  key: string
  cwd: string
  name: string
  updated: number
  sessions: SessionInfo[]
}

export type WindowMode = 'window' | 'dropdown'
export type ThemePref = 'system' | 'light' | 'dark' | 'blue'

export interface AppSettings {
  recentFolders: string[]
  lastFolder: string | null
  /** 'dropdown' = Guake-style: slides from the top edge on a global hotkey */
  mode: WindowMode
  hotkey: string
  /** drop-down height as a fraction of the screen work area */
  dropHeight: number
  dropOpacity: number
  hideOnBlur: boolean
  theme: ThemePref
  /** defaults for new chats: '' = Claude Code's own default */
  model: string
  effort: string
  /** default | acceptEdits | plan | bypassPermissions — '' = Claude Code's own default */
  permissionMode: string
  /** Linux-style overlay: transparent window background, text stays solid (needs a relaunch) */
  seeThrough: boolean
  /** code editor (Monaco): font family name, size in px, ligatures */
  editorFont: string
  editorFontSize: number
  editorLigatures: boolean
  /** start (hidden in the tray) when Windows signs in — undefined = on */
  openAtLogin?: boolean
  /** Web tabs block requests to known ad / tracking servers */
  adBlock: boolean
  /** UI language — '' until the app first picks one from the system language */
  language: Lang | ''
}

export type Lang = 'en' | 'vi'

export interface WindowState {
  mode: WindowMode
  maximized: boolean
  hotkey: string
  hotkeyOk: boolean
}

/** One plan limit from Claude's usage API (what /usage and the Claude app show). */
export interface UsageLimit {
  /** session = 5-hour window, weekly_all = all models this week, weekly_scoped = one model this week */
  kind: string
  label: string
  percent: number
  severity: string
  resetsAt: string | null
}

/** Machine temperature and cooling (src-zig/src/thermal.zig) */
export type FanProfile = 'silent' | 'standard' | 'performance'
export interface ThermalInfo {
  /** hottest ACPI thermal zone, °C; null when the machine reports none */
  celsius: number | null
  zones: { name: string; celsius: number }[]
  /** power plan: raise the fans before slowing the CPU; null = unreadable */
  activeCooling: boolean | null
  /** power plan: CPU turbo boost off */
  turboOff: boolean | null
  /** ASUS laptop: the firmware fan profile can be set (asks for admin) */
  asus: boolean
  /** the fan profile VIBE CODE last set, and the fan speeds read then */
  fanProfile: FanProfile | null
  /** the CPU fan was last set to full speed by VIBE CODE */
  fanFull: boolean
  cpuFanRpm: number | null
  gpuFanRpm: number | null
}

/** System-wide equalizer: VIBE CODE's own audio filter (src-zig/apo, src-zig/src/audio.zig) */
export interface SoundInfo {
  /** a connected speaker / headphones can take the filter, or it is installed; Sound is hidden otherwise */
  supported: boolean
  /** the filter is in Windows' audio chain */
  installed: boolean
  /** it processed sound in the last few seconds */
  running: boolean
  /** speakers / headphones it was put on, and the ones it could not be */
  devices: string[]
  skipped: string[]
  enabled: boolean
  preset: string
  /** dB per band, in `freqs` order */
  bands: number[]
  freqs: number[]
}

/** The Anthropic API key Claude chats can run on instead of the plan's login */
export interface ClaudeApiKey {
  /** "sk-ant-…abcd" — never the whole key; null = none saved */
  hint: string | null
  /** new (and restarted) Claude chats start with it */
  on: boolean
}

export interface AgentInfo {
  id: AgentId
  /** on PATH, and really that agent */
  found: boolean
  /** on PATH, but another program of the same name (its `--version` says so): cannot chat */
  wrong?: boolean
}

export interface ClaudeInfo {
  found: boolean
  path: string | null
  shell: string
}

/* ---------------- SQL Server (Database tab + Claude's mssql tools) ---------------- */

/** A saved connection as the UI sees it — no password. */
export interface DbConnection {
  id: string
  name: string
  server: string
  database: string
  auth: 'sql' | 'windows'
  user: string
  /** Claude's queries run in a transaction that is always rolled back */
  claudeReadOnly: boolean
  color?: string
}

export interface DbConnectionInput {
  id?: string
  name: string
  conn: string
  claudeReadOnly: boolean
  color?: string
}

/** A connection string found in the project or in SSMS, ready to add. */
export interface DbFound {
  name: string
  conn: string
  /** where it came from: a project file, or "SSMS 20.0" */
  file: string
  /** SSMS knew the server and login but had no saved password */
  needsPassword?: boolean
}

export interface DbObject {
  schema: string
  name: string
  /** U table, V view, P procedure, FN / IF / TF function */
  type: 'U' | 'V' | 'P' | 'FN' | 'IF' | 'TF'
}

export interface DbColumn {
  name: string
  type: string
  nullable: boolean
  identity: boolean
  pk: boolean
  /** foreign key target: schema.table.column */
  ref?: string
}

export interface DbResultSet {
  columns: { name: string; type: string }[]
  rows: unknown[][]
  truncated: boolean
}

export interface DbQueryResult {
  ok: boolean
  error?: string
  results: DbResultSet[]
  messages: string[]
  /** rows inserted / updated / deleted; -1 for none */
  affected: number
  ms: number
}

/* ---------------- Gmail (read-only Gmail tab) ---------------- */

export interface MailSummary {
  uid: number
  /** display name, or the address when there is none */
  from: string
  fromAddr: string
  subject: string
  /** ms since epoch, 0 when unknown */
  date: number
  seen: boolean
}

export interface MailBody {
  uid: number
  from: string
  to: string
  subject: string
  date: number
  html: string | null
  text: string | null
  attachments: string[]
}

/* ---------------- Office tab → Sheet (+ Claude's sheet tools) ---------------- */

/** one of Claude's vibe-office tool calls, for the Office tab to run on what it shows */
export interface OfficeRequest {
  id: number
  tool: 'office_status' | 'office_open' | 'doc_read' | 'sheet_read' | 'slide_read' | 'pdf_read'
  args: Record<string, unknown>
}

/** a file on the Office tab's "recent" list, as it is on disk now */
export interface RecentFile {
  path: string
  /** bytes; 0 when the file is gone */
  size: number
  /** ms since epoch, 0 when unknown */
  modified: number
  exists: boolean
}

/* ---------------- Zalo (Zalo tab + Claude's zalo tools) ---------------- */

export interface ZaloState {
  status: 'off' | 'qr' | 'connecting' | 'online' | 'error'
  /** QR code to scan (data: URL) while status is 'qr' */
  qr?: string
  /** name shown on the phone that scanned the QR, waiting for "Đăng nhập" there */
  scanned?: string
  error?: string
  self?: { id: string; name: string; avatar: string }
}

/** Web tab bookmark: a link, or a folder of them */
export interface WebBookmark {
  title: string
  url?: string
  children?: WebBookmark[]
}

export interface WebData {
  /** when bookmarks and history were imported from Chrome (0 = not yet) */
  importedAt: number
  bookmarks: WebBookmark[]
  /** Chrome is installed, so there is something to import */
  chromeFound: boolean
}

/** A browser extension in the Web tabs */
export interface WebExtension {
  id: string
  name: string
  enabled: boolean
  /** the ad blocker: switched with the shield, not removable */
  builtin: boolean
  /** its settings page (chrome-extension://…), when it has one */
  options?: string
}

export interface WebSuggestion {
  url: string
  title: string
  bookmark?: boolean
}

/** A background task Claude started in a chat */
export interface ChatTask {
  id: string
  command: string
  description: string
  /** running, completed, failed, killed… (as Claude Code reports it) */
  status: string
  startedAt: number
  endedAt?: number
  outputFile?: string
  /** the end of its output */
  output?: string
}

/** A file Claude created, edited or read in a chat (its Write / Edit / Read tools) */
export interface ChatFile {
  path: string
  /** a file read and then changed counts as changed */
  action: 'created' | 'edited' | 'read'
  /** successful Write / Edit calls on it */
  edits: number
  /** the last time Claude touched it */
  at: number
  exists: boolean
}

/** One thing in a chat's conversation, as the Chat view draws it */
export type ChatItem =
  /** mid: sent while Claude was working ("Send now"), it took it in during that turn */
  | { kind: 'user'; text: string; mid?: boolean; at: number }
  | { kind: 'text'; text: string; at: number }
  | {
      kind: 'tool'
      id: string
      name: string
      /** one line: the command's description, the file, the pattern… */
      label: string
      /** the full command / prompt / input, when the label doesn't say it all */
      detail: string
      /** undefined while the tool runs */
      output?: string
      error: boolean
      /** lines a Write / Edit added and removed */
      added: number
      removed: number
      /** a Write / Edit's change as unified-diff lines ("@@ -a,b +c,d @@" hunk heads, then " ", "+", "-" lines) */
      diff?: string[]
      /** pictures the tool returned (screenshots…), saved as files: their paths */
      images?: string[]
      at: number
    }
  /** a turn ended (ms = how long it worked), or was interrupted (ms = 0) */
  | { kind: 'done'; ms: number; at: number }

export interface ChatTodo {
  id: string
  text: string
  /** pending, in_progress, completed */
  status: string
}

/** A chat's conversation: its last items, and Claude's to-do list as it stands now */
export interface ChatLog {
  items: ChatItem[]
  todos: ChatTodo[]
  /** the list is drawn before items[todosAt] (or at the end) */
  todosAt: number
  /** older items left out */
  skipped: number
  /** tokens Claude wrote in the whole chat, and in its last turn */
  outTokens: number
  turnOutTokens: number
}

/** One item of the Zalo "Việc của tôi" checklist, summarised by Claude from messages sent to me. */
export interface ZaloTask {
  id: string
  title: string
  detail?: string
  threadId: string
  threadName: string
  group: boolean
  /** the message that asked for it */
  msgId?: string
  from: string
  /** Zalo user id of who asked */
  fromId?: string
  /** their avatar url (filled in when sent to the UI) */
  avatar?: string
  ts: number
  /** todo: not answered · doing: answered, not finished · done: reported done / resolved */
  status: 'todo' | 'doing' | 'done'
  /** status set by hand — Claude won't move it back */
  manual?: boolean
  updatedAt: number
}

/** A message to me that just arrived and is being turned into a task. */
export interface ZaloIncoming {
  threadId: string
  msgId: string
  threadName: string
  group: boolean
  from: string
  avatar?: string
  text: string
  ts: number
}

export interface ZaloTasksState {
  tasks: ZaloTask[]
  running: boolean
  analyzedAt: number
  error?: string
  /** new messages to me waiting for / in the current analysis */
  incoming?: ZaloIncoming[]
  /** ids of tasks the last analysis created (highlighted in the list) */
  fresh?: string[]
  /** ids of tasks whose status the last analysis changed */
  changed?: string[]
  /** tasks created / changed by Claude that I haven't looked at yet → the badge on the Zalo tab */
  unseen?: Record<string, 'new' | 'updated'>
  /** a batch of incoming messages is waiting: goes to Claude at this time unless more arrive */
  dueAt?: number
}

/** A row of Source code › This PC (the whole-computer file browser). */
export interface ExEntry {
  name: string
  path: string
  isDir: boolean
  /** bytes (0 for folders) */
  size: number
  /** ms since 1970; 0 unknown */
  modified: number
  /** hidden or system item */
  hidden: boolean
}

/** A search result of Source code › This PC. */
export interface ExHit extends ExEntry {
  /** the folder it's in, relative to where the search started ("" right there) */
  at: string
  /** matched characters of the name: [start, end) pairs */
  marks: number[]
}

export interface ExFound {
  /** the best ones, best first */
  hits: ExHit[]
  /** matches in all */
  total: number
  /** items walked so far */
  indexed: number
  /** the walk is over */
  done: boolean
}

/** File Explorer's left column: the user's folders and the drives. */
export interface ExPlace {
  kind: 'home' | 'desktop' | 'documents' | 'downloads' | 'pictures' | 'videos' | 'music' | 'drive'
  name: string
  path: string
  /** drives: bytes, 0 unknown */
  total: number
  free: number
}

/** Phone remote (src-zig/src/remote.zig): the Android app pairs with a PIN and drives the chats over the local network */
export interface RemoteState {
  enabled: boolean
  listening: boolean
  /** why the server could not start */
  problem: string | null
  port: number
  host: string
  /** this computer's IPv4 addresses */
  addresses: string[]
  /** shown while a phone can pair with it */
  pin: string | null
  pinUntil: number
  devices: { id: string; name: string; at: number; online: boolean }[]
}
