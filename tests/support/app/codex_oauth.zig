const FakeWire = struct {
    refresh_count: usize = 0,
    cancel_on_refresh: ?*p.Cancellation = null,
    mutate_store: ?*store_mod.Store = null,
    change_credential: bool = false,
    fail_refresh: bool = false,
    fn wire(self: *FakeWire) Wire {
        return .{ .context = self, .begin = begin, .poll = poll, .refresh = refresh, .account = account };
    }
    fn begin(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, _: ?*const p.Cancellation, _: u32) !device.DeviceState {
        const id = try a.dupe(u8, "device-id");
        errdefer a.free(id);
        return .{ .device_auth_id = id, .user_code = try a.dupe(u8, "ABCD"), .interval_ms = 1, .expires_at_ms = @as(i64, @intCast(std.Io.Clock.real.now(io).toMilliseconds())) + 60_000 };
    }
    fn poll(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, _: *const device.DeviceState, _: ?*const p.Cancellation, _: u32) !device.PollResult {
        const self: *FakeWire = @ptrCast(@alignCast(ctx.?));
        if (self.mutate_store) |store| {
            var tx = try store.beginTransaction(null, 1000);
            defer tx.deinit();
            var latest = try tx.loadLatest();
            defer cfg.release(&latest);
            latest.value.registry.?.reasoning_effort = "high";
            if (self.change_credential) {
                const names = try merge(a, &latest.value, "codex", .{ .access_token = "parallel", .refresh_token = "parallel-refresh", .expires_at_ms = 2 }, true);
                defer a.free(names);
                try tx.saveLatest(latest.value);
            } else try tx.saveLatest(latest.value);
        }
        return .{ .success = try tokens(a, io) };
    }
    fn refresh(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, _: []const u8, _: ?*const p.Cancellation, _: u32) !device.TokenSet {
        const self: *FakeWire = @ptrCast(@alignCast(ctx.?));
        self.refresh_count += 1;
        if (self.fail_refresh) return error.AmbiguousResponse;
        const result = try tokens(a, io);
        if (self.cancel_on_refresh) |c| c.cancel();
        return result;
    }
    fn tokens(a: std.mem.Allocator, io: std.Io) !device.TokenSet {
        const access = try a.dupe(u8, "new-access");
        errdefer a.free(access);
        return .{ .access_token = access, .refresh_token = try a.dupe(u8, "new-refresh"), .expires_at_ms = @as(i64, @intCast(std.Io.Clock.real.now(io).toMilliseconds())) + 3_600_000 };
    }
    fn account(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8) ![]u8 {
        return a.dupe(u8, "account-id");
    }
};

fn failIntentSave(intent: bool) !void {
    if (intent) return error.InjectedFailure;
}

fn failRotationSave(intent: bool) !void {
    if (!intent) return error.InjectedFailure;
}
