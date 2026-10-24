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
/// 目标平台被限制为 Linux x86_64，其他平台在配置阶段直接 panic。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64)
        @panic("ThinAgent v1 supports Linux x86_64 only");
    const optimize = b.standardOptimizeOption(.{});

    // 可供其他前端直接导入；不链接TTY/libc宽度/Markdown C parser。
    const presentation = b.addModule("presentation", .{
        .root_source_file = b.path("src/presentation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const presentation_tests = b.addTest(.{ .use_llvm = false, .root_module = presentation });
    const run_presentation = b.addRunArtifact(presentation_tests);
    b.step("test-presentation", "Run frontend-neutral presentation tests without terminal or libc").dependOn(&run_presentation.step);

    // 主程序 thin。use_llvm = false 表示使用 Zig 自有后端而非 LLVM。
    const exe = b.addExecutable(.{
        .name = "thin",
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addMarkdown(b, exe.root_module);
    b.installArtifact(exe);

    // `zig build run -- [参数]`：先编译再运行 thin，参数写在 `--` 之后传给程序，类似 cargo run。
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Build and run thin (pass program arguments after --)").dependOn(&run_cmd.step);

    // 单元测试：编译 src/root.zig 的所有 test 块，不依赖网络。
    const unit = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addMarkdown(b, unit.root_module);
    // Test-only parser copy with allocation injection; never linked into thin.
    unit.root_module.addCSourceFile(.{ .file = b.path("src/tests/md4c_fault_test.c"), .flags = &.{"-std=c11"} });
    const run_unit = b.addRunArtifact(unit);
    b.step("test-unit", "Run product unit tests without network or credentials").dependOn(&run_unit.step);

    const memory_tests = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/memory_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_memory = b.addRunArtifact(memory_tests);
    b.step("test-memory", "Run bounded automatic-memory offline regressions").dependOn(&run_memory.step);

    const http_tests = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // HTTP/SSE 测试需要本地 mock 服务：由 Node 脚本启动服务，并把编译好的测试程序作为参数传入。
    const run_http = fixture(b, "node", "tests/product/http_mock.mjs", &.{http_tests}, &.{});
    b.step("test-http", "Run local product HTTP/SSE integration tests (requires Node and OpenSSL)").dependOn(&run_http.step);

    const proxy_tests = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proxy_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_proxy = fixture(b, "node", "tests/product/proxy_mock.mjs", &.{proxy_tests}, &.{});
    b.step("test-proxy", "Run owned allowlisted HTTP CONNECT and destination TLS fixtures").dependOn(&run_proxy.step);

    const systemone_tests = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/systemone_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_systemone = fixture(b, "node", "tests/product/systemone_mock.mjs", &.{systemone_tests}, &.{});
    b.step("test-systemone", "Run owned SystemOne/curl HTTP, proxy and TLS fixtures").dependOn(&run_systemone.step);

    const anthropic_tests = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/anthropic_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
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

    // PTY 验收驱动：独立可执行文件，入口见 src/app_pty_test_root.zig。
    const pty_driver = b.addExecutable(.{
        .name = "thin-app-pty",
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app_pty_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // 应用验收：Node 脚本同时拿到 thin 可执行文件与 PTY 驱动，在隔离环境中运行 CLI 与 PTY 测试。
    const run_app = fixture(b, "node", "tests/product/app_mock.mjs", &.{ exe, pty_driver }, &.{});
    b.step("test-app", "Run isolated CLI and PTY application acceptance (requires Node)").dependOn(&run_app.step);

    const run_memory_app = fixture(b, "node", "tests/product/memory_auto_mock.mjs", &.{exe}, &.{});
    b.step("test-memory-app", "Run owned loopback automatic-memory CLI lifecycle acceptance").dependOn(&run_memory_app.step);

    // Foreground subagent acceptance: real in-process child Runtime over owned
    // loopback Chat/Responses/Anthropic wires plus default-off and denial cases.
    const run_subagent = fixture(b, "node", "tests/product/subagent_mock.mjs", &.{exe}, &.{});
    b.step("test-subagent", "Run owned-loopback interactive subagent Runtime acceptance").dependOn(&run_subagent.step);

    const run_idle_enter = fixture(b, "python3", "tests/product/idle_enter_mock.py", &.{exe}, &.{});
    b.step("test-idle-enter", "Run owned idle prompt newline PTYs (requires Python 3)").dependOn(&run_idle_enter.step);

    const run_resize = fixture(b, "python3", "tests/product/resize_deferred_mock.py", &.{exe}, &.{});
    b.step("test-resize-deferred", "Run owned deferred resize, animation and fresh-ACK PTY checks").dependOn(&run_resize.step);

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

    // 聚合步骤 `zig build test`：依次挂载所有离线测试（不含需要真实 API 的内容）。
    const test_all = b.step("test", "Run all offline unit, transport, application and foundation tests");
    test_all.dependOn(&run_unit.step);
    test_all.dependOn(&run_memory.step);
    test_all.dependOn(&run_memory_app.step);
    test_all.dependOn(&run_subagent.step);
    test_all.dependOn(&run_presentation.step);
    test_all.dependOn(&run_http.step);
    test_all.dependOn(&run_anthropic.step);
    test_all.dependOn(&run_systemone.step);
    test_all.dependOn(&run_proxy.step);
    test_all.dependOn(&run_app.step);
    test_all.dependOn(&run_idle_enter.step);
    test_all.dependOn(&run_resize.step);
    test_all.dependOn(viewport_step);
    test_all.dependOn(&run_settings.step);
    test_all.dependOn(&run_command.step);
    test_all.dependOn(&run_approval_cancel.step);
    test_all.dependOn(&run_tool_preview.step);
    test_all.dependOn(&run_queued.step);
    test_all.dependOn(&run.step);
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
    run.addFileArg(b.path(script));
    for (artifacts) |artifact| run.addArtifactArg(artifact);
    for (args) |arg| run.addArg(arg);
    run.setCwd(b.path("."));
    return run;
}

/// Vendored CommonMark/GFM parser: builds offline, no system package/runtime
/// library requirement. Zig code keeps using the native backend; C uses zig cc.
fn addMarkdown(b: *std.Build, module: *std.Build.Module) void {
    for ([_][]const u8{ "md4c.c", "entity.c", "abi.c" }) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt("src/vendor/md4c/{s}", .{file})), .flags = &.{"-std=c11"} });
    }
}
