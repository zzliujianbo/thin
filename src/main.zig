//! Validate launch syntax before initializing the terminal or application.
const std = @import("std");
const cli = @import("app/cli.zig");
const interrupt = @import("platform/interrupt.zig");
const daemon = @import("daemon/entry.zig");
const text = @import("ui/text.zig");
const capabilities = @import("platform/capabilities.zig");

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        if (err == error.Canceled and interrupt.signal() != 0) return 128 + interrupt.signal();
        if (err == error.UnsupportedPlatformMode) {
            output(init.io, .stderr(), "thin: macOS supports local foreground sessions only.\n") catch {};
            return 2;
        }
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "thin: {s}\n", .{@errorName(err)}) catch "thin: application error\n";
        output(init.io, .stderr(), message) catch {};
        return 1;
    };
}

/// Keep terminal writes cancellable even under backpressure.
pub fn output(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    const Write = struct {
        io: std.Io,
        file: std.Io.File,
        bytes: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var buffer: [4096]u8 = undefined;
            var writer = self.file.writer(self.io, &buffer);
            writer.interface.writeAll(self.bytes) catch |err| {
                self.failure = err;
                return;
            };
            writer.interface.flush() catch |err| {
                self.failure = err;
            };
        }
    };

    if (interrupt.signal() != 0) return error.Canceled;
    var write = Write{ .io = io, .file = file, .bytes = bytes };
    var future = try std.Io.concurrent(io, Write.run, .{&write});
    defer future.cancel(io); // Joins before the borrowed bytes or stack go away.
    while (!write.done.load(.acquire)) {
        if (interrupt.signal() != 0) return error.Canceled;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    future.await(io);
    if (interrupt.signal() != 0) return error.Canceled;
    if (write.failure) |err| return err;
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = cli.parse(args) catch {
        try output(init.io, .stderr(), cli.usage);
        return 2;
    };
    try capabilities.validate(options);
    if (options.mode.requiresTty() and (std.c.isatty(0) != 1 or std.c.isatty(1) != 1)) return error.TtyRequired;
    try text.initLocale();
    return daemon.run(init, options);
}
