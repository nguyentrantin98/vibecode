//! The app's tools for Claude, as MCP servers over HTTP on localhost (like Claude desktop's).
//!
//! Every `claude` chat is launched with `--mcp-config <file>` naming four servers:
//!   vibe-browser  http://127.0.0.1:<port>/mcp/<chatId>   — that chat's own Web tab
//!   vibe-mssql    http://127.0.0.1:<port>/db/<chatId>    — SQL Server connections
//!   vibe-zalo     http://127.0.0.1:<port>/zalo/<chatId>  — the personal Zalo account
//!   vibe-office   http://127.0.0.1:<port>/office/<chatId> — the files open in the Office tab (docs, sheets, PDFs)
//! and one more once the user turns Desktop control on for the chat:
//!   vibe-desktop  http://127.0.0.1:<port>/desktop/<chatId> — the other apps on the Windows desktop
//! Streamable HTTP transport with plain JSON replies (no SSE), guarded by a per-launch token.

const std = @import("std");
const core = @import("core.zig");
const http = @import("http.zig");
const m = @import("modules.zig");
const browser = @import("browser.zig");
const J = @import("browser_json.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const net = std.Io.net;

const BROWSER = "vibe-browser";
const DB = "vibe-mssql";
const ZALO = "vibe-zalo";
const DESKTOP = "vibe-desktop";
const OFFICE = "vibe-office";

var port: std.atomic.Value(u16) = .init(0);

var token_buf: [48]u8 = undefined;
var token_made = false;
var token_mutex: core.Mutex = .{};

fn token() []const u8 {
    token_mutex.lock();
    defer token_mutex.unlock();
    if (!token_made) {
        var bytes: [24]u8 = undefined;
        core.io.random(&bytes);
        token_buf = std.fmt.bytesToHex(bytes, .lower);
        token_made = true;
    }
    return &token_buf;
}

/// Starts the server on a free localhost port; returns once chats can be given a config.
pub fn start() !void {
    const address = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(core.io, .{});
    errdefer server.deinit(core.io);
    const t = try std.Thread.spawn(.{}, acceptLoop, .{server});
    t.detach();
    port.store(server.socket.address.getPort(), .seq_cst);
}

fn acceptLoop(listener: net.Server) void {
    var server = listener;
    while (true) {
        const stream = server.accept(core.io) catch |e| {
            if (e == error.SocketNotListening) return;
            core.sleepMs(50);
            continue;
        };
        // a thread of its own (not a pool worker): a connection is kept open between requests
        const t = std.Thread.spawn(.{ .stack_size = 8 << 20 }, serve, .{stream}) catch {
            stream.close(core.io);
            continue;
        };
        t.detach();
    }
}

/// One connection: requests are answered one after the other until the client closes it.
fn serve(stream: net.Stream) void {
    defer stream.close(core.io);
    // the whole request head must fit in `in_buf`
    var in_buf: [32 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(core.io, &in_buf);
    var writer = stream.writer(core.io, &out_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        onRequest(arena.allocator(), &request) catch return;
        if (!keep_alive) return;
    }
}

const json_type = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};

fn onRequest(a: Allocator, request: *std.http.Server.Request) !void {
    const route = parseTarget(a, request.head.target) orelse return request.respond("", .{ .status = .not_found });
    // no server-initiated stream (GET) and no session to end (DELETE)
    if (request.head.method != .POST)
        return request.respond("", .{ .status = .method_not_allowed, .extra_headers = &.{.{ .name = "allow", .value = "POST" }} });
    if (!isKind(route.kind)) return request.respond("", .{ .status = .not_found });
    var auth: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
        auth = h.value;
        break;
    };
    if (!authorized(auth, token())) return request.respond("", .{ .status = .unauthorized });
    // (the head's strings are gone once the body is read)
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    const body = try body_reader.allocRemaining(a, .limited(64 << 20));
    if (try onPost(a, route.kind, route.chat, body)) |reply| {
        try request.respond(reply, .{ .extra_headers = &json_type });
    } else {
        try request.respond("", .{ .status = .accepted });
    }
}

fn authorized(header: ?[]const u8, tok: []const u8) bool {
    const h = header orelse return false;
    const prefix = "Bearer ";
    return std.mem.startsWith(u8, h, prefix) and std.mem.eql(u8, h[prefix.len..], tok);
}

fn isKind(kind: []const u8) bool {
    for ([_][]const u8{ "mcp", "db", "zalo", "office", "desktop" }) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

const Route = struct { kind: []const u8, chat: []const u8 };

/// "/<kind>/<chat>" (percent-decoded); anything else is no route.
fn parseTarget(a: Allocator, target: []const u8) ?Route {
    var path = target;
    if (std.mem.findScalar(u8, path, '?')) |i| path = path[0..i];
    if (path.len == 0 or path[0] != '/') return null;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    const kind = it.next() orelse return null;
    const chat = it.next() orelse return null;
    if (it.next() != null or kind.len == 0 or chat.len == 0) return null;
    return .{
        .kind = std.Uri.percentDecodeInPlace(a.dupe(u8, kind) catch return null),
        .chat = std.Uri.percentDecodeInPlace(a.dupe(u8, chat) catch return null),
    };
}

/// `--mcp-config` file for one chat (rewritten each launch: the port and token change).
pub fn configFor(a: Allocator, chat: []const u8) ?[]u8 {
    const p = port.load(.seq_cst);
    if (p == 0) return null;
    const name = std.mem.concat(a, u8, &.{ fileName(a, chat) catch return null, ".json" }) catch return null;
    const file = core.dataPath(a, &.{ "mcp", name }) catch return null;
    const desktop = @hasDecl(m.desktop, "enabled") and m.desktop.enabled(chat);
    core.writeFile(file, configJson(a, p, token(), chat, desktop) catch return null) catch return null;
    return file;
}

/// `chat` as a file name: every character but letters, digits, '-' and '_' becomes '_'.
fn fileName(a: Allocator, chat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < chat.len) {
        const ch = chat[i];
        i = @min(chat.len, i + (std.unicode.utf8ByteSequenceLength(ch) catch 1));
        try out.append(a, if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_');
    }
    return out.toOwnedSlice(a);
}

fn configJson(a: Allocator, p: u16, tok: []const u8, chat: []const u8, desktop: bool) ![]u8 {
    const chat_enc = try http.encodeQuery(a, chat);
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{tok});
    var aw: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try w.beginObject();
    try w.objectField("mcpServers");
    try w.beginObject();
    const servers = [_]struct { name: []const u8, kind: []const u8 }{
        .{ .name = BROWSER, .kind = "mcp" },
        .{ .name = DB, .kind = "db" },
        .{ .name = ZALO, .kind = "zalo" },
        .{ .name = OFFICE, .kind = "office" },
        .{ .name = DESKTOP, .kind = "desktop" },
    };
    for (servers) |s| {
        if (!desktop and std.mem.eql(u8, s.name, DESKTOP)) continue;
        try w.objectField(s.name);
        try w.write(.{
            .type = "http",
            .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/{s}/{s}", .{ p, s.kind, chat_enc }),
            .headers = .{ .Authorization = bearer },
        });
    }
    try w.endObject();
    try w.endObject();
    return aw.toOwnedSlice();
}

/// The reply to a POSTed JSON-RPC message (JSON text), or null for a notification (no reply).
fn onPost(a: Allocator, kind: []const u8, chat: []const u8, body: []const u8) !?[]const u8 {
    const msg = J.parse(a, body) orelse
        return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}";
    // notifications (no id) get no reply
    const id = try J.text(a, J.get(msg, "id") orelse return null);
    const method = J.str(J.get(msg, "method")) orelse "";
    if (try handle(a, kind, chat, method, J.get(msg, "params"))) |result|
        return try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result });
    const message = try std.fmt.allocPrint(a, "Method not found: {s}", .{method});
    return try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":{s}}}}}", .{ id, try core.toJson(a, message) });
}

/// The server one URL kind stands for: its name, and the module behind it (null: the browser
/// tools here, or a module this build does not have).
const Server = struct { name: []const u8, instructions: []const u8 };

fn instructionsOf(comptime mod: type) []const u8 {
    return if (@hasDecl(mod, "INSTRUCTIONS")) mod.INSTRUCTIONS else "";
}

fn serverOf(kind: []const u8) Server {
    if (std.mem.eql(u8, kind, "db")) return .{ .name = DB, .instructions = instructionsOf(m.mssql) };
    if (std.mem.eql(u8, kind, "zalo")) return .{ .name = ZALO, .instructions = instructionsOf(m.zalo) };
    if (std.mem.eql(u8, kind, "office")) return .{ .name = OFFICE, .instructions = instructionsOf(m.office) };
    if (std.mem.eql(u8, kind, "desktop")) return .{ .name = DESKTOP, .instructions = instructionsOf(m.desktop) };
    return .{ .name = BROWSER, .instructions = BROWSER_INSTRUCTIONS };
}

/// The JSON text of a module's tools array (none when this build does not have the module).
fn toolsOf(comptime mod: type, a: Allocator) ![]const u8 {
    return if (@hasDecl(mod, "tools")) mod.tools(a) else "[]";
}

const not_available = "This tool is not available in this build of VIBE CODE.";

/// A tool of a module that answers with text → the JSON text of the MCP content array.
fn textTool(comptime mod: type, a: Allocator, name: []const u8, args: Value, fail: *core.Fail) ![]const u8 {
    if (!@hasDecl(mod, "callTool")) return fail.set(a, not_available, .{});
    return text(a, try mod.callTool(a, name, args, fail));
}

/// The JSON text of a method's result; null when there is no such method.
fn handle(a: Allocator, kind: []const u8, chat: []const u8, method: []const u8, params: ?Value) !?[]const u8 {
    const is = struct {
        fn is(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.is;
    if (is(method, "initialize")) {
        const server = serverOf(kind);
        return try std.fmt.allocPrint(a, "{{\"protocolVersion\":{s},\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":{s},\"version\":{s}}},\"instructions\":{s}}}", .{
            try core.toJson(a, J.str(J.get(params, "protocolVersion")) orelse "2025-06-18"),
            try core.toJson(a, server.name),
            try core.toJson(a, @as([]const u8, @import("build_options").version)),
            try core.toJson(a, server.instructions),
        });
    }
    if (is(method, "ping")) return "{}";
    if (is(method, "tools/list")) {
        const tools = if (is(kind, "db"))
            try toolsOf(m.mssql, a)
        else if (is(kind, "zalo"))
            try toolsOf(m.zalo, a)
        else if (is(kind, "office"))
            try toolsOf(m.office, a)
        else if (is(kind, "desktop"))
            try toolsOf(m.desktop, a)
        else
            browser_tools;
        return try std.mem.concat(a, u8, &.{ "{\"tools\":", tools, "}" });
    }
    if (is(method, "tools/call")) {
        const tool = J.str(J.get(params, "name")) orelse "";
        const args: Value = J.get(params, "arguments") orelse .{ .object = .empty };
        var fail: core.Fail = .{};
        const result: anyerror![]const u8 = if (is(kind, "db"))
            textTool(m.mssql, a, tool, args, &fail)
        else if (is(kind, "zalo"))
            textTool(m.zalo, a, tool, args, &fail)
        else if (is(kind, "office"))
            textTool(m.office, a, tool, args, &fail)
        else if (is(kind, "desktop"))
            (if (@hasDecl(m.desktop, "callTool")) m.desktop.callTool(a, chat, tool, args, &fail) else fail.set(a, not_available, .{}))
        else
            callBrowser(a, chat, tool, args, &fail);
        const content = result catch |e|
            return try std.mem.concat(a, u8, &.{ "{\"content\":", try text(a, fail.text(e)), ",\"isError\":true}" });
        return try std.mem.concat(a, u8, &.{ "{\"content\":", content, "}" });
    }
    return null;
}

// ---------------- browser tools ----------------

const BROWSER_INSTRUCTIONS = "These tools drive the Web tab of this chat in VIBE CODE — the browser the user is looking at. Use them when the user refers to 'the browser', 'the web page', 'this page/form/screen', 'tab Web', or something visible on the page they have open " ++
    "(prefer them over Chrome or other browser tools: this is the page the user means). " ++
    "The page is usually already open, often mid-way through a form: start with browser_snapshot (or browser_screenshot) to see it as it is. " ++
    "Do not navigate to it again or reload it just to look at it — that would wipe what they typed. " ++
    "They are also how you check your own work: after you change the code of a web page or web app, open it here and verify it before saying it works " ++
    "(start its dev server first if it needs one, in the background). Use browser_navigate, with reload: true when the page is already open and does not hot-reload " ++
    "(if its fields hold input the user typed, ask before reloading), then browser_snapshot and try the changed feature. " ++
    "Results list console errors, uncaught exceptions and failed requests of the page: fix those too.";

/// The JSON text of the browser tools array.
const browser_tools =
    \\[
    \\{"name":"browser_navigate","description":"Open a URL in this chat's Web tab (the built-in browser the user sees). Waits for the page to load. Do NOT use it to look at the page the user already has open — that throws away what they typed; use browser_snapshot instead. Opening the URL that is already loaded is a no-op unless `reload` is true.","inputSchema":{"type":"object","properties":{"url":{"type":"string"},"reload":{"type":"boolean","description":"Reload even if this URL is already open, e.g. to see code you just changed. Loses unsaved form input: if the user typed into the page, ask first."}},"required":["url"]}},
    \\{"name":"browser_snapshot","description":"Start here. Reads the page that is open in the Web tab right now, exactly as the user left it (no reload): URL, title, visible text, a numbered list of interactive elements with their current values, and the page's console errors and failed requests. Use the numbers as `ref` for browser_click / browser_type. Take a new snapshot after the page changes.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"browser_click","description":"Click an element (by `ref` from browser_snapshot, or by CSS `selector`). Waits for a page it opens to load; reports the new URL and any errors the click caused.","inputSchema":{"type":"object","properties":{"ref":{"type":"string","description":"Element number from the last browser_snapshot, e.g. \"12\""},"selector":{"type":"string","description":"CSS selector, used when no ref is given"}}}},
    \\{"name":"browser_type","description":"Set the text of an input, textarea, contenteditable or select (option value or label). `submit` presses Enter afterwards.","inputSchema":{"type":"object","properties":{"ref":{"type":"string","description":"Element number from the last browser_snapshot, e.g. \"12\""},"selector":{"type":"string","description":"CSS selector, used when no ref is given"},"text":{"type":"string"},"submit":{"type":"boolean"}},"required":["text"]}},
    \\{"name":"browser_press_key","description":"Press a key in the page, e.g. \"Enter\", \"Escape\", \"Tab\", \"Down\", \"PageDown\", \"a\".","inputSchema":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}},
    \\{"name":"browser_screenshot","description":"Screenshot of the Web tab as the user sees it.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"browser_eval","description":"Run a JavaScript expression in the page and return its (JSON) result. Promises are awaited.","inputSchema":{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}}
    \\]
;

/// Numbers every visible interactive element (data-vibe-ref) and returns them with the page text.
const SNAPSHOT_JS =
    \\(() => {
    \\  const SEL = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[contenteditable=""],[contenteditable=true],[onclick]'
    \\  document.querySelectorAll('[data-vibe-ref]').forEach((e) => e.removeAttribute('data-vibe-ref'))
    \\  const elements = []
    \\  let n = 0
    \\  for (const el of document.querySelectorAll(SEL)) {
    \\    const r = el.getBoundingClientRect()
    \\    if (r.width === 0 && r.height === 0) continue
    \\    const cs = getComputedStyle(el)
    \\    if (cs.visibility === 'hidden' || cs.display === 'none') continue
    \\    el.setAttribute('data-vibe-ref', String(++n))
    \\    const tag = el.tagName.toLowerCase()
    \\    const kind = el.getAttribute('role') || (tag === 'input' ? 'input[' + (el.type || 'text') + ']' : tag)
    \\    const label = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.name || '')
    \\      .replace(/\s+/g, ' ').trim().slice(0, 80)
    \\    let line = '[' + n + '] ' + kind + ' "' + label + '"'
    \\    if (tag === 'a') line += ' -> ' + (el.getAttribute('href') || '').slice(0, 120)
    \\    if (tag === 'input' || tag === 'textarea') {
    \\      if (el.type !== 'checkbox' && el.type !== 'radio' && el.type !== 'password' && el.value) line += ' value="' + String(el.value).slice(0, 120) + '"'
    \\    } else if (tag === 'select' && el.selectedIndex >= 0) line += ' selected="' + (el.options[el.selectedIndex].text || '').trim().slice(0, 80) + '"'
    \\    if (el.disabled) line += ' (disabled)'
    \\    if (el.checked) line += ' (checked)'
    \\    elements.push(line)
    \\    if (n >= 400) break
    \\  }
    \\  const text = document.body ? document.body.innerText.replace(/\n{3,}/g, '\n\n').slice(0, 20000) : ''
    \\  return { title: document.title, url: location.href, elements, text }
    \\})()
;

/// JS expression for the element a call points at: { ref } from the last snapshot, or { selector }.
fn findJs(a: Allocator, args: Value, fail: *core.Fail) ![]const u8 {
    if (J.get(args, "ref")) |r| if (r != .null) {
        // a string as it is, a number as its digits; either way quoted for JS
        const quoted = try core.toJson(a, try J.display(a, r));
        return std.mem.concat(a, u8, &.{ "document.querySelector('[data-vibe-ref=\"' + ", quoted, " + '\"]')" });
    };
    if (J.str(J.get(args, "selector"))) |s|
        return std.mem.concat(a, u8, &.{ "document.querySelector(", try core.toJson(a, s), ")" });
    return fail.set(a, "Pass `ref` (from browser_snapshot) or `selector`.", .{});
}

fn clickJs(a: Allocator, find: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "(() => {\n  const el = ", find,
        \\
        \\  if (!el) return 'Element not found. Take a new browser_snapshot: refs change when the page changes.'
        \\  el.scrollIntoView({ block: 'center', inline: 'center' })
        \\  if (el.focus) el.focus()
        \\  const o = { bubbles: true, cancelable: true, view: window }
        \\  el.dispatchEvent(new PointerEvent('pointerdown', o)); el.dispatchEvent(new MouseEvent('mousedown', o))
        \\  el.dispatchEvent(new PointerEvent('pointerup', o)); el.dispatchEvent(new MouseEvent('mouseup', o))
        \\  el.click()
        \\  return 'ok'
        \\})()
    });
}

/// Replaces the field's value in a way React/Vue inputs notice (native setter + input/change).
fn typeJs(a: Allocator, find: []const u8, value: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "(() => {\n  const el = ", find,
        \\
        \\  if (!el) return 'Element not found. Take a new browser_snapshot: refs change when the page changes.'
        \\  el.scrollIntoView({ block: 'center' })
        \\  el.focus()
    , "\n  const text = ", try core.toJson(a, value),
        \\
        \\  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
        \\    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
        \\    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text)
        \\    el.dispatchEvent(new Event('input', { bubbles: true }))
        \\    el.dispatchEvent(new Event('change', { bubbles: true }))
        \\  } else if (el instanceof HTMLSelectElement) {
        \\    const opt = [...el.options].find((o) => o.value === text || o.text.trim() === text)
        \\    if (!opt) return 'No option "' + text + '" in this select.'
        \\    el.value = opt.value
        \\    el.dispatchEvent(new Event('input', { bubbles: true }))
        \\    el.dispatchEvent(new Event('change', { bubbles: true }))
        \\  } else if (el.isContentEditable) {
        \\    document.execCommand('selectAll')
        \\    document.execCommand('insertText', false, text)
        \\  } else return 'That element is not a text field.'
        \\  return 'ok'
        \\})()
    });
}

/// MCP content with one text block (JSON text).
fn text(a: Allocator, t: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "[{\"type\":\"text\",\"text\":", try core.toJson(a, t), "}]" });
}

fn samePage(x: []const u8, y: []const u8) bool {
    const norm = struct {
        fn norm(s: []const u8) []const u8 {
            const end = std.mem.findScalar(u8, s, '#') orelse s.len;
            return std.mem.trimEnd(u8, s[0..end], "/");
        }
    }.norm;
    return std.mem.eql(u8, norm(x), norm(y));
}

const PAGE_STATE_JS = "({ url: location.href, title: document.title, ready: document.readyState })";

/// Waits (up to `max_ms`) for the document to finish loading; returns its { url, title, ready }.
fn settle(a: Allocator, tab: []const u8, max_ms: u64) ?Value {
    const began = core.monoMs();
    var last: ?Value = null;
    while (core.monoMs() -| began < max_ms) {
        core.sleepMs(250);
        var fail: core.Fail = .{};
        const v = browser.eval(a, tab, PAGE_STATE_JS, &fail) catch continue;
        last = v;
        const url = J.str(J.get(v, "url")) orelse continue;
        if (std.mem.eql(u8, J.str(J.get(v, "ready")) orelse "", "complete") and !std.mem.eql(u8, url, "about:blank")) break;
    }
    return last;
}

/// The page's errors (since `since`, if given) as a block to append to a tool result.
fn errorsNote(a: Allocator, tab: []const u8, since: ?u64) ![]const u8 {
    return errorsBlock(a, browser.errors(a, tab, since));
}

fn errorsBlock(a: Allocator, e: []const []const u8) ![]const u8 {
    if (e.len == 0) return "";
    return std.fmt.allocPrint(a, "\n\nConsole errors / failed requests ({d}):\n- {s}", .{ e.len, try std.mem.join(a, "\n- ", e) });
}

/// After a click / key press: let a page it opens load, then say where we are and what broke.
fn afterAction(a: Allocator, tab: []const u8, result: []const u8, before: []const u8, since: u64) ![]const u8 {
    if (!std.mem.eql(u8, result, "ok")) return text(a, result);
    const now = settle(a, tab, 15_000);
    const url = J.str(J.get(now, "url")) orelse "";
    const moved = if (url.len > 0 and !std.mem.eql(u8, url, before))
        try std.fmt.allocPrint(a, " — now at {s} \"{s}\"", .{ url, J.str(J.get(now, "title")) orelse "" })
    else
        "";
    return text(a, try std.mem.concat(a, u8, &.{ "ok", moved, try errorsNote(a, tab, since) }));
}

fn pageUrl(a: Allocator, tab: []const u8) []const u8 {
    var fail: core.Fail = .{};
    return J.str(browser.eval(a, tab, "location.href", &fail) catch null) orelse "";
}

/// One browser tool → the JSON text of the MCP content array.
fn callBrowser(a: Allocator, chat: []const u8, name: []const u8, args: Value, fail: *core.Fail) ![]const u8 {
    const tab = try browser.viewFor(a, chat, fail);
    browser.wake(a, tab);
    const since = core.monoMs();
    const is = struct {
        fn is(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.is;
    if (is(name, "browser_navigate")) {
        const url = J.str(J.get(args, "url")) orelse "";
        if (!(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "file:")))
            return fail.set(a, "Only http(s) and file URLs.", .{});
        var ignored: core.Fail = .{};
        const here: ?Value = browser.eval(a, tab, "({ url: location.href, title: document.title })", &ignored) catch null;
        const cur = J.str(J.get(here, "url")) orelse "";
        if (!(J.boolean(J.get(args, "reload")) orelse false) and samePage(cur, url))
            return text(a, try std.fmt.allocPrint(a, "Already open: {s} — \"{s}\". Not reloaded, so the user's form input is kept. Use browser_snapshot to read it.", .{ cur, J.str(J.get(here, "title")) orelse "" }));
        _ = std.Uri.parse(url) catch return fail.set(a, "bad URL: {s}", .{url});
        browser.navigate(tab, url);
        const last = settle(a, tab, 30_000);
        return text(a, try std.fmt.allocPrint(a, "Loaded {s} — \"{s}\"{s}", .{ J.str(J.get(last, "url")) orelse url, J.str(J.get(last, "title")) orelse "", try errorsNote(a, tab, null) }));
    }
    if (is(name, "browser_snapshot")) {
        const s = try browser.eval(a, tab, SNAPSHOT_JS, fail);
        return text(a, try snapshotText(a, s, try errorsNote(a, tab, null)));
    }
    if (is(name, "browser_click")) {
        const before = pageUrl(a, tab);
        const r = try valueText(a, try browser.eval(a, tab, try clickJs(a, try findJs(a, args, fail)), fail));
        return afterAction(a, tab, r, before, since);
    }
    if (is(name, "browser_type")) {
        const js = try typeJs(a, try findJs(a, args, fail), J.str(J.get(args, "text")) orelse "");
        const r = try valueText(a, try browser.eval(a, tab, js, fail));
        if (!is(r, "ok") or !(J.boolean(J.get(args, "submit")) orelse false)) return text(a, r);
        const before = pageUrl(a, tab);
        try browser.pressKey(a, tab, "Enter", fail);
        return afterAction(a, tab, r, before, since);
    }
    if (is(name, "browser_press_key")) {
        const before = pageUrl(a, tab);
        try browser.pressKey(a, tab, J.str(J.get(args, "key")) orelse "", fail);
        return afterAction(a, tab, "ok", before, since);
    }
    if (is(name, "browser_screenshot")) {
        if (!browser.isVisible(tab))
            return text(a, "The Web tab is hidden (another chat or the Source code tab is in front), so there is nothing to capture.");
        const r = try browser.cdp(a, tab, "Page.captureScreenshot", "{\"format\":\"png\"}", fail);
        const data = J.str(J.get(r, "data")) orelse "";
        if (data.len == 0 or !isBase64(a, data)) return text(a, "Could not capture the Web tab.");
        return std.mem.concat(a, u8, &.{ "[{\"type\":\"image\",\"data\":", try core.toJson(a, data), ",\"mimeType\":\"image/png\"}]" });
    }
    if (is(name, "browser_eval")) {
        const v = try browser.eval(a, tab, J.str(J.get(args, "expression")) orelse "", fail);
        return text(a, if (v == .null) "undefined" else try std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }));
    }
    return fail.set(a, "Unknown tool {s}", .{name});
}

/// What browser_snapshot says, from the page's { url, title, elements, text }.
fn snapshotText(a: Allocator, s: Value, errors_note: []const u8) ![]const u8 {
    var elements: std.ArrayList(u8) = .empty;
    var first = true;
    for (J.items(J.get(s, "elements"))) |e| if (J.str(e)) |line| {
        if (!first) try elements.append(a, '\n');
        first = false;
        try elements.appendSlice(a, line);
    };
    return std.fmt.allocPrint(a, "URL: {s}\nTitle: {s}\n\nInteractive elements:\n{s}\n\nPage text:\n{s}{s}", .{
        J.str(J.get(s, "url")) orelse "",
        J.str(J.get(s, "title")) orelse "",
        if (elements.items.len == 0) "(none)" else elements.items,
        J.str(J.get(s, "text")) orelse "",
        errors_note,
    });
}

fn isBase64(a: Allocator, data: []const u8) bool {
    const decoder = std.base64.standard.Decoder;
    const buf = a.alloc(u8, decoder.calcSizeForSlice(data) catch return false) catch return false;
    defer a.free(buf);
    decoder.decode(buf, data) catch return false;
    return true;
}

fn valueText(a: Allocator, v: Value) ![]const u8 {
    return J.display(a, v);
}

// ---------------- tests ----------------

test "routes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = parseTarget(a, "/mcp/chat%20one%2F2?x=1").?;
    try std.testing.expectEqualStrings("mcp", r.kind);
    try std.testing.expectEqualStrings("chat one/2", r.chat);
    try std.testing.expectEqualStrings("nope", parseTarget(a, "/nope/c").?.kind);
    for ([_][]const u8{ "/", "/mcp", "/mcp/", "//chat", "/mcp/chat/", "/mcp/chat/more", "mcp/chat", "", "*" }) |bad|
        try std.testing.expect(parseTarget(a, bad) == null);
    try std.testing.expect(isKind("mcp") and isKind("db") and isKind("zalo") and isKind("office") and isKind("desktop"));
    try std.testing.expect(!isKind("nope") and !isKind("") and !isKind("MCP"));
    try std.testing.expect(authorized("Bearer abc", "abc"));
    try std.testing.expect(!authorized("Bearer abcd", "abc"));
    try std.testing.expect(!authorized("bearer abc", "abc"));
    try std.testing.expect(!authorized("abc", "abc"));
    try std.testing.expect(!authorized(null, "abc"));
}

test "the config file of a chat" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a1b2-c3_d4", try fileName(a, "a1b2-c3_d4"));
    try std.testing.expectEqualStrings("chat_1__x_", try fileName(a, "chat 1/đx."));

    const v = J.parse(a, try configJson(a, 4321, "tok", "chat 1/é", false)).?;
    const servers = J.get(v, "mcpServers").?.object;
    try std.testing.expectEqual(@as(usize, 4), servers.count());
    try std.testing.expectEqualStrings("http", J.str(J.path(v, &.{ "mcpServers", "vibe-browser", "type" })).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:4321/mcp/chat%201%2F%C3%A9", J.str(J.path(v, &.{ "mcpServers", "vibe-browser", "url" })).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:4321/db/chat%201%2F%C3%A9", J.str(J.path(v, &.{ "mcpServers", "vibe-mssql", "url" })).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:4321/zalo/chat%201%2F%C3%A9", J.str(J.path(v, &.{ "mcpServers", "vibe-zalo", "url" })).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:4321/office/chat%201%2F%C3%A9", J.str(J.path(v, &.{ "mcpServers", "vibe-office", "url" })).?);
    try std.testing.expectEqualStrings("Bearer tok", J.str(J.path(v, &.{ "mcpServers", "vibe-office", "headers", "Authorization" })).?);
    try std.testing.expect(J.path(v, &.{ "mcpServers", "vibe-desktop" }) == null);
    // the URL the config names is the route the server reads back
    try std.testing.expectEqualStrings("chat 1/é", parseTarget(a, "/mcp/chat%201%2F%C3%A9").?.chat);

    const with = J.parse(a, try configJson(a, 4321, "tok", "c", true)).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:4321/desktop/c", J.str(J.path(with, &.{ "mcpServers", "vibe-desktop", "url" })).?);
}

test "JSON-RPC" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const init = J.parse(a, (try onPost(a, "mcp", "c", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}")).?).?;
    try std.testing.expectEqualStrings("2.0", J.str(J.get(init, "jsonrpc")).?);
    try std.testing.expectEqual(@as(?u64, 1), J.uint(J.get(init, "id")));
    try std.testing.expectEqualStrings("2024-11-05", J.str(J.path(init, &.{ "result", "protocolVersion" })).?);
    try std.testing.expect(J.path(init, &.{ "result", "capabilities", "tools" }).? == .object);
    try std.testing.expectEqualStrings(BROWSER, J.str(J.path(init, &.{ "result", "serverInfo", "name" })).?);
    try std.testing.expectEqualStrings(@import("build_options").version, J.str(J.path(init, &.{ "result", "serverInfo", "version" })).?);
    try std.testing.expectEqualStrings(BROWSER_INSTRUCTIONS, J.str(J.path(init, &.{ "result", "instructions" })).?);

    // no version asked for, a string id, another server
    const db = J.parse(a, (try onPost(a, "db", "c", "{\"id\":\"x-1\",\"method\":\"initialize\"}")).?).?;
    try std.testing.expectEqualStrings("x-1", J.str(J.get(db, "id")).?);
    try std.testing.expectEqualStrings("2025-06-18", J.str(J.path(db, &.{ "result", "protocolVersion" })).?);
    try std.testing.expectEqualStrings(DB, J.str(J.path(db, &.{ "result", "serverInfo", "name" })).?);
    inline for (.{ .{ "zalo", ZALO }, .{ "office", OFFICE }, .{ "desktop", DESKTOP } }) |kv| {
        const v = J.parse(a, (try onPost(a, kv[0], "c", "{\"id\":2,\"method\":\"initialize\"}")).?).?;
        try std.testing.expectEqualStrings(kv[1], J.str(J.path(v, &.{ "result", "serverInfo", "name" })).?);
    }

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", (try onPost(a, "mcp", "c", "{\"id\":7,\"method\":\"ping\"}")).?);
    // an id that is null is still an id
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}", (try onPost(a, "mcp", "c", "{\"id\":null,\"method\":\"ping\"}")).?);
    // notifications (no id) get no reply; neither does a message that is not an object
    try std.testing.expect((try onPost(a, "mcp", "c", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == null);
    try std.testing.expect((try onPost(a, "mcp", "c", "[1,2]")) == null);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
        (try onPost(a, "mcp", "c", "{oops")).?,
    );
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Method not found: resources/list\"}}",
        (try onPost(a, "mcp", "c", "{\"id\":3,\"method\":\"resources/list\"}")).?,
    );
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Method not found: \"}}",
        (try onPost(a, "mcp", "c", "{\"id\":3}")).?,
    );

    const list = J.parse(a, (try onPost(a, "mcp", "c", "{\"id\":4,\"method\":\"tools/list\"}")).?).?;
    const tools = J.items(J.path(list, &.{ "result", "tools" }));
    const names = [_][]const u8{ "browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_press_key", "browser_screenshot", "browser_eval" };
    try std.testing.expectEqual(names.len, tools.len);
    for (names, tools) |name, tool| {
        try std.testing.expectEqualStrings(name, J.str(J.get(tool, "name")).?);
        try std.testing.expect(J.str(J.get(tool, "description")).?.len > 20);
        try std.testing.expectEqualStrings("object", J.str(J.path(tool, &.{ "inputSchema", "type" })).?);
        try std.testing.expect(J.path(tool, &.{ "inputSchema", "properties" }).? == .object);
    }
    try std.testing.expectEqualStrings("Element number from the last browser_snapshot, e.g. \"12\"", J.str(J.path(tools[2], &.{ "inputSchema", "properties", "ref", "description" })).?);
    try std.testing.expectEqual(@as(usize, 4), J.path(tools[3], &.{ "inputSchema", "properties" }).?.object.count());
    try std.testing.expectEqualStrings("text", J.str(J.at(J.path(tools[3], &.{ "inputSchema", "required" }), 0)).?);
}

test "the scripts the browser tools run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    try std.testing.expectEqualStrings("document.querySelector('[data-vibe-ref=\"' + \"12\" + '\"]')", try findJs(a, J.parse(a, "{\"ref\":\"12\",\"selector\":\"#x\"}").?, &fail));
    try std.testing.expectEqualStrings("document.querySelector('[data-vibe-ref=\"' + \"12\" + '\"]')", try findJs(a, J.parse(a, "{\"ref\":12}").?, &fail));
    try std.testing.expectEqualStrings("document.querySelector(\"a[href=\\\"/x\\\"]\")", try findJs(a, J.parse(a, "{\"ref\":null,\"selector\":\"a[href=\\\"/x\\\"]\"}").?, &fail));
    try std.testing.expectError(error.Failed, findJs(a, J.parse(a, "{\"selector\":5}").?, &fail));
    try std.testing.expectEqualStrings("Pass `ref` (from browser_snapshot) or `selector`.", fail.msg);

    const click = try clickJs(a, "document.querySelector(\"#go\")");
    try std.testing.expect(std.mem.startsWith(u8, click, "(() => {\n  const el = document.querySelector(\"#go\")\n  if (!el) return 'Element not found."));
    try std.testing.expect(std.mem.endsWith(u8, click, "  el.click()\n  return 'ok'\n})()"));

    const typed = try typeJs(a, "document.querySelector(\"#q\")", "it's \"quoted\"\n");
    try std.testing.expect(std.mem.startsWith(u8, typed, "(() => {\n  const el = document.querySelector(\"#q\")\n  if (!el) return"));
    try std.testing.expect(std.mem.find(u8, typed, "\n  el.focus()\n  const text = \"it's \\\"quoted\\\"\\n\"\n  if (el instanceof HTMLInputElement") != null);
    try std.testing.expect(std.mem.endsWith(u8, typed, "  } else return 'That element is not a text field.'\n  return 'ok'\n})()"));

    try std.testing.expect(std.mem.startsWith(u8, SNAPSHOT_JS, "(() => {\n  const SEL = 'a[href],button,"));
    try std.testing.expect(std.mem.find(u8, SNAPSHOT_JS, ".replace(/\\s+/g, ' ')") != null);
    try std.testing.expect(std.mem.find(u8, SNAPSHOT_JS, "replace(/\\n{3,}/g, '\\n\\n')") != null);
    try std.testing.expect(std.mem.endsWith(u8, SNAPSHOT_JS, "return { title: document.title, url: location.href, elements, text }\n})()"));
}

test "tool results" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"a \\\"b\\\"\\nc\"}]", try text(a, "a \"b\"\nc"));
    try std.testing.expectEqualStrings("ok", try valueText(a, .{ .string = "ok" }));
    try std.testing.expectEqualStrings("null", try valueText(a, .null));
    try std.testing.expectEqualStrings("[1,true]", try valueText(a, J.parse(a, "[1, true]").?));

    try std.testing.expect(samePage("http://localhost:3000/", "http://localhost:3000"));
    try std.testing.expect(samePage("http://localhost:3000/a#top", "http://localhost:3000/a/"));
    try std.testing.expect(!samePage("http://localhost:3000/a", "http://localhost:3000/b"));
    try std.testing.expect(!samePage("http://localhost:3000/a?x=1", "http://localhost:3000/a"));
    try std.testing.expect(samePage("", ""));

    try std.testing.expectEqualStrings("", try errorsBlock(a, &.{}));
    try std.testing.expectEqualStrings("\n\nConsole errors / failed requests (2):\n- one\n- two", try errorsBlock(a, &.{ "one", "two" }));

    const page = J.parse(a, "{\"url\":\"http://x/\",\"title\":\"T\",\"elements\":[\"[1] button \\\"Go\\\"\",\"[2] a \\\"Home\\\" -> /\"],\"text\":\"Hello\"}").?;
    try std.testing.expectEqualStrings("URL: http://x/\nTitle: T\n\nInteractive elements:\n[1] button \"Go\"\n[2] a \"Home\" -> /\n\nPage text:\nHello\n\nE", try snapshotText(a, page, "\n\nE"));
    try std.testing.expectEqualStrings("URL: \nTitle: \n\nInteractive elements:\n(none)\n\nPage text:\n", try snapshotText(a, .null, ""));

    try std.testing.expect(isBase64(a, "aGVsbG8="));
    try std.testing.expect(!isBase64(a, "not base64!"));
}

test "the server answers over HTTP" {
    // global state that outlives the test (the listener, the HTTP client): not the leak-checked allocator
    core.gpa = std.heap.smp_allocator;
    core.io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try start();
    const p = port.load(.seq_cst);
    try std.testing.expect(p != 0);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp/chat-1", .{p});
    const auth = [_]http.Header{.{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token()}) }};
    const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"0\"}}}";

    // without the token, or with another one: refused before anything is read
    try std.testing.expectEqual(@as(u16, 401), (try http.postJson(a, url, &.{}, initialize)).status);
    try std.testing.expectEqual(@as(u16, 401), (try http.postJson(a, url, &.{.{ .name = "Authorization", .value = "Bearer 000000000000000000000000000000000000000000000000" }}, initialize)).status);

    const init = try http.postJson(a, url, &auth, initialize);
    try std.testing.expectEqual(@as(u16, 200), init.status);
    try std.testing.expectEqualStrings("application/json", init.header("content-type").?);
    const iv = J.parse(a, init.body).?;
    try std.testing.expectEqual(@as(?u64, 1), J.uint(J.get(iv, "id")));
    try std.testing.expectEqualStrings("2025-03-26", J.str(J.path(iv, &.{ "result", "protocolVersion" })).?);
    try std.testing.expectEqualStrings(BROWSER, J.str(J.path(iv, &.{ "result", "serverInfo", "name" })).?);

    // the notification that follows gets no reply
    const note = try http.postJson(a, url, &auth, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try std.testing.expectEqual(@as(u16, 202), note.status);
    try std.testing.expectEqual(@as(usize, 0), note.body.len);

    const list = try http.postJson(a, url, &auth, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    try std.testing.expectEqual(@as(u16, 200), list.status);
    const tools = J.items(J.path(J.parse(a, list.body), &.{ "result", "tools" }));
    try std.testing.expectEqual(@as(usize, 7), tools.len);
    try std.testing.expectEqualStrings("browser_navigate", J.str(J.get(tools[0], "name")).?);
    try std.testing.expectEqualStrings("browser_eval", J.str(J.get(tools[6], "name")).?);

    // the other servers share the port: the path says which one
    const db = try http.postJson(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/db/chat%201", .{p}), &auth, initialize);
    try std.testing.expectEqualStrings(DB, J.str(J.path(J.parse(a, db.body), &.{ "result", "serverInfo", "name" })).?);

    const bad = try http.postJson(a, url, &auth, "{oops");
    try std.testing.expectEqual(@as(u16, 200), bad.status);
    try std.testing.expectEqual(@as(i64, -32700), J.path(J.parse(a, bad.body), &.{ "error", "code" }).?.integer);
    const unknown = try http.postJson(a, url, &auth, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/list\"}");
    try std.testing.expectEqual(@as(i64, -32601), J.path(J.parse(a, unknown.body), &.{ "error", "code" }).?.integer);

    // no server-initiated stream (GET) and no session to end (DELETE), token or not
    inline for (.{ std.http.Method.GET, std.http.Method.DELETE }) |method| {
        const r = try http.request(a, url, .{ .method = method, .headers = &auth });
        try std.testing.expectEqual(@as(u16, 405), r.status);
        try std.testing.expectEqualStrings("POST", r.header("allow").?);
    }
    try std.testing.expectEqual(@as(u16, 405), (try http.request(a, url, .{ .method = .GET })).status);

    // not a server, not a route
    try std.testing.expectEqual(@as(u16, 404), (try http.postJson(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/nope/chat-1", .{p}), &auth, initialize)).status);
    try std.testing.expectEqual(@as(u16, 404), (try http.postJson(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{p}), &auth, initialize)).status);
    try std.testing.expectEqual(@as(u16, 404), (try http.request(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{p}), .{ .method = .GET })).status);

    // a large body, and the connection still answers afterwards
    const pad = try a.alloc(u8, 300_000);
    @memset(pad, 'x');
    const big = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\",\"params\":{{\"pad\":\"{s}\"}}}}", .{pad});
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}", (try http.postJson(a, url, &auth, big)).body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{}}", (try http.postJson(a, url, &auth, "{\"id\":10,\"method\":\"ping\"}")).body);
}
