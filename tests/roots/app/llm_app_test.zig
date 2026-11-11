const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("../core/config.zig");
const auth = @import("auth_store.zig");
const metadata = @import("model_metadata.zig");
const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    env: std.process.Environ.Map,
    fn init(data: []const u8) !Fixture {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (std.c.mkdirat(tmp.dir.handle, ".thin", 0o700) != 0) return error.FixtureDirectoryFailed;
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = data });
        var buffer: [4096]u8 = undefined;
        const home = try a.dupe(u8, buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)]);
        errdefer a.free(home);
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        return .{ .tmp = tmp, .home = home, .env = env };
    }
    fn deinit(self: *Fixture) void {
        self.env.deinit();
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }
};
