const FakeWire = struct {
    refresh_count: usize = 0,
    exchange_count: usize = 0,
    prompt_count: usize = 0,
    callback_mode: enum { valid, invalid, oversize, canceled, failed } = .valid,
    cancel_at_prompt: ?*p.Cancellation = null,
    challenge: [43]u8 = undefined,
    cancel_on_refresh: ?*p.Cancellation = null,
    mutate_store: ?*store_mod.Store = null,
    change_credential: bool = false,
    fail_refresh: bool = false,
    fn wire(self: *FakeWire) Wire {
        return .{ .context = self, .exchange = exchange, .refresh = refresh, .account = account };
    }
    fn sink(self: *FakeWire) BrowserSink {
        return .{ .context = self, .callback_fn = callback };
    }
    fn param(url: []const u8, marker: []const u8) ![]const u8 {
        const start = std.mem.find(u8, url, marker) orelse return error.MissingParameter;
        const rest = url[start + marker.len ..];
        return rest[0 .. std.mem.findScalar(u8, rest, '&') orelse rest.len];
    }
    fn callback(ctx: *anyopaque, url: []const u8, out: []u8, cancel: *const p.Cancellation, timeout: u32) !usize {
        const self: *FakeWire = @ptrCast(@alignCast(ctx));
        self.prompt_count += 1;
        try std.testing.expect(timeout > call_limit and timeout <= login_limit);
        try std.testing.expect(!cancel.isRequested());
        try std.testing.expectEqual(@as(usize, 4096), out.len);
        const challenge = try param(url, "&code_challenge=");
        try std.testing.expectEqual(self.challenge.len, challenge.len);
        @memcpy(&self.challenge, challenge);
        const state = try param(url, "&state=");
        switch (self.callback_mode) {
            .failed => return error.SinkFailure,
            .oversize => return out.len + 1,
            .canceled => self.cancel_at_prompt.?.cancel(),
            else => {},
        }
        return (try std.fmt.bufPrint(out, "http://localhost:1455/auth/callback?code=a%2Bb&state={s}", .{if (self.callback_mode == .invalid) "mismatch" else state})).len;
    }
    fn exchange(ctx: ?*anyopaque, a: std.mem.Allocator, client: *Client, code: []const u8, verifier: []const u8, _: ?*const p.Cancellation, timeout: u32) !device.TokenSet {
        const io = client.io;
        const self: *FakeWire = @ptrCast(@alignCast(ctx.?));
        self.exchange_count += 1;
        try std.testing.expect(timeout > 0 and timeout <= call_limit);
        try std.testing.expectEqualStrings("a+b", code);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
        var encoded: [43]u8 = undefined;
        try std.testing.expectEqualStrings(&self.challenge, std.base64.url_safe_no_pad.Encoder.encode(&encoded, &hash));
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
        return tokens(a, io);
    }
    fn refresh(ctx: ?*anyopaque, a: std.mem.Allocator, client: *Client, _: []const u8, _: ?*const p.Cancellation, _: u32) !device.TokenSet {
        const io = client.io;
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
