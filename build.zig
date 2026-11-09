const std = @import("std");

/// The version is set in one place — build.zig.zon; -Dversion=... overrides it.
const zon: struct {
    name: @EnumLiteral(),
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
} = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "RDC version (default: from build.zig.zon)") orelse zon.version;
    const os = target.result.os.tag;
    const is_macos = os == .macos;
    // Platform in the update manifest: macos-arm64, windows-x86_64, linux-x86_64…
    const platform = b.fmt("{s}-{s}", .{
        switch (os) {
            .macos => "macos",
            .windows => "windows",
            .linux => "linux",
            else => @tagName(os),
        },
        switch (target.result.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @tagName(target.result.cpu.arch),
        },
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const web = b.createModule(.{ .root_source_file = b.path("web/web.zig") });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "web", .module = web }},
    });
    root.addOptions("build_options", options);
    root.addIncludePath(b.path("src/platform"));
    if (os == .windows) {
        root.addCSourceFile(.{
            .file = b.path("src/platform/windows/shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-missing-field-initializers", "-DUNICODE", "-D_UNICODE", "-DCOBJMACROS", "-DWIN32_LEAN_AND_MEAN", "-D_WIN32_WINNT=0x0A00", "-DWINVER=0x0A00" },
        });
        const libs = [_][]const u8{
            "d3d11",    "dxgi",     "ole32",  "oleaut32", "user32",   "gdi32",   "shell32",
            "advapi32", "iphlpapi", "ws2_32", "winhttp",  "comctl32", "version",
        };
        for (libs) |lib| root.linkSystemLibrary(lib, .{});
        // Version info in rdc.exe: the updater checks the downloaded file against it.
        const sv = std.SemanticVersion.parse(version) catch @panic("version must look like 1.2.3");
        root.addWin32ResourceFile(.{ .file = b.path("windows/rdc.rc"), .flags = &.{
            b.fmt("/dRDC_VERSION_NUM={d},{d},{d},0", .{ sv.major, sv.minor, sv.patch }),
            b.fmt("/dRDC_VERSION_STR=\"{s}\"", .{version}),
        } });
    }
    if (is_macos) {
        root.addCSourceFile(.{
            .file = b.path("src/platform/macos/shim.m"),
            .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Wno-unused-parameter" },
        });
        const frameworks = [_][]const u8{
            "Foundation", "AppKit",       "ScreenCaptureKit",    "VideoToolbox", "CoreMedia",
            "CoreVideo",  "CoreGraphics", "ApplicationServices", "IOSurface",    "ImageIO",
        };
        for (frameworks) |fw| root.linkFramework(fw, .{});
    }

    const exe = b.addExecutable(.{
        .name = "rdc",
        .root_module = root,
        // Manifest: normal privileges, crisp text at any display scale, UTF-8, Windows 10/11 style.
        .win32_manifest = if (os == .windows) b.path("windows/rdc.manifest") else null,
    });
    if (os == .windows) exe.subsystem = .windows; // no console window; the log goes to a file
    b.installArtifact(exe);

    if (os == .windows) {
        // For a release: a single file, no archive — download and run. No version in the name, so
        // it stays correct after an auto-update and the link .../releases/latest/download/RDC.exe never changes.
        const exe_name = if (target.result.cpu.arch == .x86_64) "RDC.exe" else b.fmt("RDC-{s}.exe", .{@tagName(target.result.cpu.arch)});
        const install_exe = b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = "package" }, exe_name);
        b.step("package", "RDC.exe for a release in zig-out/package").dependOn(&install_exe.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run rdc").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests of the pure modules");
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addOptions("build_options", options);
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Release tool (signing and manifest) — for the machine running the build.
    const release_tool = b.addExecutable(.{ .name = "rdc-release", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/release.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });

    if (is_macos) {
        // Info.plist with the version from build.zig.zon.
        const plist_text = std.mem.replaceOwned(u8, b.allocator, @embedFile("macos/Info.plist"), "@VERSION@", version) catch @panic("OOM");
        const plist_file = b.addWriteFiles().add("Info.plist", plist_text);
        const plist = b.addInstallFileWithDir(plist_file, .{ .custom = "RDC.app/Contents" }, "Info.plist");
        const icon = b.addInstallFileWithDir(b.path("macos/RDC.icns"), .{ .custom = "RDC.app/Contents/Resources" }, "RDC.icns");
        const bin = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "RDC.app/Contents/MacOS" } } });

        // "-" means ad-hoc signing. By default macOS recognizes such a build by its code hash,
        // which changes with every rebuild, so the Screen Recording and
        // Accessibility permissions get lost. An explicit "by identifier" requirement
        // keeps RDC recognizable across builds and updates. With a certificate: -Dsign="RDC Dev".
        const identity = b.option([]const u8, "sign", "RDC.app signing identity: '-' (ad-hoc) or a certificate name") orelse "-";
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", identity, "--identifier", "com.anods.rdc" });
        if (std.mem.eql(u8, identity, "-")) sign.addArgs(&.{ "--requirements", "=designated => identifier \"com.anods.rdc\"" });
        sign.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
        sign.has_side_effects = true;
        sign.step.dependOn(&plist.step);
        sign.step.dependOn(&icon.step);
        sign.step.dependOn(&bin.step);
        b.step("app", "Build zig-out/RDC.app").dependOn(&sign.step);

        const open = b.addSystemCommand(&.{ "open", "-n" });
        open.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
        open.has_side_effects = true;
        open.step.dependOn(&sign.step);
        b.step("run-app", "Build and open RDC.app").dependOn(&open.step);

        // Release archive → zig-out/package/RDC-<version>-<platform>.zip.
        const zip = b.addSystemCommand(&.{ "/usr/bin/ditto", "-c", "-k", "--keepParent" });
        zip.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
        const archive_name = b.fmt("RDC-{s}-{s}.zip", .{ version, platform });
        const archive = zip.addOutputFileArg(archive_name);
        zip.has_side_effects = true;
        zip.step.dependOn(&sign.step);
        const install_archive = b.addInstallFileWithDir(archive, .{ .custom = "package" }, archive_name);
        b.step("package", "RDC release archive in zig-out/package").dependOn(&install_archive.step);

        // The whole release on this machine: archive + signed latest.json → zig-out/release/.
        // Signing key: RDC_UPDATE_KEY or ~/.config/rdc/update-signing.key.
        const manifest = b.addRunArtifact(release_tool);
        manifest.addArgs(&.{ "manifest", version });
        const out_dir = manifest.addOutputDirectoryArg("release");
        if (b.option([]const u8, "notes", "Release notes file")) |notes| manifest.addFileArg(b.path(notes)) else manifest.addArg("-");
        manifest.addPrefixedFileArg(b.fmt("{s}=", .{platform}), archive);
        manifest.has_side_effects = true;
        const install_release = b.addInstallDirectory(.{ .source_dir = out_dir, .install_dir = .prefix, .install_subdir = "release" });
        b.step("release", "GitHub release: RDC archive, latest.json and its signature in zig-out/release").dependOn(&install_release.step);
    }
}
