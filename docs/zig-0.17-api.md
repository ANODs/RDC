<!-- API notes verified on Zig 0.17.1 (macOS arm64): every example was compiled and run. -->

# Zig 0.17.1 API cheat-sheet (verified)

Verified 2026-11-09: `~/Applications/zig-0.17.1/zig` = 0.17.1, macOS 26 arm64 (M4 Pro), Command Line Tools only
(`xcode-select -p` = `/Library/Developer/CommandLineTools`, SDK 26.4.1, no Xcode.app).
Every snippet is an excerpt of a file that was compiled **and run**. `./run_all.sh` re-runs everything
(last output: `run_all.log`, ends with `ALL OK`). std paths below are relative to `~/Applications/zig-0.17.1/lib/std/`.

```
zig-api/
  rdc/        mini project (items 1, 6): build.zig, build.zig.zon, src/{main.zig,shim.m,shim.h},
              web/{web.zig,index.html}, macos/Info.plist
  snippets/   s00_lang.zig (language changes), s02a..s10_*.zig (items 2-10), standalone:
              `zig run <file>` / `zig build-exe <file>`; extra/ = gotcha repros (EPIPE, raw fds,
              positional stdout, embed-test)
  probe.sh    compile-probes the "gone / renamed" table below (+ expected compile errors)
  run_all.sh  re-verify everything (project, snippets, curl, probe); run_all.log = last run
```

## 0. Gone / renamed (each one probed with a real compile)

| 0.14/0.15 | 0.17.1 |
|---|---|
| `std.Thread.Mutex/Condition/RwLock/Semaphore/ResetEvent/WaitGroup/Futex/Pool` | gone. `std.Io.Mutex/Condition/RwLock/Semaphore/Event/Queue/Group`, `io.futexWait/futexWake` (all take `io`) |
| `std.Thread.sleep`, `std.time.sleep` | `try io.sleep(.fromMilliseconds(n), .awake)` |
| `std.time.Instant/Timer/nanoTimestamp/milliTimestamp` | `std.Io.Clock.awake.now(io)` (monotonic), `std.Io.Clock.real.now(io)` (wall). `std.time` = constants only |
| `std.crypto.random` | `io.random(&buf)`, `try io.randomSecure(&buf)`, `std.Random.IoSource{ .io = io }` |
| `std.net` | `std.Io.net` |
| `std.posix.write/send/recv/socket/close` | gone. `std.posix.read`, `setsockopt`, `openat` remain; raw libc: `std.c.send/recv/write` |
| `std.fs.cwd()`, `std.fs.File`, `std.io.getStdOut()` | `std.Io.Dir.cwd()`, `std.Io.File`, `std.Io.File.stdout()` (methods take `io`) |
| `std.heap.GeneralPurposeAllocator` | gone. `std.heap.SafeAllocator` (`DebugAllocator` still compiles, deprecated) |
| `std.process.argsAlloc/args/getEnvMap`, `std.os.argv` | gone. `main(init: std.process.Init)`: `init.minimal.args`, `init.environ_map` |
| `b.args`, `Step.makeFn` | `error: no field named 'args'` / `'makeFn'`. Use `run.addPassthruArgs()`. Steps are a closed set (Run, WriteFile, Install*, TranslateC, ...) |
| `exe.linkFramework/linkLibC/addCSourceFile` | only on `Module`: `exe.root_module.linkFramework(...)`, `.link_libc = true` |
| `@cImport` | `error: invalid builtin function: '@cImport'`. Use `b.addTranslateC` |
| `callconv(.C)` | `callconv(.c)` (`.C`: `union 'lang.CallingConvention' has no member named 'C'`) |
| `"x" ** 1000` | `**` removed from the grammar. `const a: [1000]u8 = @splat('x');` |
| `.ReleaseFast` / `-Doptimize=ReleaseFast` | `std.builtin.Optimize` = `.debug .safe .fast .small`; old names are deprecated decls; `-Doptimize=fast`, `--release=fast` |
| `std.builtin` | `std.lang` (`std.builtin` is a deprecated alias) |
| `@TypeOf(.enum_literal)`, `@intFromEnum/@enumFromInt` | `@EnumLiteral()`, `@backingInt/@fromBackingInt` (old ones still compile, deprecated) |
| `std.meta.Int`, `std.meta.Tuple` | gone. `@Int(.unsigned, 12)`, `@Tuple(&.{ u8, bool })` |
| `std.mem.indexOf*` | deprecated aliases of `std.mem.find*` |
| `std.fmt.bufPrint`, `std.fmt.allocPrint` | still work, deprecated: `std.mem.print(buf, ...)`, `gpa.print(...)` |
| `std.ArrayListUnmanaged` | deprecated alias of `std.ArrayList` (= unmanaged); managed: `std.array_list.Managed` (deprecated) |

Still there: `std.debug.print`, `std.log`, `std.json.parseFromSlice`, `std.atomic.Value`, `std.Thread.spawn/join/detach/getCurrentId/getCpuCount`, `std.fs.path.*`, `std.heap.page_allocator/c_allocator/smp_allocator/ArenaAllocator`.

---

## 1. Build system

### rdc/build.zig.zon
```zig
.{
    .name = .rdc, // enum literal, bare identifier only (.@"my-app" -> error)
    .version = "0.1.0", // full semver ("0.1" -> InvalidVersion)
    .fingerprint = 0x7d1efb6da7c9bf61, // from `zig build` suggestion; never change
    .minimum_zig_version = "0.17.1", // optional, not enforced ("0.18.0" builds fine)
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src", "web", "macos" }, // required
}
```
Fingerprint: leave the field out, run `zig build`:
`error: missing top-level 'fingerprint' field; suggested value: 0x7d1efb6da7c9bf61` (or `zig init`).
High 32 bits come from `.name` (0x7d1efb6d for `rdc`), low 32 are random; rename the package and you get
`invalid fingerprint: ...; if this is a new or forked package, use this value: ...`.
Required fields: `name`, `version`, `fingerprint`, `paths`. A project with no build.zig.zon still builds.

### rdc/build.zig (complete file)
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

    // Second module, rooted outside src/. @embedFile paths are relative to web/web.zig
    // and may not escape the module root directory (web/).
    const web_mod = b.createModule(.{
        .root_source_file = b.path("web/web.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "web", .module = web_mod }},
    });
    // (equivalent: exe_mod.addImport("web", web_mod);)

    // @cImport is gone in 0.17 ("invalid builtin function"): translate headers in the build graph.
    const shim_c = b.addTranslateC(.{
        .root_source_file = b.path("src/shim.h"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("shim_c", shim_c.createModule());

    if (is_macos) {
        // Language is inferred from the .m extension (Module.CSourceLanguage.objective_c).
        exe_mod.addCSourceFile(.{ .file = b.path("src/shim.m"), .flags = &.{"-fobjc-arc"} });
        const frameworks = [_][]const u8{
            "Foundation", "AppKit",       "ScreenCaptureKit",    "VideoToolbox", "CoreMedia",
            "CoreVideo",  "CoreGraphics", "ApplicationServices", "IOSurface",
        };
        for (frameworks) |fw| exe_mod.linkFramework(fw, .{});
    }

    const exe = b.addExecutable(.{ .name = "rdc", .root_module = exe_mod });
    b.installArtifact(exe);

    // zig build run -- arg1 arg2
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs(); // replaces the old `if (b.args) |args| run_cmd.addArgs(args);`
    b.step("run", "Run rdc").dependOn(&run_cmd.step);

    // zig build test  (runs `test` blocks of src/main.zig and everything it references)
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(exe_tests).step);

    // zig build app  ->  zig-out/RDC.app/Contents/{Info.plist,MacOS/rdc}, ad-hoc signed
    const app_step = b.step("app", "Assemble and ad-hoc sign zig-out/RDC.app");
    const install_plist = b.addInstallFileWithDir(
        b.path("macos/Info.plist"),
        .{ .custom = "RDC.app/Contents" },
        "Info.plist",
    );
    const install_app_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "RDC.app/Contents/MacOS" } },
    });
    const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--identifier", "com.example.rdc" });
    // install prefix is only known at make time -> LazyPath relative to .install_prefix
    codesign.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
    codesign.step.dependOn(&install_plist.step);
    codesign.step.dependOn(&install_app_exe.step);
    app_step.dependOn(&codesign.step);
}
```

### rdc/src/shim.m (excerpt) and rdc/web/web.zig
```objc
#if !__has_feature(objc_arc)
#error "shim.m must be compiled with -fobjc-arc"
#endif
#import <Foundation/Foundation.h>   // + AppKit, ScreenCaptureKit, VideoToolbox, CoreMedia, CoreVideo,
                                    //   CoreGraphics, ApplicationServices, IOSurface, <dispatch/dispatch.h>
int shim_add(int a, int b) {
    @autoreleasepool {
        NSString *s = [NSString stringWithFormat:@"shim_add(%d, %d) = %d", a, b, a + b];
        __weak NSString *weak = s; // __weak only compiles under ARC
        NSLog(@"%@ (weak alive: %d)", s, weak != nil);
    }
    return a + b;
}
// shim_probe_frameworks(): touches one symbol per framework ([SCStreamConfiguration new],
// VTCompressionSessionGetTypeID(), CMTimeMake, CVPixelBufferGetTypeID, CGMainDisplayID,
// AXIsProcessTrusted, IOSurfaceGetPropertyMaximum, [NSApplication class], NSProcessInfo) -> 9
```
```zig
// web/web.zig
pub const index_html = @embedFile("index.html");
```

### Verified runs
```
$ zig build run -- arg1 "arg two"
argv[0] = ./zig-out/bin/rdc
argv[1] = arg1
argv[2] = arg two
embedded web/index.html: 66 bytes
2026-11-09 ... rdc[...] shim_add(2, 3) = 5 (weak alive: 1)
shim_add(2, 3) = 5
framework probe = 9/9
$ otool -L zig-out/bin/rdc     -> AppKit ApplicationServices CoreGraphics CoreMedia CoreVideo Foundation
                                  IOSurface ScreenCaptureKit VideoToolbox (+ CoreFoundation, libobjc)
$ zig build test --summary all -> Build Summary: 4/4 steps succeeded; 4/4 tests passed
$ zig build app                -> ./zig-out/RDC.app: replacing existing signature
$ codesign --verify --strict --verbose=2 zig-out/RDC.app
zig-out/RDC.app: valid on disk
zig-out/RDC.app: satisfies its Designated Requirement      (Identifier=com.example.rdc, Signature=adhoc)
$ find zig-out/RDC.app -type f -> Contents/Info.plist, Contents/MacOS/rdc, Contents/_CodeSignature/CodeResources
$ zig build -Dtarget=x86_64-windows -> zig-out/bin/rdc.exe: PE32+ executable (console) x86-64 (+ rdc.pdb)
```
Where: `Build.zig` (createModule 722, addExecutable 579, addTest 676, addRunArtifact 762, addSystemCommand 743,
addInstallArtifact 1465, addInstallFileWithDir 1516, addTranslateC 949, `Graph.path` 173), `Build/Module.zig`
(addImport 306, addAnonymousImport 313, linkFramework 374, addCSourceFile 415), `Build/Step/Run.zig`
(addPassthruArgs 593, addDirectoryArg 492), `Build/Step/InstallArtifact.zig:34` (Options.dest_dir),
`Build/Configuration.zig` (`LazyPath.Relative.Base`: install_prefix, install_bin, local_cache, ...). The maker
(`lib/compiler/Maker.zig`) runs the serialized graph; build.zig only configures.

Gotchas:
- `-fobjc-arc` proof: without it the `#error` fires (and `__weak` gives "cannot create __weak reference in file using manual reference counting"); with it the object imports `_objc_initWeak`, `_objc_release`, `_objc_retainAutoreleasedReturnValue`.
- All 9 frameworks resolve from the CLT SDK with zero configuration (`zig libc` reports `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`).
- Install paths are unknown at configure time: use `b.graph.path(.install_prefix, "RDC.app")`. It honors `-p <dir>` (tested). A Run step with no output-file args counts as having side effects and always runs. arm64 binaries are already ad-hoc signed by the linker, hence "replacing existing signature".
- Custom logic at make time = build a host tool (`.target = b.graph.host`) and `b.addRunArtifact(tool)`; there is no `makeFn` any more.
- `zig build test` prints a `failed command: ...` line whenever the test binary wrote to stderr (here NSLog), even with `4/4 tests passed` and exit 0. Go by the Build Summary and the exit code.
- `zig build test -Dtarget=x86_64-windows` compiles, then fails: "the host system ... is unable to execute binaries from the target".
- Windows: `link_libc = true` uses bundled mingw. The `.m` and frameworks are skipped by `if (is_macos)`; in main.zig the `extern fn` declarations stay, but calls sit under `if (has_shim)` (`builtin.os.tag == .macos`). Unreferenced externs never reach the linker.
- `@embedFile` can't escape its module root: `@embedFile("../src/data.txt")` -> `error: embed of file outside package path`. Either root a module in that directory (web/) or `mod.addAnonymousImport("index_html", .{ .root_source_file = b.path("web/index.html") })` + `@embedFile("index_html")` (tested in snippets/extra/embed-test).
- translate-c: the first use compiles the translate-c tool (~20 s, 845 MB RSS), then it's cached. Pointers come out as `[*c]`: the typedef is `?*const fn (?*anyopaque, [*c]const u8, usize, c_int, u64) callconv(.c) void`, so a callback declared with `[*]const u8` doesn't coerce to it (compile error). Hand-written externs can use `[*]const u8`.
- `-Doptimize=` values are `debug|safe|fast|small` (`zig build --help`). `ReleaseFast` is still accepted (deprecated, "to be removed after 0.18.0").

---

## 2. main: classic vs `std.process.Init`
```zig
// snippets/s02c_main_init.zig  ("juicy main")
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa; // SafeAllocator (leak-checked) in debug/safe; c_allocator/smp_allocator in fast/small
    const io = init.io; // std.Io.Threaded instance owned by start.zig
    const arena = init.arena.allocator(); // process-lifetime, threadsafe
    const args = try init.minimal.args.toSlice(arena); // []const [:0]const u8, args[0] = exe
    for (args) |a| std.debug.print("arg: {s}\n", .{a});
    std.debug.print("HOME={s}\n", .{init.environ_map.get("HOME") orelse "?"});
    ...
}
```
```zig
// snippets/s02b_main_minimal.zig  (args + environ only: no allocator, no Io)
pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate(); // POSIX: no allocation; Windows needs iterateAllocator(gpa)
    while (it.next()) |arg| std.debug.print("arg: {s}\n", .{arg});
    std.debug.print("HOME={s}\n", .{init.environ.getPosix("HOME") orelse "?"});
}
```
```zig
// snippets/s02a_main_classic.zig  (build allocator + Io yourself; argv is unreachable here)
pub fn main() !void {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = safe.deinit(); // returns leak count, logs each leak
    const gpa = safe.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    ...
    try std.Io.File.stdout().writeStreamingAll(io, "classic main: ok\n");
}
```
Where: `process.zig:31` (Init, Init.Minimal), `start.zig:786` (callMain: picks gpa, creates Threaded, arena, environ_map),
`process/Args.zig:456` iterate / `:479` toSlice, `heap/SafeAllocator.zig:621`, `Io/Threaded.zig:1654` init / `:1854` io().

Gotchas:
- Leaks in `init.gpa` print `error(SafeAllocator): leaked [addr: ..., len: 10] allocated at: <trace>`, but the exit code stays 0.
- `Threaded.init` installs no-op SIGPIPE and SIGIO handlers: a write to a dead socket returns an error and doesn't kill the process; SIGIO is used for cancelation. Its `gpa` is used only by `io.async`/`io.concurrent`.
- `std.debug.print` and `std.log` use their own global Io (`std.Options.debug_io`), not `init.io`.

---

## 3. TCP server (std.Io.net) + duplex use of one connection
```zig
// snippets/s03a_tcp_server.zig   (verified: curl -i http://127.0.0.1:8089/hello -> 200, 3 KB header ok)
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    ...
    const addr = try net.IpAddress.parse("0.0.0.0", port); // or .{ .ip4 = .unspecified(port) }
    var server = try addr.listen(io, .{ .reuse_address = true }); // SO_REUSEADDR + SO_REUSEPORT
    defer server.deinit(io);
    while (served < max_conns) : (served += 1) {
        const stream = try server.accept(io); // blocks; returns net.Stream
        const t = try std.Thread.spawn(.{}, handleConn, .{ io, stream });
        if (served + 1 == max_conns) t.join() else t.detach();
    }
}

fn handleConn(io: std.Io, stream: net.Stream) void {
    defer stream.close(io);
    serve(io, stream) catch |err| std.debug.print("conn error: {t}\n", .{err});
}

fn serve(io: std.Io, stream: net.Stream) !void {
    // TCP_NODELAY: no std.Io option -> setsockopt on the raw fd (POSIX only; compileError on Windows)
    try std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));

    var rbuf: [8192]u8 = undefined; // header must fit in the reader buffer
    var sr = stream.reader(io, &rbuf); // net.Stream.Reader; generic API is sr.interface (*std.Io.Reader)
    const r = &sr.interface;
    const head_len = while (true) {
        if (std.mem.find(u8, r.buffered(), "\r\n\r\n")) |i| break i + 4;
        if (r.bufferedLen() == rbuf.len) return error.HeaderTooLarge;
        r.fillMore() catch |err| switch (err) { // one read(2) into the buffer
            error.EndOfStream => return, // peer closed before a full header
            error.ReadFailed => return sr.err.?, // real error is stored on the impl
        };
    };
    const head = r.buffered()[0..head_len];
    ...
    r.toss(head_len); // consume

    var wbuf: [1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf); // net.Stream.Writer; generic API is sw.interface (*std.Io.Writer)
    const w = &sw.interface;
    const body = "hello from zig 0.17\n";
    w.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return sw.err.?;
    w.writeAll(body) catch return sw.err.?; // loops until everything is buffered/sent
    w.flush() catch return sw.err.?; // loops on short writes: write-all semantics
}
```
**Reader thread + writer thread on one connection: safe with the 0.17 types, raw fds not needed.**
Give each thread its own `Stream.Reader`/`Stream.Writer` with its own buffer and share the `io`. `net.Stream` is a plain
handle you copy by value. Under `Io.Threaded` every read/write is a direct blocking `recvmsg`/`sendmsg`
(`Io/Threaded.zig:12998` netReadPosix, `:13482` netWritePosix) with no lock, and `Io.Threaded` is threadsafe.
Verified in s03b: the server reader sat blocked in recv while the writer thread sent frames on the same fd.
```zig
// snippets/s03b_duplex.zig (excerpt)
const Conn = struct {
    io: std.Io,
    stream: net.Stream,
    got_bye: std.Io.Event = .unset,
    write_mutex: std.Io.Mutex = .init, // only needed if >1 thread writes
};

fn readerThread(c: *Conn) void {
    var buf: [1024]u8 = undefined;
    var sr = c.stream.reader(c.io, &buf); // own Reader + own buffer per thread
    const r = &sr.interface;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |err| {
            std.debug.print("[srv reader] stop: {t} (impl err: {?t})\n", .{ err, sr.err });
            return;
        };
        if (std.mem.eql(u8, line, "bye\n")) c.got_bye.set(c.io);
    }
}

fn writerThread(c: *Conn) void {
    var buf: [256]u8 = undefined;
    var sw = c.stream.writer(c.io, &buf); // own Writer + own buffer per thread
    const w = &sw.interface;
    for (0..3) |i| {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        w.print("tick {d}\n", .{i}) catch return;
        w.flush() catch return; // reader thread is blocked in recv() on the same fd right now
        c.io.sleep(.fromMilliseconds(30), .awake) catch return;
    }
    c.got_bye.wait(c.io) catch return;
    // raw-fd alternative (std.posix.write/send are gone; std.c.* are plain libc externs):
    const raw = "raw send\n";
    _ = std.c.send(c.stream.socket.handle, raw.ptr, raw.len, std.c.MSG.NOSIGNAL); // NOSIGNAL: no SIGPIPE
    w.writeAll("goodbye\n") catch return;
    w.flush() catch return;
    c.stream.shutdown(c.io, .send) catch {}; // FIN -> client sees EOF
}

// main: var c: Conn = .{ .io = io, .stream = try server.accept(io) };
//       const rt = try std.Thread.spawn(.{}, readerThread, .{&c});
//       const wt = try std.Thread.spawn(.{}, writerThread, .{&c});
//       wt.join(); rt.join(); c.stream.close(io);
// unblock a reader stuck in recv(): from another thread
//       try c2.stream.shutdown(io, .both); // reader gets error.EndOfStream (~0.15 ms), then join, then close
```
Output: `TCP_NODELAY=4`, `[client] tick 0..2`, `[srv reader] got bye`, `[client] raw send`, `[client] goodbye`,
`[client] end: EndOfStream`, `reader unblocked after 151 us`.

Io-native alternative (snippets/s03c_io_concurrent.zig): run the reader as an Io task and cancel it.
```zig
var fut = try io.concurrent(readerTask, .{ io, conn }); // runs on an Io.Threaded worker thread
...
const result = fut.cancel(io); // blocked recvmsg returns error.Canceled -> "error.Canceled (~120 us)"
```
Where: `Io/net.zig` (IpAddress.parse 101, ListenOptions 226, listen 248, connect 345, Stream 1284, shutdown 1325,
reader 1501, writer 1515, Server.accept 1607), `Io/Reader.zig` (takeDelimiterInclusive 824, fillMore 1156),
`Io/Writer.zig` (flush 387, writeAll 625), `posix.zig` (setsockopt 1079, read 406).

Gotchas:
- Never share one `Reader` or `Writer` between threads. More than one writer thread (pings + data) needs a mutex around the Writer so frames don't interleave.
- `close()` the stream only after both threads are done. To wake a blocked std.Thread reader, call `shutdown(.both)`; `Future.cancel` works only for tasks started with `io.async/concurrent` (plain std.Threads have no Io cancel state).
- `Reader`/`Writer` interface errors are only `error.ReadFailed`/`error.WriteFailed`; the real cause is in `sr.err` / `sw.err`. Peer gone (snippets/extra/x_epipe.zig): the first 53–86 KB of writes still succeeded (two runs), then `SocketUnconnected` (EPIPE); a read gave `ConnectionResetByPeer`. The process got no SIGPIPE.
- `reuse_address = true` also sets **SO_REUSEPORT**: a second process listened on the same port without an error and the kernel split the connections between them (verified). Io has no option for SO_REUSEADDR alone.
- After `listen`, `server.socket.address` holds the bound address (getsockname), so port 0 works: `server.socket.address.getPort()`.
- TCP_NODELAY reads back as 4 via `std.c.getsockopt` on macOS (non-zero = on).
- Raw fd functions that still exist (verified): `std.c.send(fd, ptr, len, std.c.MSG.NOSIGNAL)`, `std.c.recv`, `std.c.write`, `std.posix.read(fd, buf)`.

---

## 4. Threads, sync, atomics, time
```zig
// snippets/s04_threads_sync.zig (excerpt)
const Io = std.Io;
fn BlockingQueue(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        mutex: Io.Mutex = .init,
        not_empty: Io.Condition = .init,
        not_full: Io.Condition = .init,
        items: [cap]T = undefined,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,

        pub fn push(q: *Self, io: Io, item: T) !void {
            try q.mutex.lock(io); // lock() is a cancelation point -> error.Canceled
            defer q.mutex.unlock(io);
            while (q.len == cap and !q.closed) try q.not_full.wait(io, &q.mutex);
            if (q.closed) return error.Closed;
            q.items[(q.head + q.len) % cap] = item;
            q.len += 1;
            q.not_empty.signal(io);
        }

        /// null on timeout or when closed and drained.
        pub fn popTimeout(q: *Self, io: Io, timeout_ms: i64) !?T {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            const deadline = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }).toDeadline(io);
            while (q.len == 0) {
                if (q.closed) return null;
                q.not_empty.waitTimeout(io, &q.mutex, deadline) catch |err| switch (err) {
                    error.Timeout => return null,
                    error.Canceled => |e| return e,
                };
            }
            const item = q.items[q.head];
            q.head = (q.head + 1) % cap;
            q.len -= 1;
            q.not_full.signal(io);
            return item;
        }
        // close(): lockUncancelable, closed = true, not_empty.broadcast(io), not_full.broadcast(io)
    };
}

// std.Thread.spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!std.Thread
const th = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, producer, .{ io, &q, &produced });
th.join(); // or th.detach()

io.sleep(.fromMilliseconds(2), .awake) catch return; // sleep N ms (Cancelable!void)

const t0 = Io.Clock.awake.now(io); // monotonic Io.Timestamp{ .nanoseconds: i96 }
const elapsed = t0.durationTo(Io.Clock.awake.now(io)); // Io.Duration
elapsed.toMicroseconds(); // i64   (also toMilliseconds/toSeconds; toNanoseconds -> i96)
Io.Clock.real.now(io).toMilliseconds(); // unix ms

var counter: std.atomic.Value(u64) = .init(5);
const prev = counter.fetchAdd(1, .acq_rel);
const cas = counter.cmpxchgStrong(6, 100, .acq_rel, .acquire); // null on success, else actual value
var flag: std.atomic.Value(bool) = .init(false);
flag.store(true, .release);
_ = flag.load(.acquire);

var storage: [8]u32 = undefined; // built-in bounded MPMC queue (closable, no get timeout)
var ioq: Io.Queue(u32) = .init(&storage);
try ioq.putOne(io, 42);
_ = try ioq.getOne(io);
```
Output: `sum=45 produced=10 elapsed=123721 us`, `empty pop -> null after 20 ms`, `flag=true prev=5 cas=null now=100`.

Where: `Thread.zig:344` spawn, `:298` SpawnConfig (default stack 16 MiB); `Io.zig` Mutex 1716, Condition 1782
(waitTimeout 1817), Event 1966, Queue 2390, sleep 2603, Clock 836, Timestamp 1021, Duration 1087, Timeout 1251; `atomic.zig:9`.

Gotchas:
- `std.Thread.Mutex/Condition` are gone. The `std.Io` versions take `io` on every call; `.init` is a decl (`mutex: Io.Mutex = .init`).
- `lock`/`wait`/`waitTimeout` can return `error.Canceled`. `lockUncancelable` and `waitUncancelable` don't, and are handy in code that can't fail.
- `Timeout` is `.none`, `.{ .duration = .{ .raw = Duration, .clock = .awake } }` or `.{ .deadline = Clock.Timestamp }`. Call `toDeadline(io)` once before the wait loop so spurious wakeups don't extend the total wait.
- Clocks: `.awake` = CLOCK_UPTIME_RAW on macOS (stops while the machine sleeps), `.boot` = CLOCK_MONOTONIC_RAW (keeps counting during sleep), `.real` = wall clock.
- `std.Io.Event` (`.unset`, `set(io)`, `wait(io)`, `waitTimeout(io, t)`) is the threadsafe one-shot flag; `std.Thread.ResetEvent` is gone.

---

## 5. SHA-1, base64, secure random, constant-time compare
```zig
// snippets/s05_crypto.zig (excerpt; `zig test` passes the RFC 6455 vector)
const Sha1 = std.crypto.hash.Sha1;

fn wsAccept(key: []const u8, out: *[28]u8) []const u8 {
    var h = Sha1.init(.{});
    h.update(key);
    h.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [Sha1.digest_length]u8 = undefined; // 20
    h.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest); // returns out[0..calcSize(20)]
}
// wsAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

var d: [Sha1.digest_length]u8 = undefined;
Sha1.hash("abc", &d, .{}); // one-shot; {x} on &d prints a9993e36...d89d

var b64: [std.base64.standard.Encoder.calcSize(5)]u8 = undefined; // calcSize is comptime-callable
_ = std.base64.standard.Encoder.encode(&b64, "hello"); // "aGVsbG8="
var dec: [5]u8 = undefined;
try std.base64.standard.Decoder.decode(&dec, "aGVsbG8=");

var key_bytes: [16]u8 = undefined;
io.random(&key_bytes); // CSPRNG seeded from the OS, never fails, threadsafe
var nonce: [12]u8 = undefined;
try io.randomSecure(&nonce); // fresh OS entropy (syscall), error.EntropyUnavailable possible
const src: std.Random.IoSource = .{ .io = io };
const rng = src.interface(); // std.Random interface backed by io.random
const r32 = rng.int(u32);
var r32b: u32 = undefined;
io.random(std.mem.asBytes(&r32b)); // same thing without the interface

fn ctEql(a: []const u8, b: []const u8) bool { // constant time for runtime-length slices
    if (a.len != b.len) return false; // length is not secret
    return std.crypto.timing_safe.compare(u8, a, b, .big) == .eq;
}
std.crypto.timing_safe.eql([4]u8, fixed_a, "abcd".*); // arrays/vectors only
```
Where: `crypto.zig:145` (hash.Sha1), `crypto/Sha1.zig` (hash 33, init/update/final), `base64.zig:121` encode,
`Io.zig:2674` random, `:2691` randomSecure, `Random.zig:37` IoSource, `crypto/timing_safe.zig` eql 12, compare 47.

Gotchas:
- `std.crypto.random` is gone; randomness needs an `io`.
- `timing_safe.eql` takes arrays/vectors only (compile-time length), so use `timing_safe.compare(...) == .eq` for slices. It asserts equal lengths.
- Keep the RFC 6455 vector as a unit test (`zig test snippets/s05_crypto.zig`). My first draft of the GUID was wrong and only the test caught it.

---

## 6. C interop: extern fns + C calling a Zig callback from another thread
```zig
// rdc/src/main.zig (excerpt) -- no `export` anywhere, no @cImport
extern fn shim_add(a: c_int, b: c_int) c_int;
pub const FrameCb = *const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize, key: c_int, ts: u64) callconv(.c) void;
extern fn shim_start_frames(cb: FrameCb, ctx: ?*anyopaque, count: c_int) void;

const FrameSink = struct {
    io: std.Io,
    expected: u32,
    received: std.atomic.Value(u32) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),
    done: std.Io.Event = .unset,

    // Called by C on a GCD worker thread.
    fn onFrame(ctx: ?*anyopaque, data: [*]const u8, len: usize, key: c_int, ts: u64) callconv(.c) void {
        const self: *FrameSink = @ptrCast(@alignCast(ctx.?));
        _ = self.bytes.fetchAdd(len, .monotonic);
        ...
        if (self.received.fetchAdd(1, .acq_rel) + 1 == self.expected) self.done.set(self.io);
    }
};

// in main:
var sink: FrameSink = .{ .io = io, .expected = 3 };
shim_start_frames(&FrameSink.onFrame, &sink, 3);
try sink.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
```
```objc
// rdc/src/shim.m
typedef void (*shim_frame_cb)(void *ctx, const uint8_t *data, size_t len, int key, uint64_t ts);
void shim_start_frames(shim_frame_cb cb, void *ctx, int count) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static const uint8_t payload[4] = {0xde, 0xad, 0xbe, 0xef};
        for (int i = 0; i < count; i++) cb(ctx, payload, sizeof payload, i == 0, (uint64_t)(1000 + i));
    });
}
```
Output: `main tid=9000223`, `frame key=1 ts=1000 len=4 data[0]=0xde tid=9000225` (x3, different thread), `callbacks: 3, bytes: 12`.

Gotchas:
- The spelling is `callconv(.c)`; `.C` is a compile error.
- On a foreign (GCD) thread you can use `std.debug.print`, atomics and `io` (Event.set): such threads simply have no Io cancel state.
- With a hand-written `extern fn` you pick the Zig pointer types (`[*]const u8` matches `const uint8_t *`). translate-c gives `[*c]` and `?*const fn` (section 1). Both kinds of declaration of the same symbol coexist in one binary (tested).

---

## 7. Printing, std.log with custom logFn, files in append mode
```zig
// snippets/s07_log_files.zig (excerpt)
pub const std_options: std.Options = .{ // must be `pub` in the root source file
    .log_level = .debug, // default: .debug in debug builds, .info otherwise
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(), // was @TypeOf(.enum_literal)
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf); // same lock std.debug.print uses; unlock flushes
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface; // *std.Io.Writer
    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    w.print("[{s}] " ++ scope_txt ++ format ++ "\n", .{level.asText()} ++ args) catch {};
}
const net_log = std.log.scoped(.net);
// std.debug.print("...{d}\n", .{42});  std.log.info(...);  net_log.warn(...)
// -> "[info] hello log", "[warning] (net) scoped warning code=7", "[debug] ..."

// (a) portable "append": open-or-create without truncation, position the writer at EOF
const f = try cwd.createFile(io, "app.log", .{ .truncate = false }); // no O_APPEND flag in Io
defer f.close(io);
var buf: [1024]u8 = undefined;
var fw = f.writer(io, &buf); // positional writer
try fw.seekTo(try f.length(io));
try fw.interface.print("line at t={d}\n", .{std.Io.Clock.real.now(io).toSeconds()});
try fw.flush(); // File.Writer.flush returns the real error (interface.flush -> error.WriteFailed)

// (b) real O_APPEND (atomic appends across processes): raw open + wrap the fd in std.Io.File
const fd = try std.posix.openat(std.posix.AT.FDCWD, "append.log", .{
    .ACCMODE = .WRONLY,
    .CREAT = true,
    .APPEND = true,
    .CLOEXEC = true,
}, 0o644);
const f2: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
defer f2.close(io);
var fw2 = f2.writerStreaming(io, &buf); // streaming = write(2), honors O_APPEND
try fw2.interface.writeAll("appended\n");
try fw2.flush();

const data = try std.Io.Dir.cwd().readFileAlloc(io, "app.log", init.gpa, .limited(1 << 20)); // grows per run

var out_buf: [512]u8 = undefined; // stdout
var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
try stdout.interface.print("done\n", .{});
try stdout.flush();
```
Where: `debug.zig` print 323, lockStderr 298; `log.zig` defaultLog 96, scoped 137; `std.zig:121` Options;
`Io/Dir.zig` CreateFileOptions 589, createFile 641, readFileAlloc 1333; `Io/File.zig` writer 597, writerStreaming 604;
`Io/File/Writer.zig:199` seekTo; `posix.zig:447` openat.

Gotchas:
- `CreateFileOptions` and `OpenFileOptions` have no append flag.
- **`File.writer()` is positional** (pwrite from its own offset, starting at 0). Run as `./prog >> existing.txt`, the template-style `File.stdout().writer(...)` overwrote the start of the file (verified, snippets/extra/x_stdout_positional.zig). Use `writerStreaming` for stdout, pipes and O_APPEND files. std.debug and std.log already write in streaming mode.
- `std.debug.lockStderr` is recursive per thread, and `unlockStderr()` flushes.

---

## 8. std.fmt
```zig
// snippets/s08_fmt.zig (excerpt)
var buf: [128]u8 = undefined;
const s = try std.fmt.bufPrint(&buf, "{d} {s} {x} {X} {x:0>8} {b}", .{ 42, "str", 255, 255, 0xbeef, 5 });
// "42 str ff FF 0000beef 101"
const s2 = try std.mem.print(&buf, "{d:>5}|{d:.2}|{s:<6}|", .{ 7, 3.14159, "ab" }); // "    7|3.14|ab    |"
std.debug.print("{x} {X}\n", .{ "\x01\xab", &[_]u8{ 0xde, 0xad } }); // "01ab DEAD"
std.debug.print("{t} {t} {f} {any} {?d} {q}\n", .{ Color.green, error.Oops, Point{ .x = 1, .y = 2 }, [_]u8{ 1, 2 }, @as(?u8, null), "a\"b\n" });
// "green Oops (1,2) { 1, 2 } null "a\"b\n""
var tiny: [4]u8 = undefined;
_ = std.fmt.bufPrint(&tiny, "{d}", .{123456}) catch |err| ...; // error.NoSpaceLeft
const heap_str = try init.gpa.print("{s}-{d}", .{ "id", 9 }); // allocPrint is deprecated -> Allocator.print

try std.fmt.parseInt(u16, "8080", 10); // 8080
try std.fmt.parseInt(i32, "-17", 10); // -17
try std.fmt.parseInt(u32, "0xff", 0); // 255  (base 0 = detect 0x/0o/0b prefix)
try std.fmt.parseInt(u64, "1_000_000", 10); // 1000000 ('_' ignored)
std.fmt.parseInt(u8, "300", 10); // error.Overflow;  "12a" -> error.InvalidCharacter
try std.fmt.parseFloat(f64, "2.5e3"); // 2500
```
`Point.format` signature: `pub fn format(p: Point, w: *std.Io.Writer) std.Io.Writer.Error!void`.
Where: `fmt.zig` bufPrint 600, parseInt 322; `mem.zig:5255` print; `mem/Allocator.zig:506` print; specifiers documented at `Io/Writer.zig:698`.

Gotchas:
- A type's `format` method runs only with `{f}`. Plain `{}` prints the default struct form (`.{ .x = 1 }`) with no error.
- `{t}` prints enum tags and error names (`{}` on an enum prints `.a`). `{b64}` gives base64.

---

## 9. std.json
```zig
// snippets/s09_json.zig (excerpt)
const Msg = struct {
    t: []const u8,
    code: ?[]const u8 = null, // optional: absent -> null (needs a default!)
    h264: bool = false, // absent -> default
    w: u32 = 1280, // absent -> default
};
const input =
    \\{"t":"hello","code":"123456789","h264":true,"extra":{"ignored":[1,2]}}
;
const parsed = try std.json.parseFromSlice(Msg, gpa, input, .{ .ignore_unknown_fields = true });
defer parsed.deinit(); // frees the arena holding strings
const m = parsed.value; // t=hello code=123456789 h264=true w=1280

// without .ignore_unknown_fields: {"t":"x","zz":1} -> error.UnknownField
// missing optional: {"t":"x"} -> code=null h264=false
const m3 = try std.json.parseFromSliceLeaky(Msg, arena.allocator(), input, .{ .ignore_unknown_fields = true });
const dyn = try std.json.parseFromSlice(std.json.Value, gpa, input, .{}); // dyn.value.object.get("t").?.string
std.debug.print("json: {f}\n", .{std.json.fmt(m, .{})}); // {"t":"hello","code":"123456789","h264":true,"w":1280}
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try std.json.Stringify.value(Msg{ .t = "hi", .code = null }, .{ .emit_null_optional_fields = false }, &out.writer);
// out.written() -> {"t":"hi","h264":false,"w":1280}
```
Where: `json/static.zig` ParseOptions 19 (ignore_unknown_fields, duplicate_field_behavior, allocate, max_value_len), parseFromSlice 74; `json.zig:97` fmt.
Gotcha: an optional field without a default (`= null`) is still required in the input. If it's missing you get `error.MissingField` (verified).

---

## 10. ArrayList and std.mem
```zig
// snippets/s10_list_mem.zig (excerpt)
var list: std.ArrayList(u8) = .empty; // unmanaged: pass the allocator to every mutating call
defer list.deinit(gpa);
try list.append(gpa, 'a');
try list.appendSlice(gpa, "bc");
try list.print(gpa, "-{d}", .{42}); // list.items == "abc-42"
_ = list.pop(); // ?T
list.clearRetainingCapacity();

var nums: std.ArrayList(u32) = try .initCapacity(gpa, 4);
defer nums.deinit(gpa);
nums.appendAssumeCapacity(1);
try nums.appendSlice(gpa, &.{ 2, 3, 4, 5 });
_ = nums.orderedRemove(0);
_ = nums.swapRemove(0);
const owned = try nums.toOwnedSlice(gpa); // list is empty afterwards; owned = { 5, 3, 4 }
defer gpa.free(owned);

const hay = "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\n\r\n";
std.mem.indexOf(u8, hay, "\r\n\r\n"); // 36 (deprecated alias of find)
std.mem.find(u8, hay, "\r\n\r\n"); // 36
std.mem.findScalar(u8, hay, ' '); // 3      (was indexOfScalar)
std.mem.findLast(u8, hay, "\r\n"); // 38     (was lastIndexOf)
std.mem.startsWith(u8, hay, "GET "); // true
std.mem.endsWith(u8, hay, "\r\n\r\n"); // true
std.mem.eql(u8, "abc", "abc"); // true
std.ascii.eqlIgnoreCase("WebSocket", "websocket"); // true
if (std.mem.cut(u8, "Upgrade: websocket", ": ")) |kv| ... // kv[0]="Upgrade", kv[1]="websocket" (new)
var it = std.mem.splitSequence(u8, hay, "\r\n");
std.mem.trim(u8, "  x y \r\n", " \r\n"); // "x y"
```
Where: `std.zig:52` ArrayList, `array_list.zig` (unmanaged `append` 1026, `Managed` 11 deprecated), `mem.zig` (eql 799, indexOf alias 1482, find 1487, startsWith 3254, cut 3301).
Gotcha: `std.ArrayList(T)` is unmanaged now (`.empty` / `initCapacity(gpa, n)`, `deinit(gpa)`, `append(gpa, x)`). `getLast` is deprecated in favor of `last()` (returns `?T`).
