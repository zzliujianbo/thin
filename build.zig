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
    const run_http = b.addSystemCommand(&.{"node"});
    run_http.addFileArg(b.path("tests/product/http_mock.mjs"));
    run_http.addArtifactArg(http_tests);
    run_http.setCwd(b.path("."));
    b.step("test-http", "Run local product HTTP/SSE integration tests (requires Node and OpenSSL)").dependOn(&run_http.step);

    const anthropic_tests = b.addTest(.{
        .use_llvm = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/anthropic_http_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_anthropic = b.addSystemCommand(&.{"node"});
    run_anthropic.addFileArg(b.path("tests/product/anthropic_mock.mjs"));
    run_anthropic.addArtifactArg(anthropic_tests);
    run_anthropic.setCwd(b.path("."));
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
    const run = b.addSystemCommand(&.{"node"});
    run.addFileArg(b.path("tests/probes/runner.mjs"));
    run.addArtifactArg(probes);
    run.setCwd(b.path("."));
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
    const run_app = b.addSystemCommand(&.{"node"});
    run_app.addFileArg(b.path("tests/product/app_mock.mjs"));
    run_app.addArtifactArg(exe);
    run_app.addArtifactArg(pty_driver);
    run_app.setCwd(b.path("."));
    b.step("test-app", "Run isolated CLI and PTY application acceptance (requires Node)").dependOn(&run_app.step);

    // 聚合步骤 `zig build test`：依次挂载所有离线测试（不含需要真实 API 的内容）。
    const test_all = b.step("test", "Run all offline unit, transport, application and foundation tests");
    test_all.dependOn(&run_unit.step);
    test_all.dependOn(&run_presentation.step);
    test_all.dependOn(&run_http.step);
    test_all.dependOn(&run_anthropic.step);
    test_all.dependOn(&run_app.step);
    test_all.dependOn(&run.step);
}

/// Vendored CommonMark/GFM parser: builds offline, no system package/runtime
/// library requirement. Zig code keeps using the native backend; C uses zig cc.
fn addMarkdown(b: *std.Build, module: *std.Build.Module) void {
    for ([_][]const u8{ "md4c.c", "entity.c", "abi.c" }) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt("src/vendor/md4c/{s}", .{file})), .flags = &.{"-std=c11"} });
    }
}
