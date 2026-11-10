//! Permanent access: the computer's own key, its link, and one-time codes from an
//! authenticator app (TOTP, RFC 6238: HMAC-SHA1, 30-second steps, 6 digits — what Google
//! Authenticator and every other such app reads from an otpauth:// QR code).
//!
//! One 32-byte seed is kept between runs. HKDF-SHA256 gives from it the 16-byte key of the
//! permanent link (a browser finds the host with it, the way it does with the key of an ordinary
//! link from anywhere) and the 20-byte TOTP secret (shown as a QR code for the authenticator app).
//! The link alone lets no one in: the host asks for the current code.
const std = @import("std");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

pub const seed_len = 32;
pub const link_key_len = 16;
pub const secret_len = 20;
pub const digits = 6;
pub const step_s = 30;
/// What stands in a permanent link where an ordinary one has the 9-digit code: "#my-<key>".
/// Keep in sync with PERMANENT in web/viewer.js.
pub const link_name = "my";

pub const Identity = struct {
    link_key: [link_key_len]u8,
    secret: [secret_len]u8,

    pub fn fromSeed(seed: *const [seed_len]u8) Identity {
        const prk = HkdfSha256.extract("rdc permanent v1", seed);
        var id: Identity = undefined;
        HkdfSha256.expand(&id.link_key, "link", prk);
        HkdfSha256.expand(&id.secret, "totp", prk);
        return id;
    }
};

/// The time step a moment (seconds since 1970) falls into.
pub fn stepAt(unix_s: i64) u64 {
    return @intCast(@divFloor(@max(unix_s, 0), step_s));
}

/// The 6-digit code of a time step (RFC 4226 with the step as the counter).
pub fn code(secret: []const u8, step: u64) u32 {
    var counter: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter, step, .big);
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, &counter, secret);
    const at = mac[mac.len - 1] & 0x0f;
    const bin = std.mem.readInt(u32, mac[at..][0..4], .big) & 0x7fff_ffff;
    return bin % 1_000_000;
}

pub const Verdict = union(enum) {
    /// The code of this step: remember it, no code up to it works again.
    ok: u64,
    /// The right code of a step that was used already.
    used,
    wrong,
};

/// Checks an entered code against the current step, the one before and the one after (the
/// phone's clock may be a little off). Spaces and other non-digits in `input` are ignored.
/// A code works once: steps up to `last_used` are refused.
pub fn verify(secret: []const u8, input: []const u8, unix_s: i64, last_used: u64) Verdict {
    var value: u32 = 0;
    var n: usize = 0;
    for (input) |ch| {
        if (ch < '0' or ch > '9') continue;
        if (n == digits) return .wrong;
        value = value * 10 + (ch - '0');
        n += 1;
    }
    if (n != digits) return .wrong;
    const now = stepAt(unix_s);
    var verdict: Verdict = .wrong;
    // Every candidate is computed and compared, whichever one matches.
    var step = now -| 1;
    while (step <= now + 1) : (step += 1) {
        const diff = code(secret, step) ^ value;
        if (diff != 0) continue;
        if (step > last_used) verdict = .{ .ok = step } else if (verdict == .wrong) verdict = .used;
    }
    return verdict;
}

/// Wrong codes on the permanent link: at most 5 in half a minute and 20 in a day. Whoever
/// enters them has the link already, so past that the link waits, whoever asks.
pub const Guard = struct {
    pub const burst = 5;
    pub const burst_us: u64 = 30 * std.time.us_per_s;
    pub const day_limit = 20;
    pub const day_us: u64 = 24 * std.time.us_per_hour;

    /// When the last wrong codes came, on a clock that only goes forward.
    times: [day_limit]u64 = undefined,
    count: usize = 0,
    next: usize = 0,

    /// The time of the k-th most recent wrong code (1 — the latest), if there were that many.
    fn nth(g: *const Guard, k: usize) ?u64 {
        if (k > g.count) return null;
        return g.times[(g.next + day_limit - k) % day_limit];
    }

    /// 0 — a code may be tried now; otherwise how long to wait.
    pub fn waitUs(g: *const Guard, now_us: u64) u64 {
        var wait: u64 = 0;
        if (g.nth(burst)) |t| wait = @max(wait, burst_us -| (now_us -| t));
        if (g.nth(day_limit)) |t| wait = @max(wait, day_us -| (now_us -| t));
        return wait;
    }

    pub fn failed(g: *Guard, now_us: u64) void {
        g.times[g.next] = now_us;
        g.next = (g.next + 1) % day_limit;
        g.count = @min(g.count + 1, day_limit);
    }
};

/// Base32 (RFC 4648) without padding: how authenticator apps take a secret.
pub fn base32Len(n: usize) usize {
    return (n * 8 + 4) / 5;
}

pub fn base32(out: []u8, bytes: []const u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (bytes) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            out[n] = alphabet[(acc >> bits) & 31];
            n += 1;
        }
    }
    if (bits > 0) {
        out[n] = alphabet[(acc << (5 - bits)) & 31];
        n += 1;
    }
    return out[0..n];
}

pub const secret_text_len = base32Len(secret_len);
/// The longest account name in the URI, after percent-encoding: keeps the QR code small.
const max_account = 48;
pub const max_uri = "otpauth://totp/RDC:".len + max_account + "?secret=".len + secret_text_len + "&issuer=RDC".len;

/// otpauth://totp/RDC:<account>?secret=<base32>&issuer=RDC — the text of the QR code an
/// authenticator app scans. `account` is the computer's name; what does not fit is cut.
pub fn uri(buf: *[max_uri]u8, secret: *const [secret_len]u8, account: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("otpauth://totp/RDC:") catch unreachable;
    var used: usize = 0;
    var view = std.unicode.Utf8View.init(account) catch std.unicode.Utf8View.initUnchecked("");
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        const plain = cp.len == 1 and (std.ascii.isAlphanumeric(cp[0]) or std.mem.indexOfScalar(u8, "-._~", cp[0]) != null);
        const need = if (plain) 1 else cp.len * 3;
        if (used + need > max_account) break;
        used += need;
        if (plain) {
            w.writeByte(cp[0]) catch unreachable;
        } else {
            for (cp) |b| w.print("%{X:0>2}", .{b}) catch unreachable;
        }
    }
    if (used == 0) w.writeAll("computer") catch unreachable;
    var text: [secret_text_len]u8 = undefined;
    w.print("?secret={s}&issuer=RDC", .{base32(&text, secret)}) catch unreachable;
    return w.buffered();
}

/// "ABCD EFGH …": the secret for typing into the app by hand.
pub const grouped_len = secret_text_len + secret_text_len / 4 - 1;
pub fn grouped(buf: *[grouped_len]u8, secret: *const [secret_len]u8) []const u8 {
    var text: [secret_text_len]u8 = undefined;
    _ = base32(&text, secret);
    var n: usize = 0;
    for (text, 0..) |ch, i| {
        if (i > 0 and i % 4 == 0) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

const rfc_secret = "12345678901234567890";

test "totp: RFC 4226 counters" {
    const want = [_]u32{ 755224, 287082, 359152, 969429, 338314, 254676, 287922, 162583, 399871, 520489 };
    for (want, 0..) |w, i| try std.testing.expectEqual(w, code(rfc_secret, i));
}

test "totp: RFC 6238 times" {
    // The RFC lists 8 digits; ours are the last 6 of them.
    try std.testing.expectEqual(@as(u32, 287082), code(rfc_secret, stepAt(59)));
    try std.testing.expectEqual(@as(u32, 81804), code(rfc_secret, stepAt(1111111109)));
    try std.testing.expectEqual(@as(u32, 50471), code(rfc_secret, stepAt(1111111111)));
    try std.testing.expectEqual(@as(u32, 5924), code(rfc_secret, stepAt(1234567890)));
    try std.testing.expectEqual(@as(u32, 279037), code(rfc_secret, stepAt(2000000000)));
    try std.testing.expectEqual(@as(u32, 353130), code(rfc_secret, stepAt(20000000000)));
}

test "totp: the window, one use, what is typed" {
    const t: i64 = 1111111109; // step 37037036, code 081804
    const step = stepAt(t);
    try std.testing.expectEqual(Verdict{ .ok = step }, verify(rfc_secret, "081804", t, 0));
    try std.testing.expectEqual(Verdict{ .ok = step }, verify(rfc_secret, "081 804", t, 0));
    try std.testing.expectEqual(Verdict{ .ok = step }, verify(rfc_secret, " 0 8 1 8 0 4 ", t, step - 1));
    // The steps next to it: half a minute early or late still works, a minute does not.
    try std.testing.expectEqual(Verdict{ .ok = step }, verify(rfc_secret, "081804", t + 30, 0));
    try std.testing.expectEqual(Verdict{ .ok = step }, verify(rfc_secret, "081804", t - 30, 0));
    try std.testing.expectEqual(Verdict.wrong, verify(rfc_secret, "081804", t + 60, 0));
    try std.testing.expectEqual(Verdict.wrong, verify(rfc_secret, "081804", t - 60, 0));
    // Once used, neither this code nor an older one works.
    try std.testing.expectEqual(Verdict.used, verify(rfc_secret, "081804", t, step));
    try std.testing.expectEqual(Verdict.used, verify(rfc_secret, "081804", t, step + 1));
    // The next step's code (050471) still does.
    try std.testing.expectEqual(Verdict{ .ok = step + 1 }, verify(rfc_secret, "050471", t, step));
    try std.testing.expectEqual(Verdict.wrong, verify(rfc_secret, "081805", t, 0));
    try std.testing.expectEqual(Verdict.wrong, verify(rfc_secret, "81804", t, 0));
    try std.testing.expectEqual(Verdict.wrong, verify(rfc_secret, "0818040", t, 0));
    try std.testing.expectEqual(Verdict.wrong, verify(rfc_secret, "", t, 0));
    // A clock before 1970 counts as 1970.
    try std.testing.expectEqual(Verdict{ .ok = 1 }, verify(rfc_secret, "287082", -5, 0));
}

test "totp: guard — five wrong codes in half a minute, twenty in a day" {
    const s = std.time.us_per_s;
    var g: Guard = .{};
    var now: u64 = 1000 * s;
    for (0..Guard.burst - 1) |_| {
        try std.testing.expectEqual(@as(u64, 0), g.waitUs(now));
        g.failed(now);
        now += s;
    }
    try std.testing.expectEqual(@as(u64, 0), g.waitUs(now));
    g.failed(now); // the fifth, 4 s after the first
    try std.testing.expectEqual(26 * s, g.waitUs(now));
    try std.testing.expectEqual(@as(u64, 1), g.waitUs(now + 26 * s - 1));
    try std.testing.expectEqual(@as(u64, 0), g.waitUs(now + 26 * s));
    // Fifteen more, each as soon as it is allowed: then the day's limit holds.
    const first: u64 = 1000 * s;
    for (0..Guard.day_limit - Guard.burst) |_| {
        now += g.waitUs(now);
        try std.testing.expectEqual(@as(u64, 0), g.waitUs(now));
        g.failed(now);
    }
    try std.testing.expect(g.waitUs(now) > 23 * std.time.us_per_hour);
    try std.testing.expectEqual(@as(u64, 0), g.waitUs(first + Guard.day_us));
    // The window slides: one more is allowed once the oldest is a day old, and the next one waits again.
    now = first + Guard.day_us;
    g.failed(now);
    try std.testing.expect(g.waitUs(now) > 0);
}

test "totp: base32 (RFC 4648)" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", base32(&buf, ""));
    try std.testing.expectEqualStrings("MY", base32(&buf, "f"));
    try std.testing.expectEqualStrings("MZXQ", base32(&buf, "fo"));
    try std.testing.expectEqualStrings("MZXW6", base32(&buf, "foo"));
    try std.testing.expectEqualStrings("MZXW6YQ", base32(&buf, "foob"));
    try std.testing.expectEqualStrings("MZXW6YTB", base32(&buf, "fooba"));
    try std.testing.expectEqualStrings("MZXW6YTBOI", base32(&buf, "foobar"));
    try std.testing.expectEqual(@as(usize, 32), secret_text_len);
}

test "totp: the URI for the authenticator app" {
    var buf: [max_uri]u8 = undefined;
    const secret = rfc_secret.*;
    try std.testing.expectEqualStrings(
        "otpauth://totp/RDC:Tims-MacBook?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=RDC",
        uri(&buf, &secret, "Tims-MacBook"),
    );
    try std.testing.expectEqualStrings(
        "otpauth://totp/RDC:Tim%27s%20Mac%20%D0%B4?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=RDC",
        uri(&buf, &secret, "Tim's Mac \xd0\xb4"),
    );
    try std.testing.expectEqualStrings(
        "otpauth://totp/RDC:computer?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=RDC",
        uri(&buf, &secret, ""),
    );
    // A long name is cut between characters, never inside one.
    var name: [80]u8 = undefined;
    for (0..40) |i| name[i * 2 ..][0..2].* = "\xd0\xb4".*;
    const long = uri(&buf, &secret, &name);
    try std.testing.expect(long.len <= max_uri);
    try std.testing.expect(std.mem.indexOf(u8, long, ":%D0%B4%D0%B4%D0%B4%D0%B4%D0%B4%D0%B4%D0%B4%D0%B4?secret=") != null);
    var g: [grouped_len]u8 = undefined;
    try std.testing.expectEqualStrings("GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ", grouped(&g, &secret));
}

test "totp: identity from a seed" {
    const a = Identity.fromSeed(&@as([seed_len]u8, @splat(1)));
    const b = Identity.fromSeed(&@as([seed_len]u8, @splat(1)));
    const c = Identity.fromSeed(&@as([seed_len]u8, @splat(2)));
    try std.testing.expectEqualSlices(u8, &a.link_key, &b.link_key);
    try std.testing.expectEqualSlices(u8, &a.secret, &b.secret);
    try std.testing.expect(!std.mem.eql(u8, &a.link_key, &c.link_key));
    try std.testing.expect(!std.mem.eql(u8, &a.secret, &c.secret));
    try std.testing.expect(!std.mem.eql(u8, &a.link_key, a.secret[0..link_key_len]));
}
