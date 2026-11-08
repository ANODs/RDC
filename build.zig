const std = @import("std");

/// Версия задаётся в одном месте — build.zig.zon; -Dversion=... переопределяет её.
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
    const version = b.option([]const u8, "version", "Версия RDC (по умолчанию из build.zig.zon)") orelse zon.version;
    const os = target.result.os.tag;
    const is_macos = os == .macos;
    // Платформа в манифесте обновлений: macos-arm64, windows-x86_64, linux-x86_64…
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
    if (is_macos) {
        root.addIncludePath(b.path("src/platform/macos"));
        root.addCSourceFile(.{
            .file = b.path("src/platform/macos/shim.m"),
            .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Wno-unused-parameter" },
        });
        const frameworks = [_][]const u8{
            "Foundation",  "AppKit",       "ScreenCaptureKit",    "VideoToolbox", "CoreMedia",
            "CoreVideo",   "CoreGraphics", "ApplicationServices", "IOSurface",
        };
        for (frameworks) |fw| root.linkFramework(fw, .{});
    }

    const exe = b.addExecutable(.{ .name = "rdc", .root_module = root });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Запустить rdc").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Тесты чистых модулей");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Инструмент релизов (подпись и манифест) — для машины, где идёт сборка.
    const release_tool = b.addExecutable(.{ .name = "rdc-release", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/release.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });

    if (is_macos) {
        // Info.plist с версией из build.zig.zon.
        const plist_text = std.mem.replaceOwned(u8, b.allocator, @embedFile("macos/Info.plist"), "@VERSION@", version) catch @panic("OOM");
        const plist_file = b.addWriteFiles().add("Info.plist", plist_text);
        const plist = b.addInstallFileWithDir(plist_file, .{ .custom = "RDC.app/Contents" }, "Info.plist");
        const bin = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "RDC.app/Contents/MacOS" } } });

        // «-» — подпись ad-hoc. По умолчанию macOS узнаёт такую сборку по отпечатку,
        // который меняется при каждой пересборке, и права «Запись экрана» и
        // «Универсальный доступ» слетают. Явное требование «по идентификатору»
        // делает RDC узнаваемым между сборками и обновлениями. С сертификатом: -Dsign="RDC Dev".
        const identity = b.option([]const u8, "sign", "Подпись RDC.app: «-» (ad-hoc) или имя сертификата") orelse "-";
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", identity, "--identifier", "com.anods.rdc" });
        if (std.mem.eql(u8, identity, "-")) sign.addArgs(&.{ "--requirements", "=designated => identifier \"com.anods.rdc\"" });
        sign.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
        sign.has_side_effects = true;
        sign.step.dependOn(&plist.step);
        sign.step.dependOn(&bin.step);
        b.step("app", "Собрать zig-out/RDC.app").dependOn(&sign.step);

        const open = b.addSystemCommand(&.{ "open", "-n" });
        open.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
        open.has_side_effects = true;
        open.step.dependOn(&sign.step);
        b.step("run-app", "Собрать и открыть RDC.app").dependOn(&open.step);

        // Архив для релиза → zig-out/package/RDC-<версия>-<платформа>.zip.
        const zip = b.addSystemCommand(&.{ "/usr/bin/ditto", "-c", "-k", "--keepParent" });
        zip.addDirectoryArg(b.graph.path(.install_prefix, "RDC.app"));
        const archive_name = b.fmt("RDC-{s}-{s}.zip", .{ version, platform });
        const archive = zip.addOutputFileArg(archive_name);
        zip.has_side_effects = true;
        zip.step.dependOn(&sign.step);
        const install_archive = b.addInstallFileWithDir(archive, .{ .custom = "package" }, archive_name);
        b.step("package", "Архив RDC для релиза в zig-out/package").dependOn(&install_archive.step);

        // Релиз целиком на этой машине: архив + подписанный latest.json → zig-out/release/.
        // Ключ подписи — RDC_UPDATE_KEY или ~/.config/rdc/update-signing.key.
        const manifest = b.addRunArtifact(release_tool);
        manifest.addArgs(&.{ "manifest", version });
        const out_dir = manifest.addOutputDirectoryArg("release");
        if (b.option([]const u8, "notes", "Файл с заметками к релизу")) |notes| manifest.addFileArg(b.path(notes)) else manifest.addArg("-");
        manifest.addPrefixedFileArg(b.fmt("{s}=", .{platform}), archive);
        manifest.has_side_effects = true;
        const install_release = b.addInstallDirectory(.{ .source_dir = out_dir, .install_dir = .prefix, .install_subdir = "release" });
        b.step("release", "Релиз для GitHub: архив RDC, latest.json и подпись в zig-out/release").dependOn(&install_release.step);
    }
}
