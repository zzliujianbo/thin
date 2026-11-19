fn schemasFor(image_on: bool, background_on: bool) []const p.ToolSchema {
    return schemasWith(image_on, background_on);
}

fn schemasForServices(enabled: bool) []const p.ToolSchema {
    return schemasFor(enabled, false);
}

const FakeBackground = struct {
    calls: usize = 0,
    checks: usize = 0,
    controls: usize = 0,
    poisoned: bool = false,
    cleanup_failed: bool = false,
    last_command: []const u8 = "",
    last_startup_ms: u32 = 0,
    last_grace_ms: u32 = 0,
    last_cleanup_ms: u32 = 0,
    last_query: background.Query = .{ .action = .list },
    start_text: []const u8 = "{\"id\":\"0123456789ab-1\",\"status\":\"running\"}",
    control_text: []const u8 = "{\"id\":\"0123456789ab-1\",\"status\":\"exited\",\"exit_code\":0}",

    fn service(self: *@This()) background.Service {
        return .{ .context = self, .start_fn = @This().start, .control_fn = @This().control, .check_fn = @This().check };
    }

    fn check(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.checks += 1;
        if (self.poisoned) return error.CleanupFailed;
    }

    fn start(raw: *anyopaque, a: std.mem.Allocator, s: background.Start, cancel: *const p.Cancellation) anyerror!background.Result {
        _ = a;
        _ = cancel;
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_command = s.command;
        self.last_startup_ms = s.startup_timeout_ms;
        self.last_grace_ms = s.term_grace_ms;
        self.last_cleanup_ms = s.cleanup_timeout_ms;
        return .{ .text = self.start_text, .cleanup_failed = self.cleanup_failed };
    }

    fn control(raw: *anyopaque, a: std.mem.Allocator, q: background.Query, cancel: *const p.Cancellation) anyerror!background.Result {
        _ = a;
        _ = cancel;
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.controls += 1;
        self.last_query = q;
        return .{ .text = self.control_text };
    }
};
