//! Actual App hooks with automatic recording and no HTTP: primary and extractor are owned fakes.
const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const App = @import("app.zig").App;
const source =
    \\{"llm":{"default":"owned/main","providers":{"owned":{"base_url":"http://127.0.0.1:1","api_key":"private-owned-test-key","models":{"main":{"protocol":"PRIMARY_PROTOCOL","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;
const Fake = struct {
    calls: usize = 0,
    extracted: std.atomic.Value(usize) = .init(0),
    fn main(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "Owned answer."), .finish = .stop, .usage = .{ .total_tokens = 1234 } } };
    }
    fn auxiliary(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.extracted.fetchAdd(1, .acq_rel);
        try std.testing.expect(request.scope.protocol != .auto and request.tools.len == 0);
        try sink.emit(.{ .usage = .{ .total_tokens = 333 } });
        return .{ .success = .{ .message = try p.textMessage(a, .assistant,
            \\{"items":[{"category":"preferences","topic":"review-style","content":"Prefers concise review explanations.","expected_version":null,"expires_at_ms":null}]}
        ), .finish = .stop, .usage = .{ .total_tokens = 333 } } };
    }
};
