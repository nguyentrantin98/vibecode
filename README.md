# VIBE CODE

Desktop workspace for **Claude Code**: several parallel chats, a Monaco editor (the VS Code editor core), a live Git *Changes* panel with diff view, an integrated terminal, and a screen-capture tool that drops marked-up screenshots straight into the chat.

## Download

**[⬇ Download VIBE CODE for Windows (x64)](https://github.com/nguyentrantin98/vibecode/releases/latest/download/vibe-code_x64-setup.exe)**

All versions and release notes: [Releases](https://github.com/nguyentrantin98/vibecode/releases).

Run the installer (no admin rights needed, it installs for the current user). VIBE CODE also needs:

- **Claude Code CLI** on PATH: `npm install -g @anthropic-ai/claude-code`, then sign in once with `claude`
- **Git** on PATH
- Windows 10/11 (WebView2 is installed automatically if missing)

**Updates:** when a new version is published, an **Update vX.Y.Z** button appears at the left of the status bar. Click it: the app downloads the installer, updates itself and restarts.

![VIBE CODE demo: open a project, start a chat, go to file, run a failing test, capture and mark up the error with Ctrl+Alt+Z, send it to Claude, review the diff, tests pass](docs/demo.gif)

## Features

- **Parallel chats**: every open chat gets its own column, side by side (drag a column by its grip to move it); the column you click drives the Source code and Web tabs on the right. Other agents (Codex, Gemini…) work too.
- **Minimal UI**: buttons are icons only; hover one for its name. The center tabs (Source code, Web, dbX, Zalo, Gmail, Office) sit in the title bar.
- **Claude history**: the Chats sidebar lists every project and conversation from `~/.claude/projects` (shared with the Claude desktop app, the CLI and the IDE extensions) and updates live. Clicking a conversation resumes it in its own folder.
- **Editor + Git**: Monaco editor, go to file / symbol, a live *Changes* panel with diffs, commit history and a branch switcher.
- **Terminal**: integrated terminals (ConPTY, WebGL rendering).
- **Web / dbX / Zalo tabs**: a built-in browser, a database client and a Zalo inbox that Claude can also use through its tools.
- **dbX**: [DBX](https://github.com/t8y2/dbx) (Apache-2.0) inside the app, for SQL Server, PostgreSQL, MySQL, SQLite, Oracle, MongoDB, Redis and 100+ more databases (schemas, queries, data editing, ER diagrams). It is downloaded on first use (~42 MB) and runs only on this computer. Claude queries the same connections through the `vibe-dbx` tools (what it may change is set in DBX's Settings → MCP). The SQL Server connections of the old Database tab are added to DBX the first time it starts.
- **Screen capture**: **Ctrl+Alt+Z** grabs the screen as it is, VIBE CODE included (so you can capture the app itself); the dashed-square button in the title bar hides VIBE CODE first and grabs what is behind it. Drag to pick a region (click for the whole screen), with a magnifier, size label and colour picker. Then mark it up with rectangle, ellipse, arrow, pen, highlighter, text, mosaic (hide sensitive info) and numbered steps. **Send** copies it to the clipboard and attaches it to the active chat. You can also just copy it or save it as a PNG.
- **Temperature & sound**: the status bar shows the machine temperature; click it for cooling (fans first, CPU Turbo Boost off, and on ASUS laptops the fan profile and a 100% fan switch). **EQ** next to it is a whole-machine equalizer (presets such as *Less bass*, *Clear voice*, plus 10 bands): VIBE CODE's own audio filter (`src-zig/apo`), added after the speakers' own effects with one admin prompt.
- **Drop-down (Guake) mode**: a global hotkey slides VIBE CODE over any app.
- **Attachments**: paste or drop images and files into a chat. They wait in a tray until you send.
- **Phone remote**: follow and drive your chats from an Android phone on the same Wi-Fi (see below).

## Shortcuts

All commands with their keys are listed in the command palette (**Ctrl+Shift+P** or **F1**).
Bindings follow VS Code / Windows Terminal. Keys that mean something in a terminal (Ctrl+B, Ctrl+W,
Ctrl+J, Ctrl+O, Ctrl+L, Ctrl+T…, used by readline and Claude Code) go to the terminal while it has
the cursor.

| Keys | Action |
|---|---|
| Alt+` (global) | Show / hide VIBE CODE (drop-down slides over any app) |
| Ctrl+Alt+Z (global) | Capture the screen |
| Ctrl+Shift+P / F1 | Command palette |
| Ctrl+P | Go to file (`@` symbol, `:` line, `>` commands) |
| Ctrl+Shift+O / Ctrl+G | Go to symbol / line in the open file |
| Ctrl+Shift+N | New chat |
| Alt+1…9 · Ctrl+Alt+← / → | Switch chat · previous / next chat |
| Ctrl+Shift+L | Put the cursor in the open chat |
| Ctrl+1 / 2 / 3 / 4 | Source code / Web / dbX / Zalo tab |
| Ctrl+Shift+E / G / C | Explorer / Changes / Chats |
| Ctrl+` · Ctrl+J · Ctrl+Shift+` | Toggle terminal · toggle panel · new terminal |
| Ctrl+B | Toggle sidebar |
| Ctrl+S · Ctrl+W (Ctrl+F4) · Ctrl+Shift+T | Save · close editor tab · reopen closed tab |
| Ctrl+Tab / Ctrl+Shift+Tab (Ctrl+PgDn / PgUp) | Next / previous editor tab |
| Ctrl+O | Open folder |
| Ctrl+C (with selection) / Ctrl+Shift+C · Ctrl+V | Copy / paste in a terminal |
| Ctrl+= / Ctrl+− / Ctrl+0 | Terminal font size |
| Shift+Enter (in chat) | Newline in Claude prompt |

F5 / Ctrl+R never reload the app window (that would blank every chat).

**In the capture editor:** V move/resize · R rectangle · E ellipse · A arrow · P pen · H highlighter · T text · B mosaic · N numbered step · Shift (while drawing) square / circle · arrow keys nudge the region · Ctrl+Z undo · Ctrl+C copy · Ctrl+S save · Enter or double-click send to chat · Esc / right-click cancel.

## Drop-down (Guake) mode

Click **Guake** in the title bar (or use the tray icon menu). VIBE CODE then lives at the top edge of the screen under the mouse: the global hotkey slides it down over whatever app you're in and back up again. The tray menu sets height, opacity and "hide when focus is lost". Dragging the bottom edge changes the height. The hotkey is `hotkey` in `%APPDATA%\TINJS Studio\settings.json` (F12 can't be used: Windows reserves it for debuggers).

## Phone remote (Android)

Click the phone icon in the status bar, tick **Phone remote**, then **Pair a phone** and type the PIN on the phone.
The phone sees every open chat and whether it is working, finished or waiting on you; reads the conversation
or the live terminal; sends messages; answers Claude's numbered choices with one tap; starts new chats.

- **App**: `npm run build:android` makes `android/build/vibe-code-remote.apk` (~25 KB, Android 7+). It finds
  the computer by itself (UDP broadcast) and shows the page the computer serves, so it never needs updating.
- **No app**: any phone browser at `http://<computer IP>:47717` works the same.

Port 47717 (TCP + UDP); allow it when Windows Firewall asks (private networks). Off by default; the PIN is
valid 5 minutes and dies after 5 wrong tries; each phone gets its own token (only its hash is stored, in
`remote.json`) and can be removed from the panel. Traffic is plain HTTP on your local network: use it on
networks you trust, or over Tailscale / a VPN from outside.

## Development

Stack: Zig (own Win32 + WebView2 host) · React · TypeScript · Vite · Monaco · xterm.js (WebGL) · ConPTY.
Windows only for now: `src-zig` has no macOS host yet.

```bash
npm install
npm run dev          # debug build of the app showing the page from Vite, with hot reload
npm run build        # release build in src-zig/zig-out/bin/
npm run release      # bump the patch version, build, make the installer, commit, push and publish a GitHub release
npm run release 0.3.0  # same, with an explicit version
npm run build:android  # the phone remote APK (needs an Android SDK platform + build-tools and a JDK; no Gradle)
```

Building needs Node 24+ and Zig 0.17.1. The installer is made with NSIS 3 in
`%LOCALAPPDATA%\tauri\NSIS`, with the `nsis_tauri_utils.dll` plugin from
[tauri-apps/nsis-tauri-utils](https://github.com/tauri-apps/nsis-tauri-utils/releases) in its
`Plugins\x86-unicode\additional` (`src-zig/installer/installer.nsi` is Tauri's template, so
updates install over a Tauri-built copy). The app itself has no Node runtime.

`npm run release` uploads the installer as `vibe-code_x64-setup.exe` on a `vX.Y.Z` release. The
download link above and the in-app Update button both use the latest release. It needs a GitHub token:
`GITHUB_TOKEN`, or the credential git already has for github.com.

`STUDIO_USER_DATA=<folder>` runs with a separate profile (settings, logins, Zalo session).

## Layout

- `src-zig/src`: the native side (see `src-zig/PORTING.md`). Terminals (`pty.zig`), files and the file
  watcher, git, Claude's session store, DBX for the dbX tab (`dbx.zig`), Zalo (`zalo/`), the built-in
  browser (`browser.zig`, native WebView2 tabs that sleep when hidden), the MCP server Claude's tools
  talk to (`mcp.zig`), window / tray / drop-down mode (`windowing.zig`), screen capture
  (`capture.zig` + `capture.html`), updates (`appcmds.zig`), the window host (`host/`)
- `src/renderer/src/api.ts`: `window.api`, the page's bridge to the native commands and events
- `src/renderer/src`: UI (`components/`), state (`store.ts`, `actions.ts`), terminals, Monaco setup
- `scripts/release.cjs`: build and publish a release
- `src-zig/src/remote.zig` (server, pairing, discovery) · `src/renderer/src/remote.ts` (what phones see and do) ·
  `src/renderer/src/phone/` (the phone page) · `android/` (the APK: one Java file, built by `scripts/build-android.cjs`)
