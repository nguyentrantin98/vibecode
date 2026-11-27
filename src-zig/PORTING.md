# Porting src-tauri (Rust) to src-zig (Zig 0.17.1)

The app was moved from Tauri/Rust (`src-tauri/src/*.rs`, removed after v0.2.29; `git show
v0.2.29:src-tauri/src/<file>.rs` for the reference: behaviour must stay the same) to a plain Zig
executable with its own Win32 + WebView2 host. The renderer
(`../src/renderer`) is unchanged: it calls `invoke(cmd, args)` and listens to events exactly as it
did with Tauri (`../src/renderer/src/api.ts` lists every command with its argument names and the
shape of what it expects back; `../src/renderer/src/native.ts` is the page side of the bridge).

Windows is the target that must build and work. macOS (`src/host/mac`) is not written yet: guard
Windows-only code with `if (core.is_windows)` / `comptime` switches where it is cheap, do not write
the macOS side.

## Layout

| file | what |
|---|---|
| `src/core.zig` | allocator `core.gpa`, `core.io`, worker pool `core.spawn`, `core.emit`, folders, files, child processes `core.run`, `core.which`, `core.Fail`, wide strings |
| `src/ipc.zig` | how a command is declared (read the header comment), `ipc.Call`, `ipc.Channel`, `ipc.Raw`, `ipc.Bytes` |
| `src/host.zig`, `src/host/win/host.zig`, `src/host/win/com.zig` | windows, webviews, UI thread (`host.onUi`, `host.onUiSync`), routes, COM helpers; `host.win.c` is Win32 + WebView2 translated from C (`src/host/win/c.h`) |
| `src/settings.zig` | `settings.get(a)`, `settings.tr(en, vi)`, `settings.vi()`, `settings.set`, … |
| `src/http.zig` | HTTP(S) client: `http.get`, `http.request`, `http.postJson`, `http.stream`, `http.download`, `http.client()` |
| `src/watch.zig` | recursive folder watcher with debounced batches |
| `src/dialog.zig` | native open / save / folder dialogs |
| `src/png.zig` | PNG encoder |
| `src/modules.zig` | the list of feature modules; `-Donly=a,b` compiles just those |
| `src/<module>.zig` | one per Rust file (`zalo/zalo.zig` for `zalo/*.rs`); a module may add helper files next to it |

A module declares `pub const commands = .{ .{ "fs_read_dir", fs_read_dir }, … };` and optionally
`pub fn init() void` / `pub fn deinit() void` (see `modules.zig`, `main.zig`). Command names and
JSON shapes are the Tauri ones: argument keys are camelCase (`chat_id` in Rust is `chatId` on the
wire), result structs use the field names serde produced (check `#[serde(rename_all = …)]`, and
`skip_serializing_if`: write a `jsonStringify` like `settings.zig` when a null field must be left
out). Events: `core.emit("fs:changed", .{paths})` — the payload is the listener's argument list.

Rust → Zig:
- `Res<T>` / `core::err("…")` → `!T` and `return c.fail("… {s}", .{x})`.
- `anyhow` errors outside commands → `fail: *core.Fail` parameter and `return fail.set(a, "…", .{})`.
- `tauri::ipc::Channel<T>` argument → a field of type `ipc.Channel`; `ch.send(value)`.
- `tauri::ipc::Request` (raw body + headers) → `ipc.Raw` and `c.header("x-ext")`;
  `tauri::ipc::Response` (bytes) → return `ipc.Bytes`.
- `tokio::spawn` / `spawn_blocking` → `core.spawn(func, .{args})`; a long-lived loop gets its own
  `std.Thread.spawn`. There is no async: commands already run on worker threads and may block.
- `parking_lot::Mutex` → `core.Mutex` (`lock()` / `unlock()`), statics as file-level `var`.
- `crate::core::command(…)` → `core.run(a, argv, .{ .cwd = … })` (no console window), or
  `std.process.spawn(core.io, .{ … .create_no_window = true })` when output is streamed.
- `regex` → there is no regex library: write the match by hand (keep it a small, tested function).
- Per-call memory: `c.arena` (freed after the reply). Anything kept longer: `core.gpa`.
- User-visible text keeps both languages: `settings.tr("English", "Tiếng Việt")`.

Other modules are reached through `const m = @import("modules.zig");` and must be guarded so that
a `-Donly` build without them still compiles:

    if (@hasDecl(m.pty, "killAll")) m.pty.killAll();

## Contract between modules (names and signatures are fixed)

    pty        pub fn claudePath(a: Allocator) ?[]u8
               pub fn killAll() void
    mcp        pub fn start() !void
               pub fn configFor(a: Allocator, chat: []const u8) ?[]u8          // path of the --mcp-config file
    secure     pub fn seal(a: Allocator, plain: []const u8) ![]u8
               pub fn open(a: Allocator, sealed: []const u8) ![]u8
               pub fn sealStr(a: Allocator, s: []const u8) ![]u8                // base64 text
               pub fn openStr(a: Allocator, b64: []const u8) ![]u8
    fsx        pub fn trash(path: []const u8) !void
               pub fn localDrives(a: Allocator) ![]const []const u8
    windowing  pub fn show() void, pub fn toggle() void, pub fn quit() void, pub fn applyDropPrefs() void
               pub const hidden_arg = "--hidden";
    toast      pub const ToastTag = struct { text: []const u8, color: []const u8 };
               pub const ToastCard = struct { id, avatar: ?[]const u8 = null, name, title, body, meta: ?[]const u8 = null, tag: ?ToastTag = null };
               pub fn show(cards: []const ToastCard) void                       // copies what it keeps
    capture    pub const hotkey = "Ctrl+Alt+Z";
               pub fn captureStart(hide: bool) !void
               pub fn grab(a: Allocator, x: i32, y: i32, w: u32, h: u32) ?[]u8  // BGRA, top-down, w*h*4
    browser    pub fn syncAdblock() void, pub fn clearCache() !void, pub fn startAdblock() void
               pub fn addExtension / extensions / extensionEnable / extensionRemove (used by extensions.zig, same agent)
    adblock    as adblock.rs (used by browser.zig and extensions.zig, same agent)
    extensions pub fn installDefaults() void
    zalo_tasks pub fn init() void, pub fn onIngest(ids: []const []const u8) void
               pub fn safeName(a: Allocator, s: []const u8) ![]u8
    zalo       pub fn init() void

Claude's tools (the MCP server in `mcp.zig` calls these):

    zalo, office:
        pub const INSTRUCTIONS: []const u8
        pub fn tools(a: Allocator) ![]const u8                    // the JSON text of the tools array
        pub fn callTool(a: Allocator, name: []const u8, args: std.json.Value, fail: *core.Fail) anyerror![]const u8   // the text result
    dbx (passes DBX's own MCP tools and results through):
        pub const INSTRUCTIONS: []const u8
        pub fn tools(a: Allocator, fail: *core.Fail) ![]const u8          // the JSON text of the tools array
        pub fn callTool(a: Allocator, params: std.json.Value, fail: *core.Fail) ![]const u8   // the JSON text of the MCP result
    desktop:
        pub fn enabled(chat: []const u8) bool
        pub const INSTRUCTIONS, pub fn tools(a) as above
        pub fn callTool(a: Allocator, chat: []const u8, name: []const u8, args: std.json.Value, fail: *core.Fail) anyerror![]const u8   // JSON text of the MCP "content" array

## Zig 0.17.1 — this is not the Zig you remember

The standard library changed a lot after 0.14/0.15. **Do not write std calls from memory**: look
at how the existing files do it (`core.zig`, `http.zig`, `watch.zig`, `settings.zig`,
`host/win/host.zig`, `tools/gen_assets.zig`) and read the std source when unsure:

    C:\Users\PC\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-x86_64-windows-0.17.1\lib\std

Things already confirmed here:
- Everything that touches the OS takes an `Io`: use `core.io`. Files and folders are `std.Io.Dir`
  / `std.Io.File`: `std.Io.Dir.cwd().openFile(core.io, path, .{})`, `.readFileAlloc(core.io, path,
  a, .limited(max))`, `.statFile(core.io, path, .{})`, `.createDirPath`, `.deleteFile`,
  `.deleteTree`, `.openDir(core.io, path, .{ .iterate = true })` then `dir.iterate()` /
  `it.next(core.io)`, `dir.walk(a)`, `Dir.rename(Dir.cwd(), from, Dir.cwd(), to, core.io)`.
  `std.fs` only has path helpers left (`std.fs.path.join`, `.basename`, `.dirname`, `.extension`).
- Readers / writers are `std.Io.Reader` / `std.Io.Writer` (concrete types with a buffer):
  `var fw = file.writer(core.io, &buf); try fw.interface.writeAll(…); try fw.interface.flush();`
  Growable output: `var aw: std.Io.Writer.Allocating = .init(a); … aw.written()`.
- Containers are unmanaged: `var list: std.ArrayList(T) = .empty; try list.append(a, x);
  list.items; try list.print(a, "{d}", .{n});` `std.StringHashMapUnmanaged(V)`,
  `std.AutoHashMapUnmanaged(K, V)` (`.empty`, `put(a, k, v)`).
- JSON: `core.toJson(a, value)`, `core.fromJson(T, a, bytes)` (unknown keys ignored);
  dynamic values are `std.json.Value` via `std.json.parseFromSliceLeaky(std.json.Value, a, bytes,
  .{})`, objects are unmanaged maps (`v.object.get("k")`, `v.object.put(a, k, val)`); writing by
  hand: `std.json.Stringify.value(v, .{}, &aw.writer)`, `std.json.Stringify.encodeJsonString`.
- Reflection: `@typeInfo(T).@"struct"` has `field_names`, `field_types`, `field_attrs` (no
  `.fields`).
- Processes: `std.process.spawn(core.io, .{ .argv = …, .stdin = .pipe, .stdout = .pipe,
  .create_no_window = true })`, `child.wait(core.io)`, `child.kill(core.io)`; see `core.run`.
- Time: `core.nowMs()` (Unix ms), `core.monoMs()`, `core.sleepMs(n)`. Random bytes:
  `core.io.random(&buf)`.
- Locks / signalling: `core.Mutex`, `std.Io.Condition` (`waitUncancelable(core.io, &mutex.m)`,
  `signal(core.io)`), `std.Io.Event`, `std.atomic.Value(T)`.
- Networking: `std.Io.net` (`IpAddress.parse`, `.listen(core.io, .{})`, `server.accept(core.io)`,
  `stream.reader/writer`), `std.http.Server`, `std.http.Client` (through `http.zig`),
  `std.crypto.tls.Client`.
- Formatting: `{s}` strings, `{d}` numbers, `{x}` hex, `{f}` for a type's `format` method,
  `{any}` anything.
- Win32: `const c = host.win.c;` (windows.h, shlobj, shobjidl, shellapi, dwmapi, wincrypt/dpapi,
  psapi, tlhelp32, wincodec, uiautomation, WebView2). COM through `host.win.com` (`com.call(obj,
  "Method", .{args})`, `com.query`, `com.release`, `com.handler`). An API that is missing from `c`
  is declared in your own file: `extern "kernel32" fn Foo(...) callconv(.winapi) c.BOOL;`.
  Strings: `core.wide(a, utf8)` → `[:0]u16`, `core.fromWide(a, ptr)`.
  WebView2 and windows are single-threaded: touch them only on the UI thread (`host.onUiSync`).

## Rules while several people port at once

- Edit only the files of your own modules (plus new helper files you create). **Do not edit**
  `core.zig`, `ipc.zig`, `host*.zig`, `host/win/*`, `http.zig`, `watch.zig`, `dialog.zig`,
  `png.zig`, `settings.zig`, `modules.zig`, `main.zig`, `build.zig`, `c.h`. If one of them is
  missing something or has a bug, work around it inside your module and say so in your report.
- Build and test with (from `src-zig`; never plain `zig build` or `zig build run`, they overwrite
  the shared `zig-out`):

      zig build check -Donly=<your modules, comma separated>     # compile + link, nothing installed
      zig build test  -Donly=<your modules>                      # unit tests

  Module names for `-Donly` are the file names without `.zig` (`zalo/zalo` for Zalo).
  Zig compiles lazily: code that nothing references is not even type-checked. Every command is
  referenced through the `commands` table; make sure helpers are reachable from a command, `init`,
  or a `test`.
- Port the Rust tests that exist (`#[cfg(test)]`) and add tests for the pure logic you had to
  write by hand (parsers, the regex replacements, protocol encoders).
- Keep the Rust file's structure, names (in Zig style: `snake_case` functions that are commands
  keep their command name, other functions `camelCase`, types `PascalCase`) and its comments
  where they explain *why*. No extra features, no speculative abstractions.
- Done means: `zig build check -Donly=<yours>` and `zig build test -Donly=<yours>` are clean, and
  your report lists what is ported, what is not (and why), anything you could not verify without
  the running app, and every place you depend on another module.

SQLite: `const sq = @import("sqlite");` (the C API: `sq.sqlite3_open_v2`, `sq.sqlite3_prepare_v2`, …).
Files a module embeds (`@embedFile`) must live under `src-zig/src`: copy them from `src-tauri/src` at v0.2.29.

Win32 gotchas seen so far:
- Handle constants that are not real pointers (`HWND_TOPMOST`, `HWND_BROADCAST`, `HKEY_CURRENT_USER`;
  `INVALID_HANDLE_VALUE` is fine) fail to compile when the handle type is an aligned pointer
  ("requires aligned address"): declare your own `extern` for that call with an integer parameter,
  as `host/win/host.zig` does for `SetWindowPos` / `PostMessageW`.
- GUIDs the headers only declare (`pub extern const CLSID_…: GUID`) may not link: define the GUID
  value yourself (`const CLSID_Foo: c.GUID = .{ .Data1 = …, … };`), as `dialog.zig` does.
- A COM object used on a worker thread needs `CoInitializeEx` on that thread (see `dialog.zig`).
- Temp folder: `core.tempDir()`.
- Zig parses every module file even with `-Donly`: a syntax error in someone else's file fails
  your build too (their semantic errors do not). Wait and rebuild; do not edit their file.
- The array repeat operator `**` is gone (`"\x00" ** 8` does not compile): use `@splat` or a
  literal. `std.mem.indexOf*` still work but are aliases of the new `std.mem.find*`.
- Python is not installed on this machine: edit with the Edit tool, not scripts.
- Code behind `if (core.debug) return;` is not compiled in a debug build: also run
  `zig build -Doptimize=ReleaseFast --prefix <a temp folder>` (do not start that exe: it writes
  the sign-in Run entry to its own path).
- In a debug build, std panics on some Windows statuses a release build returns as
  `error.Unexpected` (a path with a control character → `OBJECT_NAME_INVALID` panics in
  `Dir.access`).
