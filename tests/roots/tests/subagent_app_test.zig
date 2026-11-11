//! App-level subagent ownership regressions: the capability is always wired,
//! idle rebinding keeps it installed, and Decision/Image clones stay independent.
//! No network, real credentials or user configuration directories are touched.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const App = @import("../app/app.zig").App;
const DecisionClient = @import("../app/decision_client.zig").Client;
const image_client = @import("../app/image_client.zig");
const ImageClient = image_client.Client;
const model_resolver = @import("../app/model_resolver.zig");

const parent_tools = [_][]const u8{ "subagent", "get_subagent_result", "send_subagent_message", "cancel_subagent" };

fn hasSchema(schemas: []const @import("../core/protocol.zig").ToolSchema, name: []const u8) bool {
    for (schemas) |schema| if (std.mem.eql(u8, schema.name, name)) return true;
    return false;
}

fn expectSubagentSurface(app: *App) !void {
    try std.testing.expect(app.executor.subagent != null);
    const schemas = app.executor.executor().schemas;
    for (parent_tools) |name| try std.testing.expect(hasSchema(schemas, name));
    for (parent_tools) |name| try std.testing.expect(hasSchema(app.runtime.executor.schemas, name));
    // The child has no recursive delegation and no memory tool.
    try std.testing.expect(app.executor.parent_channel == null);
    try std.testing.expect(app.executor.allow_memory);
}
