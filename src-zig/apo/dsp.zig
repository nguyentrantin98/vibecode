//! The equalizer itself: a preamp and up to 10 peaking filters (RBJ audio-EQ cookbook biquads,
//! transposed direct form II in f64), run on interleaved f32 frames. No allocation, no locks:
//! `process` runs on the audio engine's real-time thread.

const std = @import("std");

pub const FREQS = [_]f64{ 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
pub const BANDS = FREQS.len;
pub const MAX_CHANNELS = 16;
/// about one octave per band
const Q = 1.41;

pub const Settings = struct {
    enabled: bool = false,
    gains: [BANDS]f64 = @splat(0),

    /// "1 -8 -6 -4 -2 0 0 0 0 0 0": on/off, then the band gains in dB (eq.txt, written by the app)
    pub fn parse(text: []const u8) ?Settings {
        var s: Settings = .{};
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n,");
        const on = it.next() orelse return null;
        s.enabled = std.mem.eql(u8, on, "1");
        for (&s.gains) |*g| {
            const tok = it.next() orelse return null;
            const v = std.fmt.parseFloat(f64, tok) catch return null;
            if (!std.math.isFinite(v)) return null;
            g.* = std.math.clamp(v, -15, 15);
        }
        return s;
    }
};

const Biquad = struct { b0: f64, b1: f64, b2: f64, a1: f64, a2: f64 };

pub const Coefs = struct {
    /// filters in use (bands at 0 dB are left out)
    count: u32 = 0,
    preamp: f64 = 1,
    q: [BANDS]Biquad = undefined,

    pub fn compute(s: Settings, rate: f64) Coefs {
        var c: Coefs = .{};
        if (!s.enabled or !(rate > 1000)) return c;
        var peak: f64 = 0;
        for (s.gains) |g| peak = @max(peak, g);
        // lower the level by the biggest boost so boosted bands cannot clip
        c.preamp = std.math.pow(f64, 10, -peak / 20);
        for (FREQS, s.gains) |f, g| {
            if (@abs(g) < 0.05 or f >= rate * 0.45) continue;
            const a = std.math.pow(f64, 10, g / 40);
            const w0 = 2 * std.math.pi * f / rate;
            const alpha = @sin(w0) / (2 * Q);
            const cw = @cos(w0);
            const a0 = 1 + alpha / a;
            c.q[c.count] = .{
                .b0 = (1 + alpha * a) / a0,
                .b1 = -2 * cw / a0,
                .b2 = (1 - alpha * a) / a0,
                .a1 = -2 * cw / a0,
                .a2 = (1 - alpha / a) / a0,
            };
            c.count += 1;
        }
        return c;
    }

    pub fn passthrough(c: *const Coefs) bool {
        return c.count == 0 and c.preamp == 1;
    }
};

/// Per channel, per filter: the two delay values.
pub const State = struct {
    z: [MAX_CHANNELS][BANDS][2]f64 = std.mem.zeroes([MAX_CHANNELS][BANDS][2]f64),

    pub fn reset(st: *State) void {
        st.z = std.mem.zeroes([MAX_CHANNELS][BANDS][2]f64);
    }
};

/// In place, `frames` frames of `channels` interleaved samples.
pub fn process(c: *const Coefs, st: *State, buf: [*]f32, frames: usize, channels: usize) void {
    if (c.passthrough()) return;
    const ch_n = @min(channels, MAX_CHANNELS);
    const n = c.count;
    for (0..frames) |i| {
        const frame = buf + i * channels;
        for (0..ch_n) |ch| {
            var x: f64 = frame[ch] * c.preamp;
            const zs = &st.z[ch];
            for (c.q[0..n], zs[0..n]) |q, *z| {
                const y = q.b0 * x + z[0];
                z[0] = q.b1 * x - q.a1 * y + z[1];
                z[1] = q.b2 * x - q.a2 * y;
                x = y;
            }
            // denormals cost a lot on x86 once the input goes quiet
            if (@abs(zs[0][0]) < 1e-30) for (zs[0..n]) |*z| {
                if (@abs(z[0]) < 1e-30) z[0] = 0;
                if (@abs(z[1]) < 1e-30) z[1] = 0;
            };
            frame[ch] = @floatCast(std.math.clamp(x, -4, 4));
        }
    }
}

// ---------------- tests ----------------

fn gainAt(c: *const Coefs, f: f64, rate: f64) f64 {
    // run a sine through it and compare the steady-state amplitude
    var st: State = .{};
    var buf: [48000]f32 = undefined;
    for (&buf, 0..) |*s, i| s.* = @floatCast(@sin(2 * std.math.pi * f * @as(f64, @floatFromInt(i)) / rate));
    process(c, &st, &buf, buf.len, 1);
    var peak: f64 = 0;
    for (buf[buf.len / 2 ..]) |s| peak = @max(peak, @abs(@as(f64, s)));
    return 20 * std.math.log10(peak);
}

test "parse" {
    const s = Settings.parse("1 -8 -6 -4 -2 0 0 1.5 3 0 0\r\n").?;
    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(f64, -8), s.gains[0]);
    try std.testing.expectEqual(@as(f64, 1.5), s.gains[6]);
    try std.testing.expect(Settings.parse("1 2 3") == null);
    try std.testing.expect(!Settings.parse("0 0 0 0 0 0 0 0 0 0 0").?.enabled);
}

test "off and flat pass audio through untouched" {
    const off = Coefs.compute(.{ .enabled = false, .gains = @splat(6) }, 48000);
    try std.testing.expect(off.passthrough());
    const flat = Coefs.compute(.{ .enabled = true }, 48000);
    try std.testing.expect(flat.passthrough());
}

test "cutting bass lowers bass and leaves the mids" {
    var s: Settings = .{ .enabled = true };
    s.gains[0] = -9;
    s.gains[1] = -7;
    s.gains[2] = -5;
    const c = Coefs.compute(s, 48000);
    try std.testing.expect(gainAt(&c, 40, 48000) < -6);
    try std.testing.expect(@abs(gainAt(&c, 3000, 48000)) < 0.5);
}

test "a boost is offset by the preamp so it cannot clip" {
    var s: Settings = .{ .enabled = true };
    s.gains[5] = 6;
    const c = Coefs.compute(s, 44100);
    const g = gainAt(&c, 1000, 44100);
    try std.testing.expect(g < 0.3 and g > -0.5);
    try std.testing.expect(gainAt(&c, 100, 44100) < -5);
}
