//! ThinAgent 的构建脚本：定义 thin 可执行文件、各类测试步骤（test-unit/test-http/test-probes/test-app）及聚合的 test 步骤。
const std = @import("std");
const builtin = @import("builtin");

// 编译期版本检查：项目只能用 Zig 0.17.0 构建，避免在其他版本上出现难以理解的 API 错误。
comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 17 or v.patch != 0)
        @compileError("ThinAgent requires Zig 0.17.0");
}

/// 构建图入口（由 `zig build` 调用）。
/// Linux 保留完整能力；macOS 只构建本地模式，platform-tests-only 仍不安装产品。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform_only = b.option(bool, "platform-tests-only", "Only independent platform tests; no product executable") orelse false;
    const platform_llvm = target.result.os.tag == .macos;
    // Only Linux terminal/product targets need the existing SSH C transport.
    // Darwin local-terminal tests never compile SSH or require libssh.
    const ssh_include = if (target.result.os.tag == .linux) b.option([]const u8, "ssh-include", "Directory containing libssh/ headers") else null;
    const ssh_library = if (target.result.os.tag == .linux) b.option([]const u8, "ssh-library", "Absolute libssh shared-library path (otherwise link system ssh)") else null;

    // 可供其他前端直接导入；不链接 TTY 或 libc 宽度实现。
    _ = b.addModule("presentation", .{
        .root_source_file = b.path("src/presentation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const all = compose(b, "all");
    const presentation_tests = b.addTest(.{ .use_llvm = platform_llvm, .root_module = b.createModule(.{
        .root_source_file = all.path(b, "src/presentation.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    presentation_tests.step.dependOn(&all.run.step);
    const run_presentation = runTest(b, presentation_tests);
    b.step("test-presentation", "Run frontend-neutral presentation tests without terminal or libc").dependOn(&run_presentation.step);

    const filesystem_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/filesystem_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    filesystem_tests.step.dependOn(&all.run.step);
    b.step("test-filesystem", "Run POSIX file, auth, checkpoint and Memory regressions without SSH or TTY").dependOn(&runTest(b, filesystem_tests).step);

    const terminal_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/terminal_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    terminal_tests.step.dependOn(&all.run.step);
    addRuntime(b, terminal_tests.root_module, ssh_include, ssh_library);
    const terminal_headers = b.addExecutable(.{
        .name = "thin-terminal-sdk-probe",
        .use_llvm = true,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    terminal_headers.root_module.addCSourceFile(.{
        .file = b.path("tests/macos/terminal_abi_probe.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    const terminal_step = b.step("test-terminal", "Run owned PTY, locale, wakeup and libc-header ABI checks");
    terminal_step.dependOn(&runTest(b, terminal_tests).step);
    terminal_step.dependOn(&runTest(b, terminal_headers).step);
    for ([_]*std.Build.Step.Compile{ presentation_tests, filesystem_tests, terminal_tests, terminal_headers }) |artifact| configureStack(artifact);

    if (platform_only) {
        // Do not let `zig build -Dplatform-tests-only=true` look like a successful
        // product installation. Only explicit test steps are valid in this mode.
        const no_product = b.addFail("platform-tests-only does not build thin; select test-filesystem, test-terminal or test-presentation");
        b.getInstallStep().dependOn(&no_product.step);
        b.step("run", "Product unavailable in platform-tests-only mode").dependOn(&no_product.step);
        return;
    }
    const supported = (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) or
        (target.result.os.tag == .macos and (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64));
    if (!supported) @panic("ThinAgent supports Linux x86_64 and macOS x86_64/aarch64");

    // Darwin 使用 LLVM；Linux 保留原后端。
    const exe = b.addExecutable(.{
        .name = "thin",
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addRuntime(b, exe.root_module, ssh_include, ssh_library);
    b.installArtifact(exe);
    b.step("check", "Compile the product without installing or running it").dependOn(&exe.step);

    // `zig build run -- [参数]`：先编译再运行 thin，参数写在 `--` 之后传给程序，类似 cargo run。
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Build and run thin (pass program arguments after --)").dependOn(&run_cmd.step);

    // 单元测试：编译 src/root.zig 的所有 test 块，不依赖网络。
    const unit = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit.step.dependOn(&all.run.step);
    addRuntime(b, unit.root_module, ssh_include, ssh_library);
    const run_unit = runTest(b, unit);
    b.step("test-unit-full", "Run the complete unit suite in one process").dependOn(&run_unit.step);

    b.step("test-unit", "Run the complete unit suite in one process").dependOn(&run_unit.step);
    const sharded = b.step("test-unit-sharded", "Run Linux unit owner shards with standard runners");
    if (target.result.os.tag != .linux)
        sharded.dependOn(&b.addFail("test-unit-sharded is Linux-only; use test-fast or test-unit-full on macOS").step);
    const shard_inventory: ?*std.Build.Step.Run = if (target.result.os.tag == .linux) guard: {
        const guard = b.addSystemCommand(&.{"python3"});
        guard.addFileArg(b.path("tests/tools/verify_shards.py"));
        guard.addArg("--full");
        guard.addArtifactArg(unit);
        guard.has_side_effects = true;
        guard.setCwd(b.path("."));
        break :guard guard;
    } else null;
    for ([_][]const u8{ "fast", "ui", "app", "core", "integration", "daemon" }) |group| {
        const variant = compose(b, group);
        const grouped = b.addTest(.{ .use_llvm = platform_llvm, .root_module = b.createModule(.{
            .root_source_file = variant.path(b, "src/__test_group_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        grouped.step.dependOn(&variant.run.step);
        if (!std.mem.eql(u8, group, "fast")) addRuntime(b, grouped.root_module, ssh_include, ssh_library);
        configureStack(grouped);
        const name = if (std.mem.eql(u8, group, "fast")) "test-fast" else b.fmt("test-unit-{s}", .{group});
        const run_group = runTest(b, grouped);
        run_group.step.name = b.fmt("run test [{s}]", .{group});
        const group_step = b.step(name, b.fmt("Run the {s} test selection", .{group}));
        if (std.mem.eql(u8, group, "daemon") and target.result.os.tag != .linux) {
            group_step.dependOn(&b.addFail("test-unit-daemon is Linux-only").step);
        } else group_step.dependOn(&run_group.step);
        if (shard_inventory) |guard| {
            guard.addArgs(&.{ "--shard", group });
            guard.addArtifactArg(grouped);
            // Keep inventory/full compilation local to the sharded entry;
            // individual owner runs must remain independent and lightweight.
            const guarded_run = runTest(b, grouped);
            guarded_run.step.name = b.fmt("run test [{s}]", .{group});
            guarded_run.step.dependOn(&guard.step);
            sharded.dependOn(&guarded_run.step);
        }
    }

    // Filters belong to separate compile artifacts, never to the full unit suite.
    const focus_filter = b.option([]const u8, "test-filter", "Nonempty substring for test-focus");
    const focus_step = b.step("test-focus", "Run unit tests matching -Dtest-filter");
    if (focus_filter) |filter| {
        if (std.mem.trim(u8, filter, " \t\r\n").len != 0) {
            const focused = b.addTest(.{ .use_llvm = platform_llvm, .root_module = unit.root_module, .filters = &.{filter} });
            configureStack(focused);
            focused.step.dependOn(&all.run.step);
            focus_step.dependOn(&runTest(b, focused).step);
        } else focus_step.dependOn(&b.addFail("test-focus requires a nonempty -Dtest-filter").step);
    } else focus_step.dependOn(&b.addFail("test-focus requires a nonempty -Dtest-filter").step);
    const rendering = b.addTest(.{ .use_llvm = platform_llvm, .root_module = unit.root_module, .filters = &.{ "ui.", "util.display_text." } });
    rendering.step.dependOn(&all.run.step);
    b.step("test-render", "Run rendering-related unit tests").dependOn(&runTest(b, rendering).step);

    const memory_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/memory_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    memory_tests.step.dependOn(&all.run.step);
    addNative(b, memory_tests.root_module);
    const run_memory = runTest(b, memory_tests);
    b.step("test-memory", "Run bounded automatic-memory offline regressions").dependOn(&run_memory.step);

    const http_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    http_tests.step.dependOn(&all.run.step);
    addNative(b, http_tests.root_module);
    // HTTP/SSE 测试需要本地 mock 服务：由 Node 脚本启动服务，并把编译好的测试程序作为参数传入。
    const run_http = fixture(b, "node", "tests/product/http_mock.mjs", &.{http_tests}, &.{});
    b.step("test-http", "Run local product HTTP/SSE integration tests (requires Node and OpenSSL)").dependOn(&run_http.step);

    const proxy_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/proxy_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    proxy_tests.step.dependOn(&all.run.step);
    addNative(b, proxy_tests.root_module);
    const run_proxy = fixture(b, "node", "tests/product/proxy_mock.mjs", &.{proxy_tests}, &.{});
    b.step("test-proxy", "Run owned allowlisted HTTP CONNECT and destination TLS fixtures").dependOn(&run_proxy.step);

    const systemone_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/systemone_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    systemone_tests.step.dependOn(&all.run.step);
    addNative(b, systemone_tests.root_module);
    const run_systemone = fixture(b, "node", "tests/product/systemone_mock.mjs", &.{systemone_tests}, &.{});
    b.step("test-systemone", "Run owned SystemOne/curl HTTP, proxy and TLS fixtures").dependOn(&run_systemone.step);

    const anthropic_tests = b.addTest(.{
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = all.path(b, "src/anthropic_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    anthropic_tests.step.dependOn(&all.run.step);
    addNative(b, anthropic_tests.root_module);
    const run_anthropic = fixture(b, "node", "tests/product/anthropic_mock.mjs", &.{anthropic_tests}, &.{});
    b.step("test-anthropic", "Run isolated Anthropic Messages HTTP/SSE fixtures").dependOn(&run_anthropic.step);

    // 终端 ABI 模块（libc termios 结构体布局）单独成模块，供 probes 测试导入。
    const terminal_abi = b.createModule(.{ .root_source_file = b.path("src/platform/terminal_abi.zig"), .target = target, .optimize = optimize, .link_libc = true });

    const probes = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/probes.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "terminal_abi", .module = terminal_abi }},
        }),
    });

    // 探针测试：由 Node runner 调度，验证 Linux I/O 行为（需要 OpenSSL）。
    const run = fixture(b, "node", "tests/probes/runner.mjs", &.{probes}, &.{});
    b.step("test-probes", "Run local Linux I/O probes (requires Node and OpenSSL)").dependOn(&run.step);

    // PTY 验收驱动只恢复测试辅助声明。
    const driver = compose(b, "driver");
    const pty_driver = b.addExecutable(.{
        .name = "thin-app-pty",
        .use_llvm = platform_llvm,
        .root_module = b.createModule(.{
            .root_source_file = driver.path(b, "src/app_pty_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    pty_driver.step.dependOn(&driver.run.step);
    addRuntime(b, pty_driver.root_module, ssh_include, ssh_library);

    const run_ssh = fixture(b, "python3", "tests/product/ssh_mock.py", &.{exe}, &.{});
    const ssh_step = b.step("test-ssh", "Run Linux SSH/TUI/key/lifecycle acceptance (requires OpenSSH)");
    if (target.result.os.tag == .linux) ssh_step.dependOn(&run_ssh.step) else ssh_step.dependOn(&b.addFail("SSH is unsupported in the macOS local build").step);

    // 应用验收：Node 脚本同时拿到 thin 可执行文件与 PTY 驱动，在隔离环境中运行 CLI 与 PTY 测试。
    const run_app = fixture(b, "node", "tests/product/app_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-app", "Run isolated CLI and PTY application acceptance (requires Node)").dependOn(&run_app.step);
    const run_streaming = fixture(b, "node", "tests/product/app_mock.mjs", &.{ exe, pty_driver }, &.{"--streaming-only"});
    b.step("test-streaming", "Run focused streaming Markdown and history PTY acceptance").dependOn(&run_streaming.step);

    const run_memory_app = fixture(b, "node", "tests/product/memory_auto_mock.mjs", &.{exe}, &.{});
    b.step("test-memory-app", "Run owned loopback automatic-memory CLI lifecycle acceptance").dependOn(&run_memory_app.step);

    // Foreground subagent acceptance: real in-process child Runtime over owned
    // loopback Chat/Responses/Anthropic wires plus denial cases.
    const run_subagent = fixture(b, "node", "tests/product/subagent_mock.mjs", &.{exe}, &.{});
    b.step("test-subagent", "Run owned-loopback interactive subagent Runtime acceptance").dependOn(&run_subagent.step);

    // Instance-owned background services: owned loopback plus a real PTY, so
    // cross-task keep-alive is proven in one App instance (--print exits must
    // clear every service, which is the correct headless semantic).
    const run_background = fixture(b, "python3", "tests/product/background_mock.py", &.{exe}, &.{});
    b.step("test-background", "Run owned-loopback background service lifecycle and cross-task acceptance").dependOn(&run_background.step);

    // Daemon/attach/takeover acceptance over owned loopback and a real PTY.
    const run_daemon = fixture(b, "python3", "tests/product/daemon_mock.py", &.{exe}, &.{});
    const daemon_step = b.step("test-daemon", "Run Linux daemon/attach/takeover/approval/SIGTERM acceptance");
    if (target.result.os.tag == .linux) daemon_step.dependOn(&run_daemon.step) else daemon_step.dependOn(&b.addFail("Persistent daemon is unsupported in the macOS local build").step);
    const run_subscription = fixture(b, "python3", "tests/product/subscription_mock.py", &.{exe}, &.{});
    b.step("test-subscription", "Run owned push-stream binding, watermark and slow-reader acceptance").dependOn(&run_subscription.step);

    const run_idle_enter = fixture(b, "python3", "tests/product/idle_enter_mock.py", &.{exe}, &.{});
    b.step("test-idle-enter", "Run owned idle prompt newline PTYs (requires Python 3)").dependOn(&run_idle_enter.step);
    const run_resume_menu = fixture(b, "python3", "tests/product/resume_menu_mock.py", &.{exe}, &.{});
    b.step("test-resume-menu", "Run owned saved-session menu and continuation PTYs").dependOn(&run_resume_menu.step);

    const run_memory_background = fixture(b, "python3", "tests/product/memory_background_mock.py", &.{exe}, &.{});
    b.step("test-memory-background", "Run owned PTY background Memory status and lifecycle acceptance").dependOn(&run_memory_background.step);

    const run_resize = fixture(b, "python3", "tests/product/resize_deferred_mock.py", &.{exe}, &.{});
    b.step("test-resize-deferred", "Run owned passive size/safety, ACK invalidation and stream-resume PTY checks (no auto repair)").dependOn(&run_resize.step);

    const viewport_step = b.step("test-resize-viewport", "Run owned tmux viewport, multiline composer and local-command lifecycle checks");
    // Same script and artifacts; only the viewport mode differs.
    const viewport_modes = [_][]const []const u8{ &.{}, &.{"--wrap"}, &.{"--local-command"} };
    for (&viewport_modes) |mode| {
        const run_viewport = fixture(b, "python3", "tests/product/resize_viewport_mock.py", &.{exe}, mode);
        viewport_step.dependOn(&run_viewport.step);
    }

    // Global settings acceptance reuses both application artifacts; the Node
    // fixture owns its loopback server and serial PTY launches.
    const run_settings = fixture(b, "node", "tests/product/global_settings_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-settings", "Run isolated global settings PTY acceptance without inference").dependOn(&run_settings.step);

    // Focused image group; normal test-app also includes it exactly once.
    const run_image = fixture(b, "node", "tests/product/app_mock.mjs", &.{ exe, pty_driver }, &.{"--image-model-only"});
    b.step("test-image", "Run owned local-image HTTP and Settings PTY acceptance").dependOn(&run_image.step);

    const run_command = fixture(b, "node", "tests/product/local_command_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-command", "Run owned local-command approval, denial, cancellation and timeout PTYs").dependOn(&run_command.step);

    const run_approval_cancel = fixture(b, "node", "tests/product/approval_cancel_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-approval-cancel", "Run owned long-approval Escape context-restoration PTY").dependOn(&run_approval_cancel.step);

    const run_tool_preview = fixture(b, "node", "tests/product/tool_preview_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-tool-preview", "Run gated owned tool-preview streaming and cancellation PTYs").dependOn(&run_tool_preview.step);

    const run_tool_presentation = fixture(b, "node", "tests/product/app_mock.mjs", &.{ exe, pty_driver }, &.{"--tool-presentation-only"});
    b.step("test-tool-presentation", "Run owned tool animation, result rows, file counts and Memory captions").dependOn(&run_tool_presentation.step);

    const run_queued = fixture(b, "node", "tests/product/steering_followup_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-queued", "Run owned steering, follow-up, withdrawal and stop-clear confirmation PTYs").dependOn(&run_queued.step);

    const interaction = b.step("test-interaction", "Run selected interaction PTY fixtures");
    interaction.dependOn(&run_idle_enter.step);
    interaction.dependOn(&run_resume_menu.step);
    interaction.dependOn(&run_resize.step);
    interaction.dependOn(viewport_step);
    interaction.dependOn(&run_approval_cancel.step);
    interaction.dependOn(&run_command.step);
    const communication = b.step("test-communication", "Run subscription, daemon and SSH fixtures");
    if (target.result.os.tag == .linux) {
        const communication_daemon = fixture(b, "python3", "tests/product/daemon_mock.py", &.{exe}, &.{});
        communication_daemon.step.dependOn(&run_subscription.step);
        communication_daemon.step.dependOn(&run_ssh.step);
        communication.dependOn(&communication_daemon.step);
    } else communication.dependOn(&b.addFail("Daemon/SSH communication fixtures are Linux-only").step);

    // Root-level offline tooling selftests are part of the complete gate.
    const workflow_tests = b.addSystemCommand(&.{ "python3", "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py" });
    workflow_tests.has_side_effects = true;
    // 聚合步骤 `zig build test`：依次挂载所有离线测试（不含需要真实 API 的内容）。
    const test_all = b.step("test", "Run all offline unit, transport, application and foundation tests");
    // Isolate the daemon latency gate only within this entry. Individual
    // targets retain their own lightweight graph, without global scheduling.
    const full_prerequisites = if (target.result.os.tag == .linux) gate: {
        const full_daemon = fixture(b, "python3", "tests/product/daemon_mock.py", &.{exe}, &.{});
        test_all.dependOn(&full_daemon.step);
        break :gate &full_daemon.step;
    } else test_all;
    full_prerequisites.dependOn(&workflow_tests.step);
    full_prerequisites.dependOn(&run_unit.step);
    full_prerequisites.dependOn(&run_memory.step);
    full_prerequisites.dependOn(&run_memory_app.step);
    full_prerequisites.dependOn(&run_background.step);
    if (target.result.os.tag == .linux) {
        full_prerequisites.dependOn(&run_subscription.step);
        full_prerequisites.dependOn(&run_ssh.step);
        full_prerequisites.dependOn(&run_subagent.step);
        full_prerequisites.dependOn(&run.step);
    }
    full_prerequisites.dependOn(&run_presentation.step);
    if (target.result.os.tag == .linux) {
        full_prerequisites.dependOn(&run_http.step);
        full_prerequisites.dependOn(&run_anthropic.step);
        full_prerequisites.dependOn(&run_systemone.step);
        full_prerequisites.dependOn(&run_proxy.step);
    }
    full_prerequisites.dependOn(&run_app.step);
    full_prerequisites.dependOn(&run_idle_enter.step);
    full_prerequisites.dependOn(&run_resume_menu.step);
    full_prerequisites.dependOn(&run_memory_background.step);
    full_prerequisites.dependOn(&run_resize.step);
    full_prerequisites.dependOn(viewport_step);
    full_prerequisites.dependOn(&run_settings.step);
    full_prerequisites.dependOn(&run_command.step);
    full_prerequisites.dependOn(&run_approval_cancel.step);
    full_prerequisites.dependOn(&run_tool_preview.step);
    full_prerequisites.dependOn(&run_queued.step);
    for ([_]*std.Build.Step.Compile{ exe, unit, rendering, memory_tests, http_tests, proxy_tests, systemone_tests, anthropic_tests, probes, pty_driver }) |artifact| configureStack(artifact);
}

const Composed = struct {
    run: *std.Build.Step.Run,
    directory: std.Build.LazyPath,

    fn path(self: Composed, b: *std.Build, name: []const u8) std.Build.LazyPath {
        return self.directory.path(b, name);
    }
};

fn compose(b: *std.Build, group: []const u8) Composed {
    const project_root = b.root.root_dir.handle.realPathFileAlloc(b.graph.io, if (b.root.sub_path.len == 0) "." else b.root.sub_path, b.allocator) catch @panic("cannot canonicalize test project root");
    const project_id = std.hash.Wyhash.hash(0, project_root);
    const directory = std.Build.LazyPath.cache_root.path(b, b.fmt("generated-tests/{x}/{s}", .{ project_id, group }));
    const run = b.addSystemCommand(&.{ "python3", "tests/tools/compose.py", "--layout", "tests/layout.json", "--out" });
    run.addDirectoryArg(directory);
    run.addArgs(&.{ "--group", group });
    run.setCwd(b.path("."));
    // Dynamic manifest and source inputs are read on every invocation. The
    // composer writes only changed files, preserving compiler cache hits.
    run.has_side_effects = true;
    return .{ .run = run, .directory = directory };
}

fn runTest(b: *std.Build, artifact: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    // Reuse compiled binaries, not prior test results.
    run.has_side_effects = true;
    return run;
}

fn configureStack(artifact: *std.Build.Step.Compile) void {
    // LLVM Debug keeps multiple bounded metadata/Session copies alive in a
    // frame; reserve a consistent Darwin main stack instead of overflowing
    // the default during checkpoint/model-catalog operations. Pages commit
    // on demand. Linux keeps its existing backend and stack policy.
    if (artifact.root_module.resolved_target.?.result.os.tag == .macos)
        artifact.stack_size = 32 * 1024 * 1024;
}

/// One owned-fixture runner: a Node/Python entry script launched from the repo
/// root, then the built artifacts, then any mode flags. Order matters because
/// the fixtures read argv positionally.
fn fixture(
    b: *std.Build,
    runner: []const u8,
    script: []const u8,
    artifacts: []const *std.Build.Step.Compile,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{runner});
    run.has_side_effects = true;
    run.addFileArg(b.path(script));
    for (artifacts) |artifact| run.addArtifactArg(artifact);
    for (args) |arg| run.addArg(arg);
    run.setCwd(b.path("."));
    return run;
}

fn addRuntime(b: *std.Build, module: *std.Build.Module, include: ?[]const u8, library: ?[]const u8) void {
    if (module.resolved_target.?.result.os.tag == .linux) {
        addSsh(b, module, include, library);
    } else {
        addNative(b, module);
    }
}

fn addNative(b: *std.Build, module: *std.Build.Module) void {
    if (module.resolved_target.?.result.os.tag != .macos) return;
    for ([_][]const u8{ "darwin_process.c", "darwin_ipc.c" }) |file| {
        module.addCSourceFile(.{
            .file = b.path(b.fmt("src/platform/{s}", .{file})),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
    }
}

fn addSsh(b: *std.Build, module: *std.Build.Module, include: ?[]const u8, library: ?[]const u8) void {
    if (include) |path| module.addSystemIncludePath(.{ .cwd_relative = path });
    for ([_][]const u8{ "ssh_keys.c", "ssh_transport.c" }) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt("src/daemon/{s}", .{file})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    }
    if (library) |path| module.addObjectFile(.{ .cwd_relative = path }) else module.linkSystemLibrary("ssh", .{});
}
