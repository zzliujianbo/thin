test "public grammar is exactly thin or thin --daemon" {
    const plain = try parse(&.{"thin"});
    try std.testing.expectEqual(Mode.foreground, plain.mode);
    try std.testing.expect(plain.auto_refresh_models);
    try std.testing.expectEqual(Mode.daemon, (try parse(&.{ "thin", "--daemon" })).mode);
    try std.testing.expectEqualStrings("Usage: thin [--daemon]\n", usage);

    const id = "0123456789abcdef0123456789abcdef";
    for ([_][]const [:0]const u8{
        &.{},                                    &.{ "thin", "" },                                    &.{ "thin", "prompt" },                                     &.{ "thin", "--" },
        &.{ "thin", "--help" },                  &.{ "thin", "-h" },                                  &.{ "thin", "--version" },                                  &.{ "thin", "--print", "hello" },
        &.{ "thin", "-p", "hello" },             &.{ "thin", "--attach", id },                        &.{ "thin", "--takeover" },                                 &.{ "thin", "--connect" },
        &.{ "thin", "--restore-selection", id }, &.{ "thin", "--resume", id },                        &.{ "thin", "--daemon", "--ssh-listen", "127.0.0.1:2222" }, &.{ "thin", "--ssh-listen" },
        &.{ "thin", "--no-model-auto-refresh" }, &.{ "thin", "--daemon", "--no-model-auto-refresh" }, &.{ "thin", "--daemon", "--daemon" },                       &.{ "thin", "--daemon", "extra" },
        &.{ "thin", "--help", "--daemon" },      &.{ "thin", "--daemon", "--help" },                  &.{ "thin", "--worker-resume" },                            &.{ "thin", "--worker-restore-selection", id },
    }) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
}

test "private worker layouts match spawner positional arguments" {
    const id = "0123456789abcdef0123456789abcdef";
    const old = "fedcba9876543210fedcba9876543210";
    const socket = "/run/user/1000/thin/worker.sock";
    const fresh = try parse(&.{ "thin", "--internal-worker", socket, id, "daemon" });
    try std.testing.expectEqual(Mode.worker, fresh.mode);
    try std.testing.expectEqual(WorkerOwner.daemon, fresh.worker_owner);
    try std.testing.expectEqualStrings(socket, fresh.worker_endpoint.?);
    try std.testing.expectEqualStrings(id, &fresh.worker_session.?);
    try std.testing.expect(fresh.auto_refresh_models and !fresh.worker_resume and fresh.worker_restore_selection == null);
    const resumed = try parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-resume", "--no-model-auto-refresh" });
    try std.testing.expectEqual(WorkerOwner.foreground, resumed.worker_owner);
    try std.testing.expect(resumed.worker_resume and !resumed.auto_refresh_models);
    const restored = try parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-restore-selection", old });
    try std.testing.expectEqualStrings(old, &restored.worker_restore_selection.?);

    for ([_][]const [:0]const u8{
        &.{ "thin", "--internal-worker" },
        &.{ "thin", "--internal-worker", "relative", id, "daemon" },
        &.{ "thin", "--internal-worker", socket, id, "other" },
        &.{ "thin", "--worker-resume", "--internal-worker", socket, id, "daemon" },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-resume", "--worker-restore-selection", old },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--no-model-auto-refresh", "--worker-resume" },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--no-model-auto-refresh", "--no-model-auto-refresh" },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--restore-selection", old },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--daemon" },
    }) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, "bad", "daemon" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", "0123456789ABCDEF0123456789ABCDEF" }));
}

test "retired private SSH child layouts are rejected" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-ssh", "1234" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-ssh", "1234", "--no-model-auto-refresh" }));
}
