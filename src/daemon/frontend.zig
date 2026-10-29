//! UI-owned facade. Its callbacks read local immutable views/queues only.
//! The Client itself belongs exclusively to Communication until deinit joins it.
const std = @import("std");
const Client = @import("client.zig").Client;
const communication = @import("communication.zig");
const Communication = communication.Communication;
const action = @import("../ui/remote_action.zig");
const session = @import("../ui/session_client.zig");
const tui = @import("../ui/tui.zig");
const config = @import("../core/config.zig");
const settings = @import("../core/settings.zig");
const runtime = @import("../core/runtime.zig");
const activity = @import("../presentation/activity.zig");

pub const Frontend = struct {
    a: std.mem.Allocator,
    communication: *Communication,
    view: *Client.Projection,
    retired: ?*Client.Projection = null,
    generation: u64 = 1,
    revision: u64,
    activity_floor: u64 = 0,
    presentation_changed: bool = false,

    pub fn start(client: *Client) !*Frontend {
        const self = try client.a.create(Frontend);
        errdefer client.a.destroy(self);
        const view = try client.exportProjection();
        errdefer view.deinit();
        const revision = client.publication_revision;
        const worker = try Communication.start(client);
        self.* = .{ .a = client.a, .communication = worker, .view = view, .revision = revision };
        return self;
    }

    pub fn deinit(self: *Frontend) void {
        self.communication.deinit();
        self.view.deinit();
        if (self.retired) |retired| retired.deinit();
        self.a.destroy(self);
    }

    fn from(raw: *anyopaque) *Frontend {
        return @ptrCast(@alignCast(raw));
    }

    fn adopt(self: *Frontend, view: communication.View) void {
        if (view.generation < self.generation) {
            view.projection.deinit();
            return;
        }
        if (view.generation == self.generation and view.revision < self.revision) {
            // Configuration can overtake the display queue. Its newer revision
            // must not erase the older ordered terminal/idle acknowledgement.
            if (view.ordered and view.watermark >= self.activity_floor) {
                self.view.snapshot.busy = view.projection.snapshot.busy;
                self.view.snapshot.mode = view.projection.snapshot.mode;
                self.view.snapshot.task_kind = view.projection.snapshot.task_kind;
                self.view.state.busy = view.projection.snapshot.busy;
            }
            view.projection.deinit();
            return;
        }
        if (view.generation != self.generation) self.activity_floor = 0;
        if (!view.ordered) self.activity_floor = @max(self.activity_floor, view.watermark);
        if (view.generation == self.generation and ((!view.ordered and self.view.snapshot.busy) or
            (view.ordered and view.watermark < self.activity_floor)))
        {
            // A control reply cannot settle the previous task ahead of its
            // ordered terminal event. New sessions do not inherit this latch.
            view.projection.snapshot.busy = true;
            view.projection.state.busy = true;
        }
        self.presentation_changed = self.presentation_changed or view.generation != self.generation or
            view.projection.configuration_revision != self.view.configuration_revision;
        if (self.retired) |retired| retired.deinit();
        self.retired = self.view;
        self.view = view.projection;
        self.generation = view.generation;
        self.revision = view.revision;
    }

    fn startAction(raw: *anyopaque, epoch: u64, value: action.Action) !u64 {
        const self = from(raw);
        return self.communication.submit(self.generation, epoch, value);
    }

    fn pollCompletion(raw: *anyopaque) ?action.Completion {
        const self = from(raw);
        // Drain before inspecting BOTH work queues. A producer racing these
        // reads leaves a new notification for the terminal wait set.
        self.communication.ready.drain();
        var result = self.communication.popCompletion() orelse return null;
        if (result.view) |view| {
            result.completion.obsolete = view.generation < self.generation;
            self.adopt(view);
        } else result.completion.obsolete = result.completion.request.generation < self.generation;
        return result.completion;
    }

    fn current(raw: *anyopaque) tui.Connection.State {
        return from(raw).view.state;
    }
    fn snapshot(raw: *anyopaque) *const session.Snapshot {
        return &from(raw).view.snapshot;
    }
    fn buffered(raw: *anyopaque) bool {
        return from(raw).communication.buffered();
    }

    /// Nonblocking display-ACK admission. Validation uses the projection this
    /// frontend actually displayed: a watermark from a superseded control epoch
    /// is refused here instead of being recorded against the new view.
    fn acknowledge(raw: *anyopaque, epoch: u64, sequence: u64) !void {
        return acknowledgeRange(raw, epoch, 0, sequence);
    }

    /// Selective display proof from the UI: one exact inclusive range (or the
    /// prefix when `first == 0`). Nonblocking admission only; the bound watch
    /// socket owns the actual write, so control stays independent.
    fn acknowledgeRange(raw: *anyopaque, epoch: u64, first: u64, last: u64) !void {
        const self = from(raw);
        if (last == 0) return;
        if (first != 0 and first > last) return error.InvalidInput;
        if (epoch == 0 or epoch != self.view.snapshot.control_epoch) return error.StaleControl;
        return self.communication.acknowledgeRange(epoch, first, last);
    }
    fn poll(raw: *anyopaque, _: std.mem.Allocator) !?session.Item {
        const self = from(raw);
        // Bounded even if a producer keeps supplying stale/view-only messages.
        for (0..Communication.display_capacity) |_| {
            var display = (try self.communication.popDisplay()) orelse return null;
            switch (display.value) {
                .view => |view| self.adopt(view),
                .event => |item| {
                    if (display.generation != self.generation) {
                        display.deinit();
                        continue;
                    }
                    return item;
                },
            }
        }
        return null;
    }

    pub fn connection(self: *Frontend) tui.Connection {
        return .{
            .context = self,
            .current_fn = current,
            .configure_fn = noConfigure,
            .configure_provider_fn = noConfigureProvider,
            .select_model_fn = noConfigure,
            .set_effort_fn = noEffort,
            .cycle_effort_fn = noCycle,
            .preference_fn = noPreference,
            .setting_fn = noSetting,
            .decision_fn = noChoice,
            .image_fn = noChoice,
            .proxy_fn = noProxy,
            .proxy_address_fn = noConfigure,
            .refresh_models_fn = noRefresh,
            .poll_models_fn = metadataOwned,
            .session_client = .{ .context = self, .vtable = &table },
            .async_actions = .{ .context = self, .start_fn = startAction, .poll_fn = pollCompletion, .wake_fd = self.communication.ready.fd },
        };
    }

    // Fail closed if any UI path accidentally invokes an old synchronous
    // callback. Never queue a mutation and then pretend it failed/succeeded.
    fn noConfigure(_: *anyopaque, _: []const u8) anyerror!void {
        return error.AsyncRequired;
    }
    fn noConfigureProvider(_: *anyopaque, _: config.providers.Id, _: []const u8) anyerror!void {
        return error.AsyncRequired;
    }
    fn noEffort(_: *anyopaque, _: activity.ReasoningEffort) anyerror!void {
        return error.AsyncRequired;
    }
    fn noCycle(_: *anyopaque) anyerror!activity.ReasoningEffort {
        return error.AsyncRequired;
    }
    fn noPreference(_: *anyopaque, _: settings.Key, _: ?u32) anyerror!void {
        return error.AsyncRequired;
    }
    fn noSetting(_: *anyopaque, _: tui.Connection.Setting, _: bool) anyerror!void {
        return error.AsyncRequired;
    }
    fn noChoice(_: *anyopaque, _: tui.Connection.DecisionChoice) anyerror!void {
        return error.AsyncRequired;
    }
    fn noProxy(_: *anyopaque, _: []const u8, _: bool) anyerror!void {
        return error.AsyncRequired;
    }
    fn noRefresh(_: *anyopaque) anyerror!void {
        return error.AsyncRequired;
    }
    fn metadataOwned(raw: *anyopaque, _: bool) bool {
        // Communication owns polling; this callback only consumes a UI-local
        // publication notification. An idle menu must redraw when its immutable
        // projection changes, even if no task/body event accompanies it.
        const self = from(raw);
        const changed = self.presentation_changed;
        self.presentation_changed = false;
        return changed;
    }
    fn noSubmit(_: *anyopaque, _: u64, _: session.TaskKind, _: []const u8) anyerror!void {
        return error.AsyncRequired;
    }
    fn noEpoch(_: *anyopaque, _: u64) anyerror!void {
        return error.AsyncRequired;
    }
    fn noRevision(_: *anyopaque, _: u64, _: u64) anyerror!void {
        return error.AsyncRequired;
    }
    fn noConfirm(_: *anyopaque, _: u64, _: bool) anyerror!void {
        return error.AsyncRequired;
    }
    fn noApprove(_: *anyopaque, _: u64, _: u64, _: runtime.Decision) anyerror!void {
        return error.AsyncRequired;
    }
    fn noEnqueue(_: *anyopaque, _: u64, _: session.QueueKind, _: []const u8) anyerror!void {
        return error.AsyncRequired;
    }
    fn noWithdraw(_: *anyopaque, _: std.mem.Allocator, _: u64, _: u64) anyerror!?[]u8 {
        return error.AsyncRequired;
    }
    fn noManage(_: *anyopaque, _: std.mem.Allocator, _: session.Manage) anyerror!session.Outcome {
        return error.AsyncRequired;
    }
    fn detach(_: *anyopaque) void {} // Owner joins/cleans up after TUI restoration.

    const table: session.VTable = .{
        .snapshot_fn = snapshot,
        .poll_fn = poll,
        .buffered_fn = buffered,
        .acknowledge_fn = acknowledge,
        .acknowledge_range_fn = acknowledgeRange,
        .submit_fn = noSubmit,
        .cancel_fn = noEpoch,
        .cancel_clear_fn = noRevision,
        .set_confirming_fn = noConfirm,
        .approve_fn = noApprove,
        .enqueue_fn = noEnqueue,
        .withdraw_fn = noWithdraw,
        .queue_resume_fn = noEpoch,
        .manage_fn = noManage,
        .detach_fn = detach,
    };
};

fn testProjection(busy: bool, model: []const u8) !*Client.Projection {
    const a = std.testing.allocator;
    const projection = try a.create(Client.Projection);
    projection.* = .{ .a = a, .arena = .init(a), .state = .{ .runtime = null, .available = true, .busy = busy, .model = model, .base_url = "" }, .snapshot = .{ .available = true, .attached = true, .busy = busy, .control_epoch = 7 } };
    return projection;
}

test "configuration-only publications notify the UI once without polling the owner" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(false, "old"), .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    const changed = try testProjection(false, "new");
    changed.configuration_revision = 1;
    frontend.adopt(.{ .generation = 1, .revision = 11, .watermark = 0, .ordered = false, .projection = changed });
    try std.testing.expectEqualStrings("new", Frontend.current(&frontend).model);
    try std.testing.expect(Frontend.metadataOwned(&frontend, false));
    try std.testing.expect(!Frontend.metadataOwned(&frontend, true));
    frontend.adopt(.{ .generation = 1, .revision = 9, .watermark = 0, .ordered = false, .projection = try testProjection(false, "stale") });
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    try std.testing.expectEqualStrings("new", Frontend.current(&frontend).model);
    const activity_only = try testProjection(true, "new");
    activity_only.configuration_revision = 1;
    frontend.adopt(.{ .generation = 1, .revision = 12, .watermark = 1, .ordered = true, .projection = activity_only });
    try std.testing.expect(frontend.view.snapshot.busy);
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
}

test "newer control settings cannot erase an ordered idle acknowledgement" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(true, "old-settings"), .generation = 2, .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    frontend.adopt(.{ .generation = 2, .revision = 12, .watermark = 20, .ordered = false, .projection = try testProjection(false, "new-settings") });
    try std.testing.expect(frontend.view.snapshot.busy);
    // Older task's idle must not settle the accepted task at watermark 20.
    frontend.adopt(.{ .generation = 2, .revision = 11, .watermark = 19, .ordered = true, .projection = try testProjection(false, "stale-settings") });
    try std.testing.expect(frontend.view.snapshot.busy);
    // This reaches the consumer only after its preceding terminal event. Even
    // though settings overtook its revision, idle must still be acknowledged.
    frontend.adopt(.{ .generation = 2, .revision = 11, .watermark = 20, .ordered = true, .projection = try testProjection(false, "stale-settings") });
    try std.testing.expect(!frontend.view.snapshot.busy);
    try std.testing.expect(!frontend.view.state.busy);
    try std.testing.expectEqualStrings("new-settings", frontend.view.state.model);
    frontend.adopt(.{ .generation = 1, .revision = 100, .watermark = 100, .ordered = true, .projection = try testProjection(true, "old-session") });
    try std.testing.expectEqual(@as(u64, 2), frontend.generation);
    try std.testing.expect(!frontend.view.snapshot.busy);
}
