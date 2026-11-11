//! Positive request/protocol contracts; fake models only, no HTTP or storage.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const thinking = @import("../core/thinking.zig");
const r = @import("../core/runtime.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const support = @import("adapter_test_support.zig");

const Stub = struct {
    fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        return error.UnexpectedRequest;
    }
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
};

fn runtime(config: *cfg.Config, dummy: *u8) !r.Runtime {
    return r.Runtime.init(std.testing.allocator, std.testing.io, config, .{ .context = dummy, .call_fn = Stub.call }, .{ .context = dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "");
}
