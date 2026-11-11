//! Registry Session regressions. Temporary HOME, synthetic keys, no requests.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const metadata = @import("model_metadata.zig");
const selections = @import("selection.zig");
const codec = @import("resume_codec.zig");
const a = std.testing.allocator;

fn save(home: []const u8, text: []const u8) !void {
    var store = try Store.open(a, std.testing.io, home);
    defer store.deinit();
    var parsed = try cfg.parse(a, text);
    defer cfg.release(&parsed);
    // Seed a literal disk document, independently of onboarding serialization.
    try store.root.writeMode(cfg.file_name, text, false, 0o600);
}

fn expectInactiveHistoryWithoutLowPriceMarker(session: *Session, read_only: bool) !void {
    const context = @import("../core/context.zig");
    try std.testing.expect(session.app == null and session.read_only == read_only);
    const config = &session.pending.?.value;
    try std.testing.expect(!config.selection_pending);
    try std.testing.expectEqual(@as(?u32, 20000), config.model.input_price_threshold);
    const budget = context.inputBudget(config.*);
    const connection = session.connection();
    const state = connection.current();
    try std.testing.expect(state.runtime == null and !state.low_price_input);
    try std.testing.expect(state.low_price_input_enabled and config.limits.low_price_input);
    try std.testing.expectEqual(@as(u32, 65536), state.context_limit);
    try std.testing.expectEqual(@as(u64, 65536), state.initial_context.?.limit);
    try std.testing.expectEqual(budget, context.inputBudget(config.*));
    try context.validateInputPolicy(config.*);
    const history = connection.initial_history_fn.?(connection.context);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("owned marker history", history[0].blocks[0].text);
    try std.testing.expectEqualStrings("owned marker answer", history[1].blocks[0].text);
}

const PublicationFetch = struct {
    var official: [3]std.atomic.Value(usize) = .{ .init(0), .init(0), .init(0) };
    var public_calls: std.atomic.Value(usize) = .init(0);
    var hold_public: std.atomic.Value(bool) = .init(false);
    fn fetch(_: std.mem.Allocator, _: std.Io, id: cfg.providers.Id, key: ?[]const u8) !metadata.Listing {
        if (key == null) return error.UnexpectedNullKey;
        _ = official[@intCast(@backingInt(id))].fetchAdd(1, .monotonic);
        return .{};
    }
    fn dev(_: std.mem.Allocator, io: std.Io) !metadata.Listing {
        _ = public_calls.fetchAdd(1, .monotonic);
        while (hold_public.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        return .{ .dev_done = true };
    }
    fn refresh(session: *Session) !void {
        const connection = session.connection();
        try connection.refresh_models_fn.?(connection.context);
    }
    fn poll(session: *Session) bool {
        const connection = session.connection();
        return connection.poll_models_fn.?(connection.context, true);
    }
    fn finishOfficial(session: *Session) void {
        const job = session.metadata_job.?;
        if (job.future) |*future| future.await(session.io);
        job.future = null;
    }
    fn finish(session: *Session) void {
        finishOfficial(session);
        const job = session.metadata_job.?;
        if (job.dev_future) |*future| future.await(session.io);
        job.dev_future = null;
    }
};

const custom =
    \\{"llm":{"default":"alpha/org/shared","providers":{"alpha":{"base_url":"https://alpha.invalid/v1","api_key_env":"ALPHA_KEY","models":{"org/shared":{"protocol":"chat","context_tokens":65536,"output_tokens":8192},"other":{"protocol":"chat","context_tokens":32768}}},"beta":{"base_url":"https://beta.invalid/v1","api_key_env":"BETA_KEY","models":{"org/shared":{"protocol":"responses","context_tokens":131072,"output_tokens":16384}}}}}}
;
