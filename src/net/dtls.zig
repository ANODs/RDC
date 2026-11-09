//! DTLS 1.2 server (RFC 6347) for a WebRTC data channel (RFC 8827, RFC 8261): one
//! connection, the browser is the client. TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 with
//! X25519 or P-256, a self-signed ECDSA P-256 certificate, extended master secret
//! (RFC 7627). The client must present a certificate whose SHA-256 matches the
//! fingerprint from its SDP offer, and prove it owns the key (CertificateVerify).
//! Encrypted records pass an anti-replay window (RFC 6347, section 4.1.2.6).
//! Pure logic: datagrams in, datagrams and decrypted data out through a Sink.
const std = @import("std");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
const Ecdsa = crypto.sign.ecdsa.EcdsaP256Sha256;
const X25519 = crypto.dh.X25519;
const P256 = crypto.ecc.P256;

const version: u16 = 0xfefd; // DTLS 1.2

const content_ccs: u8 = 20;
const content_alert: u8 = 21;
const content_handshake: u8 = 22;
const content_app: u8 = 23;

const hs_client_hello: u8 = 1;
const hs_server_hello: u8 = 2;
const hs_certificate: u8 = 11;
const hs_server_key_exchange: u8 = 12;
const hs_certificate_request: u8 = 13;
const hs_server_hello_done: u8 = 14;
const hs_certificate_verify: u8 = 15;
const hs_client_key_exchange: u8 = 16;
const hs_finished: u8 = 20;

const suite_ecdhe_ecdsa_aes128_gcm_sha256: u16 = 0xc02b;
const suite_renegotiation_scsv: u16 = 0x00ff;
const group_x25519: u16 = 0x001d;
const group_p256: u16 = 0x0017;
const sig_ecdsa_p256_sha256: u16 = 0x0403;

const ext_supported_groups: u16 = 10;
const ext_ec_point_formats: u16 = 11;
const ext_signature_algorithms: u16 = 13;
const ext_extended_master_secret: u16 = 23;
const ext_renegotiation_info: u16 = 0xff01;

const alert_close_notify: u8 = 0;
const alert_handshake_failure: u8 = 40;
const alert_bad_certificate: u8 = 42;
const alert_decrypt_error: u8 = 51;
const alert_protocol_version: u8 = 70;

const header_len = 13;
const hs_header_len = 12;
/// Bytes a record adds to its data: header, explicit nonce, tag.
pub const overhead = header_len + 8 + 16;
/// Datagrams stay under this size (IPv6 minimum MTU minus headers, with room to spare).
pub const mtu = 1200;
const max_message = 4096;
/// Every handshake message of both sides: four client messages of at most max_message and our own.
const max_transcript = 24 * 1024;
const max_retransmits = 6;

// ---------------------------------------------------------------------------
// The host's identity: an ECDSA P-256 key and a self-signed certificate.

pub const Identity = struct {
    key: Ecdsa.KeyPair,
    cert_buf: [512]u8,
    cert_len: usize,
    /// SHA-256 of the certificate — goes into the SDP answer.
    fingerprint: [32]u8,

    pub fn cert(id: *const Identity) []const u8 {
        return id.cert_buf[0..id.cert_len];
    }

    pub fn generate(io: std.Io) !Identity {
        var id: Identity = .{ .key = Ecdsa.KeyPair.generate(io), .cert_buf = undefined, .cert_len = 0, .fingerprint = undefined };
        var serial: [8]u8 = undefined;
        io.random(&serial);
        serial[0] = (serial[0] & 0x7f) | 0x01; // a positive INTEGER with no leading zero byte
        var noise: [Ecdsa.noise_length]u8 = undefined;
        io.random(&noise);
        id.cert_len = (try selfSignedCert(&id.cert_buf, id.key, serial, noise)).len;
        Sha256.hash(id.cert(), &id.fingerprint, .{});
        return id;
    }
};

const oid_ecdsa_sha256 = [_]u8{ 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
const name_rdc = [_]u8{ 0x30, 0x0e, 0x31, 0x0c, 0x30, 0x0a, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x03, 'R', 'D', 'C' };
const validity = [_]u8{ 0x30, 0x1e, 0x17, 0x0d } ++ "250101000000Z".* ++ [_]u8{ 0x17, 0x0d } ++ "491231235959Z".*;
const spki_prefix = [_]u8{
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
};

/// DER: tag, minimal length, contents.
fn derWrap(out: []u8, tag: u8, contents: []const u8) []u8 {
    var n: usize = 0;
    out[n] = tag;
    n += 1;
    if (contents.len < 0x80) {
        out[n] = @intCast(contents.len);
        n += 1;
    } else if (contents.len < 0x100) {
        out[n] = 0x81;
        out[n + 1] = @intCast(contents.len);
        n += 2;
    } else {
        out[n] = 0x82;
        std.mem.writeInt(u16, out[n + 1 ..][0..2], @intCast(contents.len), .big);
        n += 3;
    }
    @memcpy(out[n..][0..contents.len], contents);
    return out[0 .. n + contents.len];
}

fn selfSignedCert(out: []u8, key: Ecdsa.KeyPair, serial: [8]u8, noise: [Ecdsa.noise_length]u8) ![]u8 {
    var body: [400]u8 = undefined;
    var n: usize = 0;
    const version_v3 = [_]u8{ 0xa0, 0x03, 0x02, 0x01, 0x02 };
    for ([_][]const u8{ &version_v3, &.{ 0x02, 0x08 }, &serial, &oid_ecdsa_sha256, &name_rdc, &validity, &name_rdc, &spki_prefix, &key.public_key.toUncompressedSec1() }) |part| {
        @memcpy(body[n..][0..part.len], part);
        n += part.len;
    }
    var tbs_buf: [410]u8 = undefined;
    const tbs = derWrap(&tbs_buf, 0x30, body[0..n]);
    const sig = try key.sign(tbs, noise);
    var sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&sig_der_buf);
    var bits: [80]u8 = undefined;
    bits[0] = 0; // no unused bits
    @memcpy(bits[1..][0..sig_der.len], sig_der);
    var bits_buf: [84]u8 = undefined;
    const bit_string = derWrap(&bits_buf, 0x03, bits[0 .. 1 + sig_der.len]);
    var all: [500]u8 = undefined;
    n = 0;
    for ([_][]const u8{ tbs, &oid_ecdsa_sha256, bit_string }) |part| {
        @memcpy(all[n..][0..part.len], part);
        n += part.len;
    }
    return derWrap(out, 0x30, all[0..n]);
}

// ---------------------------------------------------------------------------
// The browser's certificate. Only its public key is needed. std.crypto.Certificate.parse
// trusts its input (a long length overflows, a missing field is read past the end), so the
// browser's bytes never reach it: they are walked with bounds first, then the key is read here.

const der_sequence: u8 = 0x30;
/// Deeper than any certificate nests.
const der_max_depth = 16;

const Der = struct {
    tag: u8,
    body: []const u8,
    /// Header and contents.
    size: usize,
};

/// The element at the start of `b`: a one-byte tag, a short length or a long one of 1–4 bytes,
/// contents within `b`. null — truncated, an indefinite or over-long length, or a multi-byte tag.
fn derNext(b: []const u8) ?Der {
    if (b.len < 2 or b[0] & 0x1f == 0x1f) return null;
    var len: usize = b[1];
    var header: usize = 2;
    if (len & 0x80 != 0) {
        const n = len & 0x7f;
        if (n == 0 or n > 4 or b.len - 2 < n) return null;
        len = 0;
        for (b[2..][0..n]) |byte| len = (len << 8) | byte;
        header += n;
    }
    if (len > b.len - header) return null;
    return .{ .tag = b[0], .body = b[header..][0..len], .size = header + len };
}

/// Every element of `b` is complete and within its parent, down through every constructed one.
fn derWellFormed(b: []const u8, depth: u8) bool {
    if (depth == 0) return false;
    var rest = b;
    while (rest.len > 0) {
        const e = derNext(rest) orelse return false;
        if (e.tag & 0x20 != 0 and !derWellFormed(e.body, depth - 1)) return false;
        rest = rest[e.size..];
    }
    return true;
}

fn derTake(rest: *[]const u8) error{Decode}!Der {
    const e = derNext(rest.*) orelse return error.Decode;
    rest.* = rest.*[e.size..];
    return e;
}

/// The subject public key (SEC1) of an X.509 certificate with an ECDSA P-256 key.
fn certP256Key(cert: []const u8) error{ Decode, Unsupported }![]const u8 {
    if (!derWellFormed(cert, der_max_depth)) return error.Decode;
    var all = cert;
    const outer = try derTake(&all);
    if (outer.tag != der_sequence or all.len != 0) return error.Decode;
    var top = outer.body;
    const tbs = try derTake(&top);
    if (tbs.tag != der_sequence) return error.Decode;
    // TBSCertificate: [0] version (optional), serial number, signature algorithm, issuer,
    // validity, subject, subject public key info, then the rest.
    var fields = tbs.body;
    var field = try derTake(&fields);
    if (field.tag == 0xa0) field = try derTake(&fields);
    if (field.tag != 0x02) return error.Decode;
    for (0..4) |_| if ((try derTake(&fields)).tag != der_sequence) return error.Decode;
    const spki = try derTake(&fields);
    if (spki.tag != der_sequence) return error.Decode;
    var parts = spki.body;
    const algorithm = try derTake(&parts);
    const key = try derTake(&parts);
    if (algorithm.tag != der_sequence or key.tag != 0x03 or key.body.len < 1 or key.body[0] != 0) return error.Decode;
    // id-ecPublicKey with the named curve prime256v1, as in our own certificate.
    if (!std.mem.eql(u8, algorithm.body, spki_prefix[4..23])) return error.Unsupported;
    return key.body[1..];
}

// ---------------------------------------------------------------------------
// TLS 1.2 PRF with SHA-256 (RFC 5246, section 5).

pub fn prf(out: []u8, secret: []const u8, label: []const u8, seed_a: []const u8, seed_b: []const u8) void {
    var a: [32]u8 = undefined; // A(1) = HMAC(secret, label + seed)
    {
        var h = HmacSha256.init(secret);
        h.update(label);
        h.update(seed_a);
        h.update(seed_b);
        h.final(&a);
    }
    var pos: usize = 0;
    while (pos < out.len) {
        var block: [32]u8 = undefined;
        var h = HmacSha256.init(secret);
        h.update(&a);
        h.update(label);
        h.update(seed_a);
        h.update(seed_b);
        h.final(&block);
        const take = @min(32, out.len - pos);
        @memcpy(out[pos..][0..take], block[0..take]);
        pos += take;
        HmacSha256.create(&a, &a, secret);
    }
}

// ---------------------------------------------------------------------------
// Byte helpers.

const Reader = struct {
    b: []const u8,
    p: usize = 0,

    fn need(r: *Reader, n: usize) error{Decode}!void {
        if (r.p + n > r.b.len) return error.Decode;
    }
    fn int(r: *Reader, comptime T: type) error{Decode}!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        try r.need(n);
        const v = std.mem.readInt(T, r.b[r.p..][0..n], .big);
        r.p += n;
        return v;
    }
    fn bytes(r: *Reader, n: usize) error{Decode}![]const u8 {
        try r.need(n);
        defer r.p += n;
        return r.b[r.p .. r.p + n];
    }
    fn vec(r: *Reader, comptime L: type) error{Decode}![]const u8 {
        return r.bytes(try r.int(L));
    }
    fn left(r: *const Reader) usize {
        return r.b.len - r.p;
    }
};

const Writer = struct {
    b: []u8,
    n: usize = 0,

    fn int(w: *Writer, comptime T: type, v: T) void {
        const len = @divExact(@typeInfo(T).int.bits, 8);
        std.mem.writeInt(T, w.b[w.n..][0..len], v, .big);
        w.n += len;
    }
    fn raw(w: *Writer, s: []const u8) void {
        @memcpy(w.b[w.n..][0..s.len], s);
        w.n += s.len;
    }
    fn bytes(w: *const Writer) []u8 {
        return w.b[0..w.n];
    }
};

fn contains16(list: []const u8, v: u16) bool {
    var i: usize = 0;
    while (i + 2 <= list.len) : (i += 2) {
        if (std.mem.readInt(u16, list[i..][0..2], .big) == v) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The server.

pub const Sink = struct {
    ctx: *anyopaque,
    /// A datagram for the peer.
    send: *const fn (ctx: *anyopaque, datagram: []const u8) void,
    /// Decrypted application data (one record — one SCTP packet).
    data: *const fn (ctx: *anyopaque, plaintext: []u8) void,
};

pub const State = enum { wait_hello, wait_flight5, established, closed, failed };

const Slot = struct {
    active: bool = false,
    msg_type: u8 = 0,
    seq: u16 = 0,
    epoch: u16 = 0,
    len: usize = 0,
    have: usize = 0,
    buf: [max_message]u8 = undefined,
};

/// RFC 6347, section 4.1.2.6: the highest record sequence number accepted and the 63 before it.
const ReplayWindow = struct {
    top: u64 = 0,
    /// Bit i: record top - i was accepted. 0 — none yet.
    seen: u64 = 0,

    /// false — a repeat, or too old to tell.
    fn fresh(w: *const ReplayWindow, seq: u64) bool {
        if (w.seen == 0 or seq > w.top) return true;
        const back = w.top - seq;
        return back < 64 and (w.seen >> @intCast(back)) & 1 == 0;
    }

    /// Only for a record that proved genuine: a forged one must not move the window.
    fn accept(w: *ReplayWindow, seq: u64) void {
        if (w.seen == 0) {
            w.top = seq;
            w.seen = 1;
        } else if (seq > w.top) {
            const ahead = seq - w.top;
            w.seen = if (ahead >= 64) 1 else (w.seen << @intCast(ahead)) | 1;
            w.top = seq;
        } else if (w.top - seq < 64) {
            w.seen |= @as(u64, 1) << @intCast(w.top - seq);
        }
    }
};

pub const Server = struct {
    io: std.Io,
    identity: *const Identity,
    peer_fingerprint: [32]u8,
    state: State = .wait_hello,
    /// Why the handshake failed, for the log.
    reason: []const u8 = "",

    transcript: [max_transcript]u8 = undefined,
    transcript_len: usize = 0,
    next_recv_seq: u16 = 0,
    next_send_seq: u16 = 0,
    /// `init` clears the `active` flags; the buffers stay undefined.
    slots: [4]Slot = undefined,

    client_random: [32]u8 = undefined,
    server_random: [32]u8 = undefined,
    group: u16 = 0,
    x25519: X25519.KeyPair = undefined,
    p256_secret: [32]u8 = undefined,
    ems: bool = false,
    reneg: bool = false,
    point_formats: bool = false,
    peer_key: ?Ecdsa.PublicKey = null,
    got_cke: bool = false,
    got_verify: bool = false,
    master: [48]u8 = undefined,
    have_keys: bool = false,
    client_key: [16]u8 = undefined,
    server_key: [16]u8 = undefined,
    client_iv: [4]u8 = undefined,
    server_iv: [4]u8 = undefined,

    /// Record sequence numbers of epochs 0 and 1.
    out_seq: [2]u64 = .{ 0, 0 },
    /// The client's encrypted records accepted so far. Epoch 0 has no window: without a MAC a
    /// forged sequence number would move it, and its repeats are caught by the message sequence.
    in_window: ReplayWindow = .{},
    /// The last flight, for retransmission: handshake messages with their headers.
    flight: [2048]u8 = undefined,
    flight_len: usize = 0,
    /// Flight 6 is ChangeCipherSpec + an encrypted Finished.
    flight_final: bool = false,
    retransmit_at_us: u64 = 0,
    retransmit_us: u64 = 1_000_000,
    retransmits: u32 = 0,
    last_resend_us: u64 = 0,

    /// Sets up the server in place: with its buffers it is too large for a small thread stack.
    pub fn init(s: *Server, io: std.Io, identity: *const Identity, peer_fingerprint: [32]u8) void {
        s.* = .{ .io = io, .identity = identity, .peer_fingerprint = peer_fingerprint };
        for (&s.slots) |*slot| slot.active = false;
    }

    pub fn established(s: *const Server) bool {
        return s.state == .established;
    }

    /// Processes every record in a datagram from the peer (decrypted in place).
    pub fn handle(s: *Server, datagram: []u8, now_us: u64, sink: Sink) void {
        var pos: usize = 0;
        while (pos + header_len <= datagram.len) {
            const header = datagram[pos..][0..header_len];
            const ct = header[0];
            const epoch = std.mem.readInt(u16, header[3..5], .big);
            const len = std.mem.readInt(u16, header[11..13], .big);
            if (pos + header_len + len > datagram.len) return;
            const body = datagram[pos + header_len ..][0..len];
            pos += header_len + len;
            if (s.state == .closed or s.state == .failed) return;
            if (epoch == 0) {
                // Once the keys are in use, a plaintext record can only come from a stranger.
                if (s.state == .established) continue;
                switch (ct) {
                    content_handshake => s.onHandshakeRecord(body, 0, now_us, sink),
                    // Unauthenticated alerts count only during the handshake.
                    content_alert => if (s.state != .established) s.onAlert(body),
                    else => {},
                }
            } else if (epoch == 1 and s.have_keys) {
                const seq = std.mem.readInt(u48, header[5..11], .big);
                if (!s.in_window.fresh(seq)) continue; // a replay, or too old: not worth decrypting
                const plain = s.open(header, body) orelse continue; // forged or damaged: drop silently
                s.in_window.accept(seq);
                switch (ct) {
                    content_handshake => s.onHandshakeRecord(plain, 1, now_us, sink),
                    content_app => if (s.state == .established) sink.data(sink.ctx, plain),
                    content_alert => s.onAlert(plain),
                    else => {},
                }
            }
        }
    }

    /// Retransmits flight 4 when the client's answer is late.
    pub fn tick(s: *Server, now_us: u64, sink: Sink) void {
        if (s.state != .wait_flight5 or now_us < s.retransmit_at_us) return;
        if (s.retransmits >= max_retransmits) return s.fail("the browser stopped answering during the handshake", null, sink);
        s.retransmits += 1;
        s.retransmit_us = @min(s.retransmit_us * 2, 8_000_000);
        s.retransmit_at_us = now_us + s.retransmit_us;
        s.transmitFlight(sink);
    }

    /// Sends application data (one SCTP packet) in one record.
    pub fn sendData(s: *Server, plaintext: []const u8, sink: Sink) void {
        if (s.state != .established) return;
        var buf: [mtu + 64]u8 = undefined;
        std.debug.assert(plaintext.len + overhead <= buf.len);
        sink.send(sink.ctx, s.seal(&buf, content_app, 1, plaintext));
    }

    pub fn close(s: *Server, sink: Sink) void {
        if (s.state == .established) {
            var buf: [64]u8 = undefined;
            sink.send(sink.ctx, s.seal(&buf, content_alert, 1, &.{ 1, alert_close_notify }));
        }
        if (s.state != .failed) s.state = .closed;
    }

    fn fail(s: *Server, reason: []const u8, alert: ?u8, sink: Sink) void {
        if (s.state == .failed or s.state == .closed) return;
        s.reason = reason;
        if (alert) |a| {
            var buf: [64]u8 = undefined;
            sink.send(sink.ctx, s.seal(&buf, content_alert, 0, &.{ 2, a }));
        }
        s.state = .failed;
    }

    fn onAlert(s: *Server, body: []const u8) void {
        if (body.len < 2) return;
        if (body[1] == alert_close_notify) {
            s.state = .closed;
        } else if (body[0] == 2) {
            s.reason = "the browser sent a fatal alert";
            s.state = .failed;
        }
    }

    // --- records

    fn seal(s: *Server, out: []u8, ct: u8, epoch: u16, plain: []const u8) []u8 {
        const seq = s.out_seq[epoch];
        s.out_seq[epoch] += 1;
        out[0] = ct;
        std.mem.writeInt(u16, out[1..3], version, .big);
        std.mem.writeInt(u16, out[3..5], epoch, .big);
        std.mem.writeInt(u48, out[5..11], @intCast(seq), .big);
        if (epoch == 0) {
            std.mem.writeInt(u16, out[11..13], @intCast(plain.len), .big);
            @memcpy(out[header_len..][0..plain.len], plain);
            return out[0 .. header_len + plain.len];
        }
        std.mem.writeInt(u16, out[11..13], @intCast(8 + plain.len + 16), .big);
        const explicit = out[header_len..][0..8];
        @memcpy(explicit, out[3..11]); // epoch + sequence number: unique per key
        var nonce: [12]u8 = undefined;
        @memcpy(nonce[0..4], &s.server_iv);
        @memcpy(nonce[4..12], explicit);
        var aad: [13]u8 = undefined;
        @memcpy(aad[0..8], out[3..11]);
        aad[8] = ct;
        std.mem.writeInt(u16, aad[9..11], version, .big);
        std.mem.writeInt(u16, aad[11..13], @intCast(plain.len), .big);
        const c = out[header_len + 8 ..][0..plain.len];
        var tag: [16]u8 = undefined;
        Aes128Gcm.encrypt(c, &tag, plain, &aad, nonce, s.server_key);
        @memcpy(out[header_len + 8 + plain.len ..][0..16], &tag);
        return out[0 .. header_len + 8 + plain.len + 16];
    }

    fn open(s: *Server, header: *const [header_len]u8, body: []u8) ?[]u8 {
        if (body.len < 8 + 16) return null;
        const plain_len = body.len - 24;
        var nonce: [12]u8 = undefined;
        @memcpy(nonce[0..4], &s.client_iv);
        @memcpy(nonce[4..12], body[0..8]);
        var aad: [13]u8 = undefined;
        @memcpy(aad[0..8], header[3..11]);
        aad[8] = header[0];
        @memcpy(aad[9..11], header[1..3]);
        std.mem.writeInt(u16, aad[11..13], @intCast(plain_len), .big);
        const c = body[8..][0..plain_len];
        const tag = body[8 + plain_len ..][0..16].*;
        Aes128Gcm.decrypt(c, c, tag, &aad, nonce, s.client_key) catch return null;
        return c;
    }

    // --- handshake messages

    fn onHandshakeRecord(s: *Server, body: []const u8, epoch: u16, now_us: u64, sink: Sink) void {
        var p: usize = 0;
        while (p + hs_header_len <= body.len) {
            const mt = body[p];
            const total = std.mem.readInt(u24, body[p + 1 ..][0..3], .big);
            const mseq = std.mem.readInt(u16, body[p + 4 ..][0..2], .big);
            const off = std.mem.readInt(u24, body[p + 6 ..][0..3], .big);
            const flen = std.mem.readInt(u24, body[p + 9 ..][0..3], .big);
            const end: usize = @as(usize, off) + flen; // not u24: 0xFFFFFF + 1 would wrap
            if (p + hs_header_len + flen > body.len or end > total) return;
            const frag = body[p + hs_header_len ..][0..flen];
            p += hs_header_len + flen;
            if (mseq < s.next_recv_seq) {
                // The peer repeats a message we already have: our last flight was lost.
                s.resendFlight(now_us, sink);
                continue;
            }
            if (mseq >= s.next_recv_seq + s.slots.len) continue;
            if (total > max_message) return s.fail("a handshake message is too large", alert_handshake_failure, sink);
            const slot = &s.slots[mseq % s.slots.len];
            if (!slot.active or slot.seq != mseq) slot.* = .{ .active = true, .msg_type = mt, .seq = mseq, .epoch = epoch, .len = total };
            if (slot.msg_type != mt or slot.len != total or slot.epoch != epoch) continue;
            // In-order fragments only; a gap is filled by the peer's retransmission.
            if (off <= slot.have and end > slot.have) {
                @memcpy(slot.buf[off..][0..flen], frag);
                slot.have = @intCast(end);
            }
        }
        while (true) {
            const slot = &s.slots[s.next_recv_seq % s.slots.len];
            if (!slot.active or slot.seq != s.next_recv_seq or slot.have < slot.len) break;
            slot.active = false;
            s.next_recv_seq +%= 1;
            s.onMessage(slot.msg_type, slot.epoch, slot.buf[0..slot.len], now_us, sink) catch |e| {
                return s.fail(switch (e) {
                    error.Decode => "a handshake message is malformed",
                    error.Unsupported => "the browser offers no cipher suite or curve RDC speaks",
                    error.Certificate => "the browser's certificate does not match its offer",
                    error.Verify => "the browser's signature or Finished message is wrong",
                    error.Unexpected => "a handshake message came out of order",
                    error.Version => "the browser does not speak DTLS 1.2",
                }, switch (e) {
                    error.Certificate => alert_bad_certificate,
                    error.Verify => alert_decrypt_error,
                    error.Version => alert_protocol_version,
                    else => alert_handshake_failure,
                }, sink);
            };
            if (s.state == .failed) return;
        }
    }

    const MsgError = error{ Decode, Unsupported, Certificate, Verify, Unexpected, Version };

    fn onMessage(s: *Server, mt: u8, epoch: u16, body: []const u8, now_us: u64, sink: Sink) MsgError!void {
        switch (s.state) {
            .wait_hello => {
                if (mt != hs_client_hello or epoch != 0) return error.Unexpected;
                try s.onClientHello(body);
                try s.appendTranscript(mt, s.next_recv_seq - 1, body);
                s.sendFlight4(now_us, sink);
            },
            .wait_flight5 => switch (mt) {
                hs_certificate => {
                    if (epoch != 0 or s.peer_key != null) return error.Unexpected;
                    try s.onCertificate(body);
                    try s.appendTranscript(mt, s.next_recv_seq - 1, body);
                },
                hs_client_key_exchange => {
                    if (epoch != 0 or s.peer_key == null or s.got_cke) return error.Unexpected;
                    try s.appendTranscript(mt, s.next_recv_seq - 1, body);
                    try s.onClientKeyExchange(body);
                },
                hs_certificate_verify => {
                    if (epoch != 0 or !s.got_cke or s.got_verify) return error.Unexpected;
                    try s.onCertificateVerify(body);
                    try s.appendTranscript(mt, s.next_recv_seq - 1, body);
                },
                hs_finished => {
                    if (epoch != 1 or !s.got_verify) return error.Unexpected;
                    var hash: [32]u8 = undefined;
                    Sha256.hash(s.transcript[0..s.transcript_len], &hash, .{});
                    var want: [12]u8 = undefined;
                    prf(&want, &s.master, "client finished", &hash, "");
                    if (body.len != 12 or !crypto.timing_safe.eql([12]u8, want, body[0..12].*)) return error.Verify;
                    try s.appendTranscript(mt, s.next_recv_seq - 1, body);
                    s.sendFlight6(sink);
                    s.state = .established;
                },
                else => return error.Unexpected,
            },
            .established, .closed, .failed => {},
        }
    }

    fn onClientHello(s: *Server, body: []const u8) MsgError!void {
        var r: Reader = .{ .b = body };
        const client_version = try r.int(u16);
        if (client_version > version) return error.Version; // DTLS versions count down: 0xfeff is 1.0
        @memcpy(&s.client_random, try r.bytes(32));
        _ = try r.vec(u8); // session id: no resumption
        _ = try r.vec(u8); // cookie: none is ever asked
        const suites = try r.vec(u16);
        _ = try r.vec(u8); // compression methods
        if (!contains16(suites, suite_ecdhe_ecdsa_aes128_gcm_sha256)) return error.Unsupported;
        s.reneg = contains16(suites, suite_renegotiation_scsv);
        var groups: []const u8 = &.{};
        var sig_algs: ?[]const u8 = null;
        if (r.left() >= 2) {
            var ext: Reader = .{ .b = try r.vec(u16) };
            while (ext.left() >= 4) {
                const t = try ext.int(u16);
                const v = try ext.vec(u16);
                switch (t) {
                    ext_supported_groups => {
                        var g: Reader = .{ .b = v };
                        groups = try g.vec(u16);
                    },
                    ext_signature_algorithms => {
                        var g: Reader = .{ .b = v };
                        sig_algs = try g.vec(u16);
                    },
                    ext_extended_master_secret => s.ems = true,
                    ext_renegotiation_info => s.reneg = true,
                    ext_ec_point_formats => s.point_formats = true,
                    else => {},
                }
            }
        }
        if (sig_algs) |algs| if (!contains16(algs, sig_ecdsa_p256_sha256)) return error.Unsupported;
        if (contains16(groups, group_x25519)) {
            s.group = group_x25519;
            s.x25519 = X25519.KeyPair.generate(s.io);
        } else if (contains16(groups, group_p256)) {
            s.group = group_p256;
            s.io.random(&s.p256_secret);
        } else return error.Unsupported;
    }

    fn onCertificate(s: *Server, body: []const u8) MsgError!void {
        var r: Reader = .{ .b = body };
        var list: Reader = .{ .b = try r.bytes(try r.int(u24)) };
        const der = try list.bytes(try list.int(u24));
        var digest: [32]u8 = undefined;
        Sha256.hash(der, &digest, .{});
        if (!crypto.timing_safe.eql([32]u8, digest, s.peer_fingerprint)) return error.Certificate;
        const key = try certP256Key(der);
        s.peer_key = Ecdsa.PublicKey.fromSec1(key) catch return error.Certificate;
    }

    fn onClientKeyExchange(s: *Server, body: []const u8) MsgError!void {
        var r: Reader = .{ .b = body };
        const point = try r.vec(u8);
        var pms: [32]u8 = undefined;
        if (s.group == group_x25519) {
            if (point.len != 32) return error.Decode;
            pms = X25519.scalarmult(s.x25519.secret_key, point[0..32].*) catch return error.Verify;
        } else {
            const peer = P256.fromSec1(point) catch return error.Decode;
            const shared = peer.mul(s.p256_secret, .big) catch return error.Verify;
            pms = shared.affineCoordinates().x.toBytes(.big);
        }
        if (s.ems) {
            var session_hash: [32]u8 = undefined;
            Sha256.hash(s.transcript[0..s.transcript_len], &session_hash, .{});
            prf(&s.master, &pms, "extended master secret", &session_hash, "");
        } else {
            prf(&s.master, &pms, "master secret", &s.client_random, &s.server_random);
        }
        crypto.secureZero(u8, &pms);
        var kb: [40]u8 = undefined;
        prf(&kb, &s.master, "key expansion", &s.server_random, &s.client_random);
        @memcpy(&s.client_key, kb[0..16]);
        @memcpy(&s.server_key, kb[16..32]);
        @memcpy(&s.client_iv, kb[32..36]);
        @memcpy(&s.server_iv, kb[36..40]);
        crypto.secureZero(u8, &kb);
        s.have_keys = true;
        s.got_cke = true;
    }

    fn onCertificateVerify(s: *Server, body: []const u8) MsgError!void {
        var r: Reader = .{ .b = body };
        if (try r.int(u16) != sig_ecdsa_p256_sha256) return error.Unsupported;
        const der = try r.vec(u16);
        const sig = Ecdsa.Signature.fromDer(der) catch return error.Verify;
        sig.verify(s.transcript[0..s.transcript_len], s.peer_key.?) catch return error.Verify;
        s.got_verify = true;
    }

    // --- our flights

    /// error.Decode when it does not fit; with messages of at most max_message it always does.
    fn appendTranscript(s: *Server, mt: u8, seq: u16, body: []const u8) error{Decode}!void {
        if (s.transcript_len + hs_header_len + body.len > s.transcript.len) return error.Decode;
        writeHsHeader(s.transcript[s.transcript_len..][0..hs_header_len], mt, seq, body.len);
        @memcpy(s.transcript[s.transcript_len + hs_header_len ..][0..body.len], body);
        s.transcript_len += hs_header_len + body.len;
    }

    fn addFlightMessage(s: *Server, mt: u8, body: []const u8) void {
        const seq = s.next_send_seq;
        s.next_send_seq += 1;
        std.debug.assert(s.flight_len + hs_header_len + body.len <= s.flight.len);
        writeHsHeader(s.flight[s.flight_len..][0..hs_header_len], mt, seq, body.len);
        @memcpy(s.flight[s.flight_len + hs_header_len ..][0..body.len], body);
        s.flight_len += hs_header_len + body.len;
        // Our messages come after at most four client messages of max_message: they always fit.
        s.appendTranscript(mt, seq, body) catch unreachable;
    }

    fn sendFlight4(s: *Server, now_us: u64, sink: Sink) void {
        s.flight_len = 0;
        s.flight_final = false;
        s.io.random(&s.server_random);

        var buf: [1024]u8 = undefined;
        var w: Writer = .{ .b = &buf };
        w.int(u16, version);
        w.raw(&s.server_random);
        w.int(u8, 0); // empty session id
        w.int(u16, suite_ecdhe_ecdsa_aes128_gcm_sha256);
        w.int(u8, 0); // no compression
        var ext: [32]u8 = undefined;
        var e: Writer = .{ .b = &ext };
        if (s.reneg) {
            e.int(u16, ext_renegotiation_info);
            e.int(u16, 1);
            e.int(u8, 0);
        }
        if (s.ems) {
            e.int(u16, ext_extended_master_secret);
            e.int(u16, 0);
        }
        if (s.point_formats) {
            e.int(u16, ext_ec_point_formats);
            e.int(u16, 2);
            e.int(u8, 1);
            e.int(u8, 0); // uncompressed
        }
        if (e.n > 0) {
            w.int(u16, @intCast(e.n));
            w.raw(e.bytes());
        }
        s.addFlightMessage(hs_server_hello, w.bytes());

        const cert = s.identity.cert();
        w = .{ .b = &buf };
        w.int(u24, @intCast(cert.len + 3));
        w.int(u24, @intCast(cert.len));
        w.raw(cert);
        s.addFlightMessage(hs_certificate, w.bytes());

        // ServerKeyExchange: the ECDHE share, signed together with both randoms.
        var params: [70]u8 = undefined;
        var pw: Writer = .{ .b = &params };
        pw.int(u8, 3); // named_curve
        pw.int(u16, s.group);
        if (s.group == group_x25519) {
            pw.int(u8, 32);
            pw.raw(&s.x25519.public_key);
        } else {
            const public = (P256.basePoint.mul(s.p256_secret, .big) catch unreachable).toUncompressedSec1();
            pw.int(u8, 65);
            pw.raw(&public);
        }
        var signed: [134]u8 = undefined;
        @memcpy(signed[0..32], &s.client_random);
        @memcpy(signed[32..64], &s.server_random);
        @memcpy(signed[64..][0..pw.n], pw.bytes());
        var noise: [Ecdsa.noise_length]u8 = undefined;
        s.io.random(&noise);
        const sig = s.identity.key.sign(signed[0 .. 64 + pw.n], noise) catch unreachable;
        var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const der = sig.toDer(&der_buf);
        w = .{ .b = &buf };
        w.raw(pw.bytes());
        w.int(u16, sig_ecdsa_p256_sha256);
        w.int(u16, @intCast(der.len));
        w.raw(der);
        s.addFlightMessage(hs_server_key_exchange, w.bytes());

        // CertificateRequest: WebRTC authenticates both sides.
        w = .{ .b = &buf };
        w.int(u8, 1);
        w.int(u8, 64); // ecdsa_sign
        w.int(u16, 2);
        w.int(u16, sig_ecdsa_p256_sha256);
        w.int(u16, 0); // no certificate authorities
        s.addFlightMessage(hs_certificate_request, w.bytes());
        s.addFlightMessage(hs_server_hello_done, "");

        s.state = .wait_flight5;
        s.retransmits = 0;
        s.retransmit_us = 1_000_000;
        s.retransmit_at_us = now_us + s.retransmit_us;
        s.transmitFlight(sink);
    }

    fn sendFlight6(s: *Server, sink: Sink) void {
        var hash: [32]u8 = undefined;
        Sha256.hash(s.transcript[0..s.transcript_len], &hash, .{});
        var verify: [12]u8 = undefined;
        prf(&verify, &s.master, "server finished", &hash, "");
        s.flight_len = 0;
        s.flight_final = true;
        s.addFlightMessage(hs_finished, &verify);
        s.transmitFlight(sink);
    }

    /// Answers a repeated message from the peer at most every 100 ms.
    fn resendFlight(s: *Server, now_us: u64, sink: Sink) void {
        if (s.flight_len == 0 or now_us -| s.last_resend_us < 100_000) return;
        s.last_resend_us = now_us;
        s.transmitFlight(sink);
    }

    /// One handshake message per record, records packed into datagrams of at most `mtu` bytes.
    fn transmitFlight(s: *Server, sink: Sink) void {
        var dgram: [mtu + 64]u8 = undefined;
        var n: usize = 0;
        if (s.flight_final) n += s.seal(dgram[n..], content_ccs, 0, &.{1}).len;
        var p: usize = 0;
        while (p < s.flight_len) {
            const len = std.mem.readInt(u24, s.flight[p + 1 ..][0..3], .big);
            const msg = s.flight[p..][0 .. hs_header_len + len];
            p += msg.len;
            const epoch: u16 = if (s.flight_final) 1 else 0;
            const need = msg.len + @as(usize, if (epoch == 1) overhead else header_len);
            std.debug.assert(need <= mtu);
            if (n + need > mtu) {
                sink.send(sink.ctx, dgram[0..n]);
                n = 0;
            }
            n += s.seal(dgram[n..], content_handshake, epoch, msg).len;
        }
        if (n > 0) sink.send(sink.ctx, dgram[0..n]);
    }
};

fn writeHsHeader(out: *[hs_header_len]u8, mt: u8, seq: u16, len: usize) void {
    out[0] = mt;
    std.mem.writeInt(u24, out[1..4], @intCast(len), .big);
    std.mem.writeInt(u16, out[4..6], seq, .big);
    std.mem.writeInt(u24, out[6..9], 0, .big);
    std.mem.writeInt(u24, out[9..12], @intCast(len), .big);
}

// ---------------------------------------------------------------------------

test "dtls: TLS 1.2 PRF (SHA-256) test vector" {
    var secret: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "9bbe436ba940f017b17652849a71db35");
    var seed: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, "a0ba9f936cda311827a6f796ffd5198c");
    var want: [100]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a" ++
        "6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab" ++
        "4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff701" ++
        "87347b66");
    var out: [100]u8 = undefined;
    prf(&out, &secret, "test label", &seed, "");
    try std.testing.expectEqualSlices(u8, &want, &out);
    // The seed may come in two parts.
    prf(&out, &secret, "test label", seed[0..5], seed[5..]);
    try std.testing.expectEqualSlices(u8, &want, &out);
}

test "dtls: self-signed certificate parses and verifies" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const id = try Identity.generate(threaded.io());
    const parsed = try (crypto.Certificate{ .buffer = id.cert(), .index = 0 }).parse();
    try std.testing.expectEqual(crypto.Certificate.Parsed.PubKeyAlgo{ .X9_62_id_ecPublicKey = .X9_62_prime256v1 }, parsed.pub_key_algo);
    try std.testing.expectEqualStrings("RDC", parsed.commonName());
    try std.testing.expectEqualSlices(u8, &id.key.public_key.toUncompressedSec1(), parsed.pubKey());
    // Self-signed: the certificate verifies against itself.
    try (crypto.Certificate{ .buffer = id.cert(), .index = 0 }).verify(.{ .buffer = id.cert(), .index = 0 }, 1_800_000_000);
    var digest: [32]u8 = undefined;
    Sha256.hash(id.cert(), &digest, .{});
    try std.testing.expectEqual(digest, id.fingerprint);
}

const TestSink = struct {
    sent: [8][mtu + 64]u8 = undefined,
    sent_len: [8]usize = @splat(0),
    count: usize = 0,

    fn send(ctx: *anyopaque, d: []const u8) void {
        const t: *TestSink = @ptrCast(@alignCast(ctx));
        @memcpy(t.sent[t.count][0..d.len], d);
        t.sent_len[t.count] = d.len;
        t.count += 1;
    }
    fn data(ctx: *anyopaque, p: []u8) void {
        _ = ctx;
        _ = p;
    }
    fn sink(t: *TestSink) Sink {
        return .{ .ctx = t, .send = send, .data = data };
    }
};

test "dtls: a ClientHello gets flight 4" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const id = try Identity.generate(io);
    const s = try std.testing.allocator.create(Server);
    defer std.testing.allocator.destroy(s);
    s.init(io, &id, @splat(0));
    // A minimal ClientHello: DTLS 1.2, one suite, X25519, EMS.
    var body: [128]u8 = undefined;
    var w: Writer = .{ .b = &body };
    w.int(u16, version);
    w.raw(&@as([32]u8, @splat(7)));
    w.int(u8, 0);
    w.int(u8, 0);
    w.int(u16, 4);
    w.int(u16, suite_ecdhe_ecdsa_aes128_gcm_sha256);
    w.int(u16, suite_renegotiation_scsv);
    w.int(u8, 1);
    w.int(u8, 0);
    w.int(u16, 4 + 4 + 4);
    w.int(u16, ext_supported_groups);
    w.int(u16, 4);
    w.int(u16, 2);
    w.int(u16, group_x25519);
    w.int(u16, ext_extended_master_secret);
    w.int(u16, 0);
    var dgram: [256]u8 = undefined;
    dgram[0] = content_handshake;
    std.mem.writeInt(u16, dgram[1..3], 0xfeff, .big);
    @memset(dgram[3..11], 0);
    std.mem.writeInt(u16, dgram[11..13], @intCast(hs_header_len + w.n), .big);
    writeHsHeader(dgram[13..25], hs_client_hello, 0, w.n);
    @memcpy(dgram[25..][0..w.n], w.bytes());
    var ts: TestSink = .{};
    s.handle(dgram[0 .. 25 + w.n], 0, ts.sink());
    try std.testing.expectEqual(State.wait_flight5, s.state);
    try std.testing.expectEqual(@as(usize, 1), ts.count);
    try std.testing.expect(s.ems and s.reneg);
    try std.testing.expectEqual(group_x25519, s.group);
    // Five records: ServerHello, Certificate, ServerKeyExchange, CertificateRequest, ServerHelloDone.
    var records: usize = 0;
    var p: usize = 0;
    const out = ts.sent[0][0..ts.sent_len[0]];
    while (p + header_len <= out.len) : (records += 1) {
        try std.testing.expectEqual(content_handshake, out[p]);
        try std.testing.expectEqual(@as(u8, @intCast(records)), out[p + header_len + 5]); // message_seq
        p += header_len + std.mem.readInt(u16, out[p + 11 ..][0..2], .big);
    }
    try std.testing.expectEqual(@as(usize, 5), records);
    try std.testing.expectEqual(out.len, p);
    // No answer → the same flight again after a second, with new record numbers.
    s.tick(500_000, ts.sink());
    try std.testing.expectEqual(@as(usize, 1), ts.count);
    s.tick(1_000_000, ts.sink());
    try std.testing.expectEqual(@as(usize, 2), ts.count);
    try std.testing.expectEqual(ts.sent_len[0], ts.sent_len[1]);
}

test "dtls: records round trip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const id = try Identity.generate(io);
    const a = try std.testing.allocator.create(Server);
    defer std.testing.allocator.destroy(a);
    a.init(io, &id, @splat(0));
    a.state = .established;
    a.have_keys = true;
    a.server_key = @splat(1);
    a.server_iv = @splat(2);
    // A second server that reads with the first one's write keys stands in for the client.
    const b = try std.testing.allocator.create(Server);
    defer std.testing.allocator.destroy(b);
    b.init(io, &id, @splat(0));
    b.state = .established;
    b.have_keys = true;
    b.client_key = @splat(1);
    b.client_iv = @splat(2);
    const Got = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        fn data(ctx: *anyopaque, p: []u8) void {
            _ = ctx;
            @memcpy(buf[0..p.len], p);
            len = p.len;
        }
    };
    var ts: TestSink = .{};
    a.sendData("SCTP packet", ts.sink());
    var rx: [mtu]u8 = undefined;
    @memcpy(rx[0..ts.sent_len[0]], ts.sent[0][0..ts.sent_len[0]]);
    b.handle(rx[0..ts.sent_len[0]], 0, .{ .ctx = &ts, .send = TestSink.send, .data = Got.data });
    try std.testing.expectEqualStrings("SCTP packet", Got.buf[0..Got.len]);
    // A flipped bit is dropped silently (in a new record: the first one again would be a replay).
    Got.len = 0;
    a.sendData("SCTP packet", ts.sink());
    @memcpy(rx[0..ts.sent_len[1]], ts.sent[1][0..ts.sent_len[1]]);
    rx[header_len + 9] ^= 1;
    b.handle(rx[0..ts.sent_len[1]], 0, .{ .ctx = &ts, .send = TestSink.send, .data = Got.data });
    try std.testing.expectEqual(@as(usize, 0), Got.len);
    // Undamaged, that record still gets through: the forged copy did not count as seen.
    @memcpy(rx[0..ts.sent_len[1]], ts.sent[1][0..ts.sent_len[1]]);
    b.handle(rx[0..ts.sent_len[1]], 0, .{ .ctx = &ts, .send = TestSink.send, .data = Got.data });
    try std.testing.expectEqualStrings("SCTP packet", Got.buf[0..Got.len]);
    try std.testing.expectEqual(State.established, b.state);
}

test "dtls: replayed and too old records are dropped" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const id = try Identity.generate(io);
    const a = try std.testing.allocator.create(Server);
    defer std.testing.allocator.destroy(a);
    a.init(io, &id, @splat(0));
    a.state = .established;
    a.have_keys = true;
    a.server_key = @splat(1);
    a.server_iv = @splat(2);
    const b = try std.testing.allocator.create(Server);
    defer std.testing.allocator.destroy(b);
    b.init(io, &id, @splat(0));
    b.state = .established;
    b.have_keys = true;
    b.client_key = @splat(1);
    b.client_iv = @splat(2);
    // Records 0…71 from a, each with one byte of data, delivered to b in any order.
    const rec_len = overhead + 1;
    const Records = struct {
        var d: [72][rec_len]u8 = undefined;
        var n: usize = 0;
        var got: usize = 0;
        fn send(ctx: *anyopaque, rec: []const u8) void {
            _ = ctx;
            @memcpy(&d[n], rec);
            n += 1;
        }
        fn data(ctx: *anyopaque, p: []u8) void {
            _ = ctx;
            _ = p;
            got += 1;
        }
        fn sink() Sink {
            return .{ .ctx = &n, .send = send, .data = data };
        }
        fn deliver(s: *Server, i: usize, forged: bool) usize {
            var rx = d[i];
            if (forged) rx[rec_len - 1] ^= 1;
            s.handle(&rx, 0, sink());
            return got;
        }
    };
    for (0..72) |_| a.sendData("x", Records.sink());
    try std.testing.expectEqual(@as(usize, 72), Records.n);
    const expectGot = std.testing.expectEqual;
    try expectGot(@as(usize, 1), Records.deliver(b, 69, false));
    try expectGot(@as(usize, 1), Records.deliver(b, 69, false)); // a repeat
    try expectGot(@as(usize, 1), Records.deliver(b, 71, true)); // forged: the window stays at 69
    try expectGot(@as(usize, 2), Records.deliver(b, 6, false)); // 63 behind: still in the window
    try expectGot(@as(usize, 2), Records.deliver(b, 5, false)); // 64 behind: too old
    try expectGot(@as(usize, 2), Records.deliver(b, 6, false)); // a repeat
    try expectGot(@as(usize, 3), Records.deliver(b, 71, false));
    try expectGot(@as(usize, 4), Records.deliver(b, 8, false)); // 63 behind 71
    try expectGot(@as(usize, 4), Records.deliver(b, 7, false)); // 64 behind 71
    try expectGot(@as(usize, 5), Records.deliver(b, 70, false)); // in the window, not seen yet
    try std.testing.expectEqual(State.established, b.state);
}

test "dtls: the browser's key is read only from a well-formed certificate" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const id = try Identity.generate(threaded.io());
    // Our own certificate, and one from OpenSSL 3 (v3, with extensions): the same key std finds.
    try std.testing.expectEqualSlices(u8, &id.key.public_key.toUncompressedSec1(), try certP256Key(id.cert()));
    var der: [378]u8 = undefined;
    _ = try std.fmt.hexToBytes(&der, "308201763082011da00302010202146f2e33a6f58a49dc2b317e3ca753d305633cf6b1300a06082a8648ce3d04030230" ++
        "11310f300d06035504030c06576562525443301e170d3236313130393130323831315a170d3236313230393130323831" ++
        "315a3011310f300d06035504030c065765625254433059301306072a8648ce3d020106082a8648ce3d03010703420004" ++
        "948ff167af10a44113de7aa8b6ad7838189572db7252dc0166ccfa418e07e466cbc35804a5683fb6ff699ee5ed5a41a0" ++
        "be0fabceed7d138f90da427efbece0d9a3533051301d0603551d0e0416041487075175992ef3ab58ecd47707025a0f06" ++
        "57e20b301f0603551d2304183016801487075175992ef3ab58ecd47707025a0f0657e20b300f0603551d130101ff0405" ++
        "30030101ff300a06082a8648ce3d04030203470030440220179c6bcdb8759d001c0e5b7e4fe787c52801f18e903d7dc7" ++
        "7ae141c840a551bc022043bc63529bd50864b8e6b7e9f43318ebfc4c1096a28d9892a87a6b10f778cb6b");
    const parsed = try (crypto.Certificate{ .buffer = &der, .index = 0 }).parse();
    try std.testing.expectEqualSlices(u8, parsed.pubKey(), try certP256Key(&der));

    // A length past the end (it overflowed std's parser), DER that is well-formed but no
    // certificate (std reads past its end), an indefinite length, a five-byte length, a child
    // longer than its parent, a multi-byte tag.
    const bad = [_][]const u8{
        &.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff, 0x30, 0x03 },
        &.{ 0x30, 0x00 },
        &.{ 0x30, 0x03, 0x03, 0x01, 0x00 },
        &.{ 0x30, 0x80, 0x00, 0x00 },
        &.{ 0x30, 0x85, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 },
        &.{ 0x30, 0x02, 0x30, 0x05 },
        &.{ 0x3f, 0x01, 0x00 },
    };
    for (bad) |b| try std.testing.expectError(error.Decode, certP256Key(b));
    // A trailing byte.
    var long: [512]u8 = undefined;
    @memcpy(long[0..id.cert().len], id.cert());
    long[id.cert().len] = 0;
    try std.testing.expectError(error.Decode, certP256Key(long[0 .. id.cert().len + 1]));
    // Damage inside a field the key reader skips: the second time runs past its SEQUENCE.
    var damaged: [512]u8 = undefined;
    @memcpy(damaged[0..id.cert().len], id.cert());
    const not_after = std.mem.find(u8, damaged[0..id.cert().len], "\x17\x0d491231").?;
    damaged[not_after + 1] = 0x0e;
    try std.testing.expectError(error.Decode, certP256Key(damaged[0..id.cert().len]));
    // Twenty SEQUENCEs one inside another.
    var deep: [40]u8 = undefined;
    for (0..20) |i| {
        deep[2 * i] = der_sequence;
        deep[2 * i + 1] = @intCast(38 - 2 * i);
    }
    try std.testing.expectError(error.Decode, certP256Key(&deep));

    // The smallest certificate shape (v1, no version field): a key in the BIT STRING is found,
    // an empty BIT STRING is refused (std's parser would slice it backwards).
    const Shape = struct {
        fn cert(out: *[160]u8, key_bits: []const u8) []u8 {
            var spki_body: [96]u8 = undefined;
            const alg = spki_prefix[2..23];
            @memcpy(spki_body[0..alg.len], alg);
            @memcpy(spki_body[alg.len..][0..key_bits.len], key_bits);
            var spki_buf: [100]u8 = undefined;
            const spki = derWrap(&spki_buf, der_sequence, spki_body[0 .. alg.len + key_bits.len]);
            const fields = [_]u8{ 0x02, 0x01, 0x01, 0x30, 0x00, 0x30, 0x00, 0x30, 0x00, 0x30, 0x00 };
            var tbs_body: [120]u8 = undefined;
            @memcpy(tbs_body[0..fields.len], &fields);
            @memcpy(tbs_body[fields.len..][0..spki.len], spki);
            var tbs_buf: [128]u8 = undefined;
            const tbs = derWrap(&tbs_buf, der_sequence, tbs_body[0 .. fields.len + spki.len]);
            return derWrap(out, der_sequence, tbs);
        }
    };
    var shaped: [160]u8 = undefined;
    var bits: [3 + 65]u8 = undefined;
    bits[0] = 0x03;
    bits[1] = 0x42;
    bits[2] = 0;
    @memcpy(bits[3..], &id.key.public_key.toUncompressedSec1());
    try std.testing.expectEqualSlices(u8, bits[3..], try certP256Key(Shape.cert(&shaped, &bits)));
    try std.testing.expectError(error.Decode, certP256Key(Shape.cert(&shaped, &.{ 0x03, 0x00 })));

    // Another curve where prime256v1 should be: refused, not misread.
    var other: [512]u8 = undefined;
    @memcpy(other[0..id.cert().len], id.cert());
    const curve = std.mem.find(u8, other[0..id.cert().len], spki_prefix[13..23]).?;
    other[curve + 9] = 0x22;
    try std.testing.expectError(error.Unsupported, certP256Key(other[0..id.cert().len]));
}

test "dtls: a malformed browser certificate fails the handshake" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const id = try Identity.generate(io);
    const s = try std.testing.allocator.create(Server);
    defer std.testing.allocator.destroy(s);
    // The fingerprint in the offer matches: only the DER is wrong.
    const der = [_]u8{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff, 0x30, 0x03 };
    var fp: [32]u8 = undefined;
    Sha256.hash(&der, &fp, .{});
    s.init(io, &id, fp);
    s.state = .wait_flight5; // as after the ClientHello
    s.next_recv_seq = 1;
    const body_len = 6 + der.len;
    var dgram: [header_len + hs_header_len + body_len]u8 = undefined;
    dgram[0] = content_handshake;
    std.mem.writeInt(u16, dgram[1..3], version, .big);
    @memset(dgram[3..11], 0);
    std.mem.writeInt(u16, dgram[11..13], hs_header_len + body_len, .big);
    writeHsHeader(dgram[13..25], hs_certificate, 1, body_len);
    std.mem.writeInt(u24, dgram[25..28], der.len + 3, .big);
    std.mem.writeInt(u24, dgram[28..31], der.len, .big);
    @memcpy(dgram[31..], &der);
    var ts: TestSink = .{};
    s.handle(&dgram, 0, ts.sink());
    try std.testing.expectEqual(State.failed, s.state);
    try std.testing.expectEqualStrings("a handshake message is malformed", s.reason);
}
