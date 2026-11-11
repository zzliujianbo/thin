test "SSH listener is explicit daemon-only; internal child is not a public attach mode" {
    const daemon = try parse(&.{ "thin", "--ssh-listen", "127.0.0.1:2222", "--daemon" });
    try std.testing.expectEqual(Mode.daemon, daemon.mode);
    try std.testing.expectEqualStrings("127.0.0.1:2222", daemon.ssh_listen.?);
    try std.testing.expect((try parse(&.{"thin"})).ssh_listen == null);
    const child = try parse(&.{ "thin", "--internal-ssh", "1234", "--no-model-auto-refresh" });
    try std.testing.expectEqual(Mode.connect, child.mode);
    try std.testing.expectEqual(@as(u32, 1234), child.ssh_owner.?);
    try std.testing.expect(!child.auto_refresh_models);
    for ([_][]const [:0]const u8{
        &.{ "thin", "--ssh-listen", "127.0.0.1:2222" },
        &.{ "thin", "--connect", "--ssh-listen", "127.0.0.1:2222" },
        &.{ "thin", "--daemon", "--ssh-listen" },
        &.{ "thin", "--daemon", "--ssh-listen", "" },
        &.{ "thin", "--daemon", "--ssh-listen", "a", "--ssh-listen", "b" },
        &.{ "thin", "--internal-ssh", "1" },
        &.{ "thin", "--internal-ssh", "-4" },
        &.{ "thin", "--internal-ssh", "+4" },
        &.{ "thin", "--internal-ssh", "2147483648" },
        &.{ "thin", "--internal-ssh", "4", "--daemon" },
        &.{ "thin", "--internal-ssh", "4", "--print", "x" },
    }) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
}
test "CLI help describes global defaults and actual metadata sources" {
    try std.testing.expect(std.mem.indexOf(u8, help, "llm.reasoning_effort globally") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "official /models and public models.dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Legacy project settings.json is ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Global logical defaults wait for known capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "saved project selection preferences") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "no third-party data") == null);
}
test "CLI selection restore is explicit bounded and interactive only" {
    const id = "0123456789abcdef0123456789abcdef";
    const options = try parse(&.{ "thin", "--restore-selection", id });
    try std.testing.expectEqualStrings(id, &options.restore_selection.?);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--restore-selection", "../history" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--restore-selection", "0123456789abcdef0123456789abcdeF" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "-p", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--restore-selection", id }));
}
test "CLI resume is distinct same-session interactive selection and rejects conflicts" {
    const id = "0123456789abcdef0123456789abcdef";
    const options = try parse(&.{ "thin", "--resume", id });
    try std.testing.expectEqualStrings(id, &options.resume_session.?);
    try std.testing.expect(options.restore_selection == null);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--resume", "../invalid" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--print", "go" }));
}
test "CLI ordinary tools run directly and print requires a prompt" {
    const options = try parse(&.{ "thin", "--print", "hello" });
    try std.testing.expectEqualStrings("hello", options.prompt.?);
    try std.testing.expect(std.mem.indexOf(u8, help, "run without approval prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "No automatic command-risk classifier") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Without Decision, static risk matches require approval each time; with Decision,") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "approval follows its ask result, and a failed decision does not allow execution.") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Patterns: recursive rm, find -delete, git clean -f") == null);
    try std.testing.expect((try parse(&.{"thin"})).auto_refresh_models);
    try std.testing.expect(!(try parse(&.{ "thin", "--no-model-auto-refresh" })).auto_refresh_models);
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--no-log" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--print", "hello", "--no-log" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--config", "other.json" }));
}
test "CLI defaults to foreground and resume stays foreground" {
    const plain = try parse(&.{"thin"});
    try std.testing.expectEqual(Mode.foreground, plain.mode);
    try std.testing.expect(plain.attach_session == null and !plain.takeover);
    try std.testing.expect(plain.worker_endpoint == null and plain.worker_session == null);
    try std.testing.expectEqual(WorkerOwner.daemon, plain.worker_owner);
    try std.testing.expect(!plain.worker_resume);

    const id = "0123456789abcdef0123456789abcdef";
    const resumed = try parse(&.{ "thin", "--resume", id });
    try std.testing.expectEqual(Mode.foreground, resumed.mode);
    try std.testing.expectEqualStrings(id, &resumed.resume_session.?);
    const restored = try parse(&.{ "thin", "--restore-selection", id });
    try std.testing.expectEqual(Mode.foreground, restored.mode);
    try std.testing.expectEqualStrings(id, &restored.restore_selection.?);
    const printed = try parse(&.{ "thin", "--print", "hello" });
    try std.testing.expectEqual(Mode.foreground, printed.mode);

    // 仅前台/connect/attach 需要终端；daemon 与内部 worker 必须能在无 TTY 下进入。
    try std.testing.expect(Mode.foreground.requiresTty());
    try std.testing.expect(Mode.connect.requiresTty());
    try std.testing.expect(Mode.attach.requiresTty());
    try std.testing.expect(!Mode.daemon.requiresTty());
    try std.testing.expect(!Mode.worker.requiresTty());
}
test "CLI daemon connect attach are exclusive with each other and other run modes" {
    const id = "0123456789abcdef0123456789abcdef";
    const other = "fedcba9876543210fedcba9876543210";

    try std.testing.expectEqual(Mode.daemon, (try parse(&.{ "thin", "--daemon" })).mode);
    try std.testing.expectEqual(Mode.connect, (try parse(&.{ "thin", "--connect" })).mode);
    const attached = try parse(&.{ "thin", "--attach", id });
    try std.testing.expectEqual(Mode.attach, attached.mode);
    try std.testing.expectEqualStrings(id, &attached.attach_session.?);
    try std.testing.expect(!attached.takeover);

    // 重复与互相冲突。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--connect", "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--connect", "--daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--attach", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--attach", other }));

    // 与 --print/--resume/--restore-selection 冲突，包括反向顺序。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--print", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print", "go", "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--print", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--attach", id }));

    // 缺少或无效的会话 ID。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--attach", "../session" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--attach", "0123456789abcdef0123456789abcdeF" }));
}
test "CLI takeover belongs to attach only" {
    const id = "0123456789abcdef0123456789abcdef";
    const attached = try parse(&.{ "thin", "--attach", id, "--takeover" });
    try std.testing.expectEqual(Mode.attach, attached.mode);
    try std.testing.expect(attached.takeover);

    // 不带 --attach，或在其它模式下使用，一律拒绝；重复也一样。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--connect", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print", "go", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--takeover", "--takeover" }));
}
test "CLI internal worker carries endpoint session and owner" {
    const id = "0123456789abcdef0123456789abcdef";
    const socket = "/run/user/1000/thin/workers/session.sock";

    const daemon_side = try parse(&.{ "thin", "--internal-worker", socket, id, "daemon" });
    try std.testing.expectEqual(Mode.worker, daemon_side.mode);
    try std.testing.expect(!Mode.worker.requiresTty());
    try std.testing.expectEqualStrings(socket, daemon_side.worker_endpoint.?);
    try std.testing.expectEqualStrings(id, &daemon_side.worker_session.?);
    try std.testing.expectEqual(WorkerOwner.daemon, daemon_side.worker_owner);
    try std.testing.expect(!daemon_side.worker_resume);

    const foreground_side = try parse(&.{ "thin", "--internal-worker", socket, id, "foreground" });
    try std.testing.expectEqual(WorkerOwner.foreground, foreground_side.worker_owner);
    try std.testing.expectEqual(Mode.worker, foreground_side.mode);

    const resumed_worker = try parse(&.{ "thin", "--worker-resume", "--internal-worker", socket, id, "foreground" });
    try std.testing.expectEqual(Mode.worker, resumed_worker.mode);
    try std.testing.expect(resumed_worker.worker_resume);

    // 缺参、空 endpoint、未知 owner、无效 ID。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", "", id, "daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "system" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, "not-a-session", "daemon" }));

    // 重复 worker 入口或与公开模式混用都是冲突。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--internal-worker", socket, id, "daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--internal-worker", socket, id, "daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--print", "go" }));

    // --worker-resume 是内部标记：不能与公开 --resume/--restore-selection 混用，也不能单独使用。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--worker-resume" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--worker-resume", "--worker-resume", "--internal-worker", socket, id, "daemon" }));
    try std.testing.expect(std.mem.indexOf(u8, help, "--worker-restore-selection") == null);
}
test "CLI worker restore-selection is worker-only and exclusive" {
    const id = "0123456789abcdef0123456789abcdef";
    const prior = "fedcba9876543210fedcba9876543210";
    const socket = "/run/user/1000/thin/workers/session.sock";

    // 合法：两个 worker 模式都可带，且不写公开字段。
    const migrated = try parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-restore-selection", prior });
    try std.testing.expectEqual(Mode.worker, migrated.mode);
    try std.testing.expectEqualStrings(prior, &migrated.worker_restore_selection.?);
    try std.testing.expect(migrated.restore_selection == null and !migrated.worker_resume);
    try std.testing.expectEqualStrings(id, &migrated.worker_session.?);

    // 参数顺序无关。
    const reordered = try parse(&.{ "thin", "--worker-restore-selection", prior, "--internal-worker", socket, id, "daemon" });
    try std.testing.expectEqualStrings(prior, &reordered.worker_restore_selection.?);
    try std.testing.expectEqual(WorkerOwner.daemon, reordered.worker_owner);

    // 公开 --restore-selection 仍是普通前台，不设置内部字段。
    const public = try parse(&.{ "thin", "--restore-selection", id });
    try std.testing.expectEqual(Mode.foreground, public.mode);
    try std.testing.expect(public.worker_restore_selection == null);

    // 无参数仍是普通前台：它不是 worker 负例。
    const plain = try parse(&.{"thin"});
    try std.testing.expectEqual(Mode.foreground, plain.mode);
    try std.testing.expect(plain.worker_restore_selection == null and plain.worker_session == null);

    // 表格：全部拒绝的组合。
    const rejected = [_][]const [:0]const u8{
        &.{ "thin", "--worker-restore-selection", prior }, // 缺内部入口
        &.{ "thin", "--worker-restore-selection" }, // 缺参数
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection" }, // 缺参数
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--worker-restore-selection", prior }, // 重复
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-resume", "--worker-restore-selection", prior }, // 与 worker-resume 混用
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--worker-resume" },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--resume", id }, // 公开 resume
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--restore-selection", id }, // 公开 restore
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--print", "go" }, // 公开 print
    };
    for (rejected) |args| try std.testing.expectError(error.InvalidArguments, parse(args));

    // 非法 ID 保持 InvalidSessionID。
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", "../session" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", "0123456789ABCDEF0123456789ABCDEF" }));
}
test "CLI help documents explicit modes without advertising internal entry" {
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expect(std.mem.indexOf(u8, help, "macOS local mode") != null);
        try std.testing.expect(std.mem.indexOf(u8, help, "--resume <32-lowerhex-session-id>") != null);
        try std.testing.expect(std.mem.indexOf(u8, help, "are unsupported") != null);
        try std.testing.expect(std.mem.indexOf(u8, help, "Only --daemon explicitly runs") == null);
        try std.testing.expect(std.mem.indexOf(u8, help, "--internal-worker") == null);
        try std.testing.expect(std.mem.indexOf(u8, help, "--worker-resume") == null);
        return;
    }
    try std.testing.expect(std.mem.indexOf(u8, help, "ordinary local foreground by default") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Only --daemon explicitly runs the per-user service") != null);
    // 只有 --connect 依赖 daemon；--attach 可连普通前台公布的 worker，两者都不自启服务。
    try std.testing.expect(std.mem.indexOf(u8, help, "--connect joins the already running daemon service") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "or the daemon may publish, so it does not require a running daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Neither --connect nor --attach starts a service") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "requires an already running service") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "are mutually exclusive") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--takeover is valid only with --attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "need a terminal; the daemon does not") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--internal-worker") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--worker-resume") == null);
}
