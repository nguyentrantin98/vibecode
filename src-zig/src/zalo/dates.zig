//! The little of `chrono` the Zalo module used: Unix milliseconds ↔ calendar dates (UTC), the
//! date formats cookies come in, and local time for what Claude reads.

const std = @import("std");
const core = @import("../core.zig");
const Allocator = std.mem.Allocator;

pub const DateTime = struct {
    year: i64,
    /// 1–12
    month: u8,
    /// 1–31
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    ms: u16 = 0,
};

const ms_per_day = 86_400_000;

/// Days since 1970-01-01 of a date in the proleptic Gregorian calendar.
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Unix milliseconds of a UTC date.
pub fn toMs(d: DateTime) i64 {
    return daysFromCivil(d.year, d.month, d.day) * ms_per_day +
        @as(i64, d.hour) * 3_600_000 + @as(i64, d.minute) * 60_000 + @as(i64, d.second) * 1000 + d.ms;
}

/// The UTC date of Unix milliseconds.
pub fn fromMs(ms: i64) DateTime {
    const days = @divFloor(ms, ms_per_day);
    const rem: u32 = @intCast(@mod(ms, ms_per_day));
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{
        .year = yoe + era * 400 + @intFromBool(month <= 2),
        .month = month,
        .day = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1),
        .hour = @intCast(rem / 3_600_000),
        .minute = @intCast(rem / 60_000 % 60),
        .second = @intCast(rem / 1000 % 60),
        .ms = @intCast(rem % 1000),
    };
}

/// "2026-11-19T07:52:45.650Z" (what JS `Date.toISOString()` and tough-cookie write).
pub fn formatIso(a: Allocator, ms: i64) ![]u8 {
    const d = fromMs(ms);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(@max(0, d.year))), d.month, d.day, d.hour, d.minute, d.second, d.ms,
    });
}

fn digits(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 9) return null;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn validDate(d: DateTime) bool {
    if (d.month < 1 or d.month > 12 or d.day < 1 or d.hour > 23 or d.minute > 59 or d.second > 60) return false;
    const leap = @mod(d.year, 4) == 0 and (@mod(d.year, 100) != 0 or @mod(d.year, 400) == 0);
    const month_days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d.day <= month_days[d.month - 1];
}

/// "HH:MM" or "HH:MM:SS" into `d`.
fn parseClock(s: []const u8, d: *DateTime) bool {
    var it = std.mem.splitScalar(u8, s, ':');
    const h = digits(it.next() orelse return false) orelse return false;
    const m = digits(it.next() orelse return false) orelse return false;
    const sec = if (it.next()) |x| digits(x) orelse return false else 0;
    if (it.next() != null or h > 23 or m > 59 or sec > 60) return false;
    d.hour = @intCast(h);
    d.minute = @intCast(m);
    d.second = @intCast(sec);
    return true;
}

/// "+07:00" / "-0700" as milliseconds east of UTC.
fn parseOffset(s: []const u8) ?i64 {
    if (s.len < 5 or (s[0] != '+' and s[0] != '-')) return null;
    const rest = s[1..];
    const hh = digits(rest[0..2]) orelse return null;
    const mm = digits(if (rest.len == 5 and rest[2] == ':') rest[3..5] else if (rest.len == 4) rest[2..4] else return null) orelse return null;
    if (hh > 23 or mm > 59) return null;
    const off: i64 = (@as(i64, hh) * 60 + mm) * 60_000;
    return if (s[0] == '-') -off else off;
}

/// RFC 3339 ("2026-11-19T07:52:45.650Z", any fraction, "Z" or an offset) → Unix milliseconds.
pub fn parseRfc3339(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't' and s[10] != ' ')) return null;
    var d: DateTime = .{
        .year = digits(s[0..4]) orelse return null,
        .month = @intCast(digits(s[5..7]) orelse return null),
        .day = @intCast(digits(s[8..10]) orelse return null),
    };
    if (s[13] != ':' or s[16] != ':') return null;
    if (!parseClock(s[11..19], &d) or !validDate(d)) return null;
    var i: usize = 19;
    var frac_ms: i64 = 0;
    if (s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return null;
        // milliseconds: the first three digits
        var scale: i64 = 100;
        for (s[start..@min(i, start + 3)]) |ch| {
            frac_ms += (ch - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    const zone = s[i..];
    const off: i64 = if (std.mem.eql(u8, zone, "Z") or std.mem.eql(u8, zone, "z")) 0 else parseOffset(zone) orelse return null;
    if (zone.len > 1 and zone[3] != ':') return null;
    return toMs(d) + frac_ms - off;
}

fn monthOf(s: []const u8) ?u8 {
    if (s.len < 3) return null;
    const names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    for (names, 1..) |n, i| if (std.ascii.eqlIgnoreCase(s[0..3], n)) return @intCast(i);
    return null;
}

/// `Expires=` dates: RFC 1123 ("Wed, 18 Mar 2026 10:00:00 GMT"), RFC 850 / Netscape
/// ("Wednesday, 18-Mar-26 10:00:00 GMT") and asctime ("Mar 18 10:00:00 2026"), with or without the
/// weekday and the zone → Unix milliseconds.
pub fn parseHttpDate(text: []const u8) ?i64 {
    var tokens: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |tok| {
        // "18-Mar-2026" is three tokens; "-0700" is a zone
        if (std.ascii.isDigit(tok[0]) and std.mem.indexOfScalar(u8, tok, '-') != null and std.mem.indexOfScalar(u8, tok, ':') == null) {
            var parts = std.mem.tokenizeScalar(u8, tok, '-');
            while (parts.next()) |p| {
                if (n == tokens.len) return null;
                tokens[n] = p;
                n += 1;
            }
        } else {
            if (n == tokens.len) return null;
            tokens[n] = tok;
            n += 1;
        }
    }
    var t = tokens[0..n];
    // the weekday says nothing we need
    if (t.len > 0 and std.ascii.isAlphabetic(t[0][0]) and monthOf(t[0]) == null) t = t[1..];
    if (t.len < 4) return null;

    var d: DateTime = .{ .year = 0, .month = 0, .day = 0 };
    var year_tok: []const u8 = undefined;
    var rest: []const []const u8 = undefined;
    if (monthOf(t[0])) |m| {
        // asctime: Mar 18 10:00:00 2026
        d.month = m;
        d.day = @intCast(digits(t[1]) orelse return null);
        if (!parseClock(t[2], &d)) return null;
        year_tok = t[3];
        rest = t[4..];
    } else {
        d.day = @intCast(@min(99, digits(t[0]) orelse return null));
        d.month = monthOf(t[1]) orelse return null;
        year_tok = t[2];
        if (!parseClock(t[3], &d)) return null;
        rest = t[4..];
    }
    const y = digits(year_tok) orelse return null;
    // two digits: 00–49 are 20xx, 50–99 are 19xx (RFC 2822)
    d.year = if (year_tok.len <= 2) (if (y < 50) 2000 + @as(i64, y) else 1900 + @as(i64, y)) else y;
    if (!validDate(d)) return null;
    var off: i64 = 0;
    if (rest.len > 0) {
        const z = rest[0];
        if (z[0] == '+' or z[0] == '-') off = parseOffset(z) orelse return null;
        // GMT / UTC / UT / Z: nothing to add (other zone names are taken as UTC too)
    }
    return toMs(d) - off;
}

/// "HH:MM:SS dd/mm/yyyy" in local time (`toLocaleString('vi-VN', {hour12: false})`); "" when the
/// time cannot be shown.
pub fn fmtLocal(a: Allocator, ts: i64) ![]u8 {
    const d = toLocal(ts) orelse return a.dupe(u8, "");
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2} {d:0>2}/{d:0>2}/{d:0>4}", .{
        d.hour, d.minute, d.second, d.day, d.month, @as(u64, @intCast(@max(0, d.year))),
    });
}

/// The local date of Unix milliseconds, by the time-zone rules that apply on that date.
pub fn toLocal(ts: i64) ?DateTime {
    if (!core.is_windows) return fromMs(ts);
    const c = core.host.win.c;
    // FILETIME: 100 ns since 1601
    const ticks = std.math.mul(i64, std.math.add(i64, ts, 11_644_473_600_000) catch return null, 10_000) catch return null;
    if (ticks < 0) return null;
    const ft: c.FILETIME = .{ .dwLowDateTime = @truncate(@as(u64, @intCast(ticks))), .dwHighDateTime = @truncate(@as(u64, @intCast(ticks)) >> 32) };
    var utc: c.SYSTEMTIME = undefined;
    var local: c.SYSTEMTIME = undefined;
    if (c.FileTimeToSystemTime(&ft, &utc) == 0) return null;
    if (c.SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) return null;
    return .{
        .year = local.wYear,
        .month = @intCast(local.wMonth),
        .day = @intCast(local.wDay),
        .hour = @intCast(local.wHour),
        .minute = @intCast(local.wMinute),
        .second = @intCast(local.wSecond),
        .ms = @intCast(local.wMilliseconds),
    };
}

const testing = std.testing;

test "dates to milliseconds and back" {
    try testing.expectEqual(@as(i64, 0), toMs(.{ .year = 1970, .month = 1, .day = 1 }));
    try testing.expectEqual(@as(i64, 951_782_400_000), toMs(.{ .year = 2000, .month = 2, .day = 29 }));
    try testing.expectEqual(@as(i64, -86_400_000), toMs(.{ .year = 1969, .month = 12, .day = 31 }));
    const cases = [_]i64{ 0, 1, -1, 951_782_400_000, 1_731_999_999_999, 4_077_597_600_000, -2_208_988_800_000, 253_402_300_799_999 };
    for (cases) |ms| try testing.expectEqual(ms, toMs(fromMs(ms)));
    const d = fromMs(1_731_999_999_999);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 11, .day = 19, .hour = 7, .minute = 6, .second = 39, .ms = 999 }, d);
    try testing.expectEqual(DateTime{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .ms = 999 }, fromMs(-1));
}

test "ISO dates" {
    const a = testing.allocator;
    const s = try formatIso(a, 1_794_988_365_650);
    defer a.free(s);
    try testing.expectEqualStrings("2026-11-18T07:52:45.650Z", s);
    try testing.expectEqual(@as(?i64, 1_794_988_365_650), parseRfc3339("2026-11-18T07:52:45.650Z"));
    try testing.expectEqual(@as(?i64, 1_794_988_365_000), parseRfc3339("2026-11-18T07:52:45Z"));
    try testing.expectEqual(@as(?i64, 1_794_988_365_650), parseRfc3339("2026-11-18T14:52:45.650123+07:00"));
    try testing.expectEqual(@as(?i64, 1_794_988_365_600), parseRfc3339("2026-11-18T02:52:45.6-05:00"));
    try testing.expectEqual(@as(?i64, 4_077_597_600_000), parseRfc3339("2099-03-19T10:00:00.000Z"));
    for ([_][]const u8{ "", "2026-11-18", "2026-11-18T07:52:45", "2026-13-18T07:52:45Z", "2026-02-30T07:52:45Z", "2026-11-18T07:52:45.Z", "2026-11-18T07:52:45+0700", "Infinity" }) |bad|
        try testing.expectEqual(@as(?i64, null), parseRfc3339(bad));
}

test "cookie dates" {
    const want: ?i64 = 4_077_511_200_000; // 2099-03-18 10:00:00 UTC
    for ([_][]const u8{
        "Wed, 18 Mar 2099 10:00:00 GMT",
        "Wed, 18-Mar-2099 10:00:00 GMT",
        "18 Mar 2099 10:00:00 GMT",
        "18 Mar 2099 10:00:00",
        "Wednesday, 18-Mar-2099 10:00:00 UTC",
        "Wed, 18 Mar 2099 17:00:00 +0700",
        "Wed, 18 Mar 2099 05:00:00 -0500",
        "Wed Mar 18 10:00:00 2099",
        "Mar 18 10:00:00 2099",
        "  wed, 18 mar 2099 10:00:00 gmt ",
    }) |s| try testing.expectEqual(want, parseHttpDate(s));
    try testing.expectEqual(@as(?i64, 984_909_600_000), parseHttpDate("Wed, 18-Mar-2001 10:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 984_909_600_000), parseHttpDate("Sun, 18-Mar-01 10:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 921_751_200_000), parseHttpDate("Thu, 18-Mar-99 10:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 4_077_511_200_000 - 3_600_000 + 60_000), parseHttpDate("18 Mar 2099 09:01 GMT"));
    for ([_][]const u8{ "", "tomorrow", "18 Foo 2099 10:00:00 GMT", "32 Mar 2099 10:00:00 GMT", "18 Mar 2099", "18 Mar 2099 25:00:00 GMT" }) |bad|
        try testing.expectEqual(@as(?i64, null), parseHttpDate(bad));
}

test "local time" {
    const a = testing.allocator;
    const ts: i64 = 1_731_999_999_999;
    const s = try fmtLocal(a, ts);
    defer a.free(s);
    // "HH:MM:SS dd/mm/yyyy", some whole quarter of an hour away from UTC
    try testing.expectEqual(@as(usize, 19), s.len);
    try testing.expect(s[2] == ':' and s[5] == ':' and s[8] == ' ' and s[11] == '/' and s[14] == '/');
    const local = toLocal(ts).?;
    const diff = toMs(local) - ts;
    try testing.expect(@mod(diff, 900_000) == 0 and @abs(diff) <= 14 * 3_600_000);
    const again = try std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2} {d:0>2}/{d:0>2}/{d}", .{ local.hour, local.minute, local.second, local.day, local.month, local.year });
    defer a.free(again);
    try testing.expectEqualStrings(again, s);
    // before 1601 Windows has no time
    if (core.is_windows) try testing.expect(toLocal(-20_000_000_000_000) == null);
}
