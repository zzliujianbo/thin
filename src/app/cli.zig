//! 命令行参数解析与帮助文本。只做语法层面的解析，不读取配置或环境。

const std = @import("std");

/// 解析后的选项。prompt 为 null 表示交互模式；非 null 表示 --print 一次性模式。
/// 当前 CLI 默认信任本进程的工具调用，不逐次审批；--trust 仅保留兼容。
/// 这不是命令风险分类或沙箱，Runtime 的授权接口仍保留给嵌入调用方。
pub const Options = struct { prompt: ?[]const u8 = null, trusted: bool = true, logging: bool = true, help: bool = false, version: bool = false };

/// 解析 argv。args[0] 是程序名，因此从 1 开始遍历。
/// 无效参数返回错误（InvalidArguments、UnknownOption），由调用方决定如何提示。
pub fn parse(args: []const [:0]const u8) !Options {
    var result: Options = .{};

    // 使用显式索引循环，以便 --print 能在处理时跳过下一个参数（即 prompt）。
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // --print 要求后面紧跟一个 prompt，且不允许重复指定，避免静默覆盖。
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) result.help = true else if (std.mem.eql(u8, arg, "--version")) result.version = true else if (std.mem.eql(u8, arg, "--trust")) result.trusted = true else if (std.mem.eql(u8, arg, "--no-log")) result.logging = false else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            if (result.prompt != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            result.prompt = args[i];
        } else return error.UnknownOption;
    }

    return result;
}

/// 帮助文本，由 --help 输出。字符串内容即为用户可见的文档。
pub const help =
    \\thin - minimal local agent (Linux x86_64, Zig 0.17.0)
    \\
    \\Usage: thin [--trust] [--no-log]
    \\       thin --print "prompt" [--trust] [--no-log]
    \\       thin --help | --version
    \\
    \\Configuration: ~/.thin/config.json
    \\Interactive startup initializes a missing/empty file for DeepSeek (deepseek-flash).
    \\Use /auth in the TUI for hidden key entry; the key is saved locally with mode 0600.
    \\Never put a key in chat or command arguments. Saving does not send an API request.
    \\Existing nonempty configurations are preserved. Advanced configuration example:
    \\  {"provider":{"base_url":"https://your-provider.example/v1",
    \\    "api_key_env":"THIN_API_KEY"},
    \\   "model":{"name":"your-model","context_tokens":128000,"protocol":"auto"}}
    \\Use either provider.api_key_env (environment variable) or provider.api_key, not both.
    \\--print requires an already configured file; it does not open the setup UI.
    \\Protocols: auto (Responses then one explicitly supported fallback), responses, chat.
    \\Known DeepSeek thinking format selects Chat locally; it never probes Responses.
    \\
    \\Interactive uses regular terminal scrollback, not an alternate full-screen buffer.
    \\Committed output remains after exit; only the live input/status area is redrawn.
    \\Enter sends; Ctrl+J adds newline; Ctrl+C cancels; Ctrl+D exits.
    \\After Ctrl+D and successful terminal restoration, the current session ID is printed.
    \\An ID alone creates no records; --no-log and no-submission exits still have an ID.
    \\PgUp/PgDn scroll; Ctrl+R toggles visible reasoning; Shift+Tab cycles supported effort.
    \\/model opens a searchable picker; /model exact-id selects directly while idle.
    \\Model selection is session-only. Effort is saved per startup project, not globally.
    \\Optional models:[{name,context_tokens,protocol,reasoning_effort,reasoning}] profiles
    \\share the endpoint (maximum 64); a custom ID inherits current context/options.
    \\Logical levels: off/minimal/low/medium/high/xhigh/max; only supported levels cycle.
    \\Legacy none means off. Unknown model capabilities keep fixed configured options.
    \\Custom/proxy models can declare reasoning:{format:"standard",map:{off:"none",high:"high"}}.
    \\A null/missing mapping is unsupported; DeepSeek format uses thinking.type (Chat only).
    \\No model discovery, trial requests or automatic changes to global defaults.
    \\Tool calls are trusted for THIS PROCESS and run without approval prompts.
    \\Commands run with your account permissions; bash is NOT a sandbox.
    \\No automatic command-risk classifier is enabled. --trust is a compatibility flag.
    \\--print returns the final committed visible answer with the same tool policy.
    \\
    \\Project settings: <startup directory>/.thin/settings.json (last logical effort, 0600).
    \\Missing settings create nothing; explicit effort saves even with --no-log.
    \\An unsupported saved level is adjusted effectively without rewriting the preference.
    \\Project Memory: <startup directory>/.thin/mem/*.md, changed through memory tools.
    \\Session records: <startup directory>/.thin/sessions/*.jsonl (local plaintext, 0600).
    \\Recording starts on the first submitted message; --no-log disables it for this run.
    \\Records include messages, tools, stages, usage and errors, not /auth input,
    \\hidden reasoning or native replay. The configured key is redacted; other sensitive
    \\content may remain. Records are not restored or automatically sent to the provider.
    \\Large fields are explicitly truncated/omitted; files rotate without deleting old records.
    \\View locally with ls -lt .thin/sessions and tail -f <chosen.jsonl>.
    \\No model probing or cache warming. Usage is reported when available;
    \\monetary cost is unknown without provider pricing.
    \\
;

// 交互与 --print 默认均不审批，--trust 保持兼容；错误参数仍拒绝。
test "CLI tools are trusted by default and print requires a prompt" {
    const options = try parse(&.{ "thin", "--print", "hello", "--trust" });
    try std.testing.expect(options.trusted);
    try std.testing.expectEqualStrings("hello", options.prompt.?);
    try std.testing.expect((try parse(&.{"thin"})).trusted);
    try std.testing.expect((try parse(&.{ "thin", "--print", "hello" })).trusted);
    try std.testing.expect((try parse(&.{ "thin", "--no-log" })).trusted);
    try std.testing.expect(std.mem.indexOf(u8, help, "run without approval prompts") != null);
    try std.testing.expect((try parse(&.{"thin"})).logging);
    try std.testing.expect(!(try parse(&.{ "thin", "--no-log" })).logging);
    try std.testing.expect(!(try parse(&.{ "thin", "--print", "hello", "--no-log" })).logging);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--config", "other.json" }));
}
