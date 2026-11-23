//! zig build                         dev build (console logs, devtools); the page from out/renderer
//!                                   (or VIBE_DEV_URL=http://localhost:5173 for vite)
//! zig build -Doptimize=ReleaseFast  the installed app
//! zig build run                     build and start it
//! zig build test                    unit tests
//!
//! `npm run build:web` first: the renderer in ../out/renderer is embedded in the executable.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const renderer = b.option([]const u8, "renderer", "folder of the built pages (default ../out/renderer)") orelse "../out/renderer";
    const version = b.option([]const u8, "version", "app version") orelse "0.2.36";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "only", b.option([]const u8, "only", "comma-separated modules to compile (default: all)") orelse "");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    mod.addImport("assets", try assetsModule(b, renderer));
    mod.addAnonymousImport("tray.png", .{ .root_source_file = b.path("../resources/tray.png") });
    mod.addAnonymousImport("icon.png", .{ .root_source_file = b.path("../resources/icon.png") });

    // SQLite (Chrome history import, the Web tab's own history)
    const sqlite = b.dependency("sqlite", .{});
    mod.addIncludePath(sqlite.path("."));
    mod.addImport("sqlite", b.addTranslateC(.{ .root_source_file = sqlite.path("sqlite3.h"), .target = target, .optimize = optimize }).createModule());
    mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=2", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_USE_ALLOCA", "-fno-sanitize=undefined" },
    });

    if (os == .windows) {
        const tc = b.addTranslateC(.{ .root_source_file = b.path("src/host/win/c.h"), .target = target, .optimize = optimize });
        tc.addIncludePath(b.path("vendor/webview2"));
        mod.addImport("win", tc.createModule());
        mod.addWin32ResourceFile(.{ .file = b.path("app.rc") });
        for ([_][]const u8{ "ole32", "oleaut32", "user32", "gdi32", "shell32", "shlwapi", "advapi32", "dwmapi", "uxtheme", "comctl32", "shcore", "crypt32", "ws2_32", "bcrypt", "version", "uiautomationcore", "windowscodecs", "winmm", "pdh", "powrprof" }) |lib|
            mod.linkSystemLibrary(lib, .{});
    } else if (os == .macos) {
        if (b.lazyDependency("zig_objc", .{ .target = target, .optimize = optimize })) |objc|
            mod.addImport("objc", objc.module("objc"));
        for ([_][]const u8{ "AppKit", "WebKit", "Foundation", "CoreGraphics", "Carbon", "ServiceManagement", "UserNotifications", "Security" }) |fw|
            mod.linkFramework(fw, .{});
    }

    if (os == .windows) {
        // the equalizer APO that audiodg.exe loads (src/audio.zig installs it): always optimized
        // and without safety checks, a panic there would cut the machine's sound
        const apo = b.addLibrary(.{
            .name = "vibe-eq-apo",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("apo/eq_apo.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .strip = true,
            }),
        });
        apo.root_module.linkSystemLibrary("ole32", .{});
        mod.addAnonymousImport("vibe-eq-apo.dll", .{ .root_source_file = apo.getEmittedBin() });
        b.step("apo", "build the equalizer APO dll").dependOn(&b.addInstallArtifact(apo, .{}).step);
        const apo_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("apo/dsp.zig"), .target = target, .optimize = optimize }) });
        b.step("test-apo", "equalizer DSP tests").dependOn(&b.addRunArtifact(apo_tests).step);
        const harness = b.addExecutable(.{ .name = "apo-harness", .root_module = b.createModule(.{ .root_source_file = b.path("apo/harness.zig"), .target = target, .optimize = .Debug }) });
        const hrun = b.addRunArtifact(harness);
        hrun.addFileArg(apo.getEmittedBin());
        b.step("apo-check", "load the APO dll like the audio engine and run audio through it").dependOn(&hrun.step);
    }

    const exe = b.addExecutable(.{ .name = "vibe-code", .root_module = mod });
    if (os == .windows and optimize != .debug) exe.subsystem = .windows;
    b.installArtifact(exe);

    if (os == .windows) {
        const arch = if (target.result.cpu.arch == .aarch64) "arm64" else "x64";
        b.getInstallStep().dependOn(&b.addInstallBinFile(b.path(b.fmt("vendor/webview2/{s}/WebView2Loader.dll", .{arch})), "WebView2Loader.dll").step);
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "start the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "unit tests").dependOn(&b.addRunArtifact(tests).step);

    // compile only (no linking): what `zig build check -Dtarget=aarch64-macos` uses from Windows
    // (COFF cannot merge sqlite's object into one: on Windows it is the executable, not installed)
    const check = if (os == .windows) b.addExecutable(.{ .name = "check", .root_module = mod }) else b.addObject(.{ .name = "check", .root_module = mod });
    b.step("check", "type-check without linking").dependOn(&check.step);
}

/// The built pages, packed at build time by tools/gen_assets.zig: .
fn assetsModule(b: *std.Build, renderer: []const u8) !*std.Build.Module {
    const gen = b.addExecutable(.{ .name = "gen_assets", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_assets.zig"),
        .target = b.graph.host,
        .optimize = .fast,
    }) });
    const run = b.addRunArtifact(gen);
    // a directory argument is cached by its path, not its files: without this a rebuilt renderer
    // was never repacked and the app shipped the pages of an old build
    run.has_side_effects = true;
    run.addDirectoryArg(b.path(renderer));
    const out = run.addOutputDirectoryArg("assets");
    return b.createModule(.{ .root_source_file = out.path(b, "assets.zig") });
}
