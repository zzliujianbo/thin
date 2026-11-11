test {
    _ = protocol;
    _ = json;
    _ = sse;
    _ = llm;
    _ = config;
    _ = context;
    _ = session_context;
    _ = runtime;
    _ = image;
    _ = http;
    _ = chat;
    _ = responses;
    _ = anthropic;
    _ = process;
    _ = filesystem;
    _ = @import("tests/filesystem_portability_test.zig");
    _ = memory;
    _ = @import("core/diagnostics.zig");
    _ = @import("core/knowledge.zig");
    _ = @import("core/knowledge_codec.zig");
    _ = @import("tools/knowledge_store.zig");
    _ = @import("app/memory_client.zig");
    _ = @import("app/memory_service_test.zig");
    _ = @import("app/memory_app_test.zig");
    _ = @import("tests/automatic_memory_runtime_test.zig");
    _ = tools;
    _ = presentation;
    _ = daemon;
    // daemon 子模块只在运行时按需 @import；显式引用它们，让真实的安全边界、
    // codec、RPC、spawn/supervisor/worker 与 session host/client 测试进入 test-unit。
    _ = @import("daemon/unix.zig");
    _ = @import("daemon/protocol.zig");
    _ = @import("daemon/registry.zig");
    _ = @import("daemon/spawn.zig");
    if (@import("builtin").os.tag == .linux) {
        _ = @import("daemon/supervisor.zig");
        _ = @import("daemon/ssh.zig");
    }
    // These modules are otherwise reached only through transitive imports;
    // reference them explicitly so filtered test-unit groups always enumerate
    // every top-level test prefix.
    _ = @import("core/systemone.zig");
    _ = @import("core/subagent_status.zig");
    _ = @import("llm/image_codec.zig");
    _ = @import("platform/anonymous_input.zig");
    _ = @import("platform/filesystem_native.zig");
    _ = @import("platform/interrupt.zig");
    _ = @import("platform/metadata.zig");
    _ = @import("platform/posix_terminal.zig");
    _ = @import("platform/spawn.zig");
    _ = @import("platform/terminal_abi.zig");
    _ = @import("platform/terminal_remote.zig");
    _ = @import("platform/wakeup.zig");
    _ = @import("platform/capabilities.zig");
    _ = @import("daemon/worker.zig");
    _ = @import("daemon/client.zig");
    _ = @import("app/session_host.zig");
    _ = @import("ui/session_client.zig");

    _ = @import("tests/tools_integration_test.zig");
    _ = @import("tests/headless_integration_test.zig");

    _ = @import("app/cli.zig");
    _ = @import("main.zig");
    _ = @import("app/auth_store.zig");
    _ = @import("core/codex_auth.zig");
    _ = @import("core/codex_login.zig");
    _ = @import("app/codex_device.zig");
    _ = @import("app/codex_oauth.zig");
    _ = @import("app/app.zig");
    _ = @import("app/model_resolver.zig");
    _ = @import("app/model_metadata.zig");
    _ = @import("app/provider_catalog.zig");
    _ = @import("app/json_bound.zig");
    _ = @import("app/models_dev.zig");
    _ = @import("core/providers.zig");
    _ = @import("app/log_store.zig");
    _ = @import("app/selection.zig");
    _ = @import("app/resume_codec.zig");
    _ = @import("app/resume_store.zig");
    _ = @import("app/resume_command.zig");
    _ = @import("core/checkpoint.zig");
    _ = @import("app/journal.zig");
    _ = @import("app/session.zig");
    _ = @import("tests/settings_session_test.zig");
    _ = @import("tests/selection_defaults_test.zig");
    _ = @import("tests/thinking_contract_test.zig");
    _ = @import("tests/context_usage_test.zig");
    _ = @import("core/subagent.zig");
    _ = @import("core/subagent_test.zig");
    _ = @import("core/background.zig");
    _ = @import("tests/background_service_test.zig");
    _ = @import("tests/app_background_test.zig");
    _ = @import("tools/subagent_tool_test.zig");
    _ = @import("tests/subagent_service_test.zig");
    _ = @import("tests/subagent_app_test.zig");
    _ = @import("tests/output_budget_test.zig");
    _ = @import("tests/compaction_policy_test.zig");
    _ = @import("tests/input_budget_test.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/input.zig");
    _ = @import("ui/input_history.zig");
    _ = @import("core/session_failure.zig");
    _ = @import("util/stream_text.zig");
    _ = @import("ui/body_stream.zig");
    _ = @import("ui/whitelist.zig");
    _ = @import("ui/whitelist_render.zig");
    _ = @import("ui/markdown_writer.zig");
    _ = @import("ui/markdown.zig");
    _ = @import("ui/tail_frame.zig");
    _ = @import("ui/stream_prefix.zig");
    _ = @import("ui/startup.zig");
    _ = @import("tests/markdown_colors_test.zig");
    _ = @import("ui/bridge.zig");
    _ = @import("ui/command_menu.zig");
    _ = @import("ui/provider_picker.zig");
    _ = @import("tests/ui_bridge_test_root.zig");
    _ = @import("tests/regular_screen.zig");
    _ = @import("ui/tui.zig");

    _ = @import("tests/local_command_test.zig");
    _ = @import("core/inbox.zig");
    _ = @import("tests/steering_runtime_test.zig");
    _ = @import("tests/runtime_test.zig");
    _ = @import("tests/tool_lifecycle_test.zig");
    _ = @import("tests/session_context_test.zig");
    _ = @import("tests/adapter_integration_test.zig");
    _ = @import("tool_metadata_adapter_test.zig");

    // Discovery blocks alone are not evidence that a named test was selected.
    for (@import("builtin").test_functions) |test_fn| {
        if (@import("std").mem.indexOf(u8, test_fn.name, ".test.") != null) return;
    }
    return error.NoMatchingProductTests;
}
