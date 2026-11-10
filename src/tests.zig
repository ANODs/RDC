//! Tests of the modules that do not need an OS.
test {
    _ = @import("core/code.zig");
    _ = @import("core/keymap.zig");
    _ = @import("core/proto.zig");
    _ = @import("core/totp.zig");
    _ = @import("core/qr.zig");
    _ = @import("net/ws.zig");
    _ = @import("net/http.zig");
    _ = @import("net/stun.zig");
    _ = @import("net/sdp.zig");
    _ = @import("net/dtls.zig");
    _ = @import("net/sctp.zig");
    _ = @import("net/mqtt.zig");
    _ = @import("net/signal.zig");
    _ = @import("net/webrtc.zig");
    _ = @import("core/manifest.zig");
    _ = @import("agent/keys.zig");
    _ = @import("agent/client.zig");
    _ = @import("agent/mcp.zig");
}
