//! Dedicated, opt-in DeepSeek Flash image inspection. Only bounded text returns
//! to canonical history: no image block, upload URL or encoded file is replayed.
const std = @import("std");
const p = @import("protocol.zig");

pub const model_id = "deepseek-flash";
pub const max_image_bytes = 4 * 1024 * 1024;
pub const max_dimension = 8192;
pub const max_question_bytes = 4096;
pub const max_result_bytes = 16 * 1024;
/// Current Flash vision documentation: each image consumes at most 1024 tokens.
/// A transport byte limit is separate; base64 bytes are not text-token usage.
pub const image_token_bound: u32 = 1024;
pub const default_question = "Describe this image accurately, including visible text relevant to the task. State uncertainty or unreadable details instead of guessing.";

pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,

    pub fn mime(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};

/// Borrowed, already validated bytes captured from one anchored file read.
pub const Image = struct {
    data: []const u8,
    format: Format,
    width: u32,
    height: u32,
};
pub const Input = struct { image: Image, question: []const u8 = default_question };
/// text is caller-allocator-owned. Usage belongs to the auxiliary call, never
/// the primary model's context/accounting. Neither bytes nor path are returned.
pub const Output = struct { text: []const u8, usage: p.Usage = .{} };

pub fn validate(input: Input) !void {
    if (input.image.data.len == 0 or input.image.data.len > max_image_bytes) return error.ImageTooLarge;
    if (input.image.width == 0 or input.image.height == 0 or input.image.width > max_dimension or input.image.height > max_dimension) return error.InvalidImageDimensions;
    if (input.question.len == 0 or input.question.len > max_question_bytes or !std.unicode.utf8ValidateSlice(input.question) or std.mem.indexOfScalar(u8, input.question, 0) != null) return error.InvalidImageQuestion;
}

pub const Service = struct {
    context: *anyopaque,
    inspect_fn: *const fn (*anyopaque, std.mem.Allocator, Input, *const p.Cancellation) anyerror!Output,
    /// Pure readiness/poison guard; must not read files or launch requests.
    check_fn: ?*const fn (*anyopaque) anyerror!void = null,

    pub fn checkReady(self: Service) !void {
        if (self.check_fn) |check| try check(self.context);
    }

    pub fn inspect(self: Service, a: std.mem.Allocator, input: Input, cancel: *const p.Cancellation) !Output {
        try self.checkReady();
        if (cancel.isRequested()) return error.Canceled;
        try validate(input);
        const output = self.inspect_fn(self.context, a, input, cancel) catch |err| {
            if (err == error.CleanupFailed) return err;
            if (cancel.isRequested()) return error.Canceled;
            return err;
        };
        if (cancel.isRequested()) {
            a.free(output.text);
            return error.Canceled;
        }
        if (output.text.len == 0 or output.text.len > max_result_bytes or !std.unicode.utf8ValidateSlice(output.text) or std.mem.indexOfScalar(u8, output.text, 0) != null) {
            a.free(output.text);
            return error.InvalidImageResponse;
        }
        return output;
    }
};

test "image inspection is bounded and a poisoned service wins over cancellation" {
    const Fake = struct {
        calls: usize = 0,
        poisoned: bool = false,
        fn check(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.poisoned) return error.CleanupFailed;
        }
        fn inspect(raw: *anyopaque, a: std.mem.Allocator, _: Input, _: *const p.Cancellation) !Output {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .text = try a.dupe(u8, "image description") };
        }
    };
    var fake: Fake = .{};
    const service: Service = .{ .context = &fake, .inspect_fn = Fake.inspect, .check_fn = Fake.check };
    const input: Input = .{ .image = .{ .data = "fixture", .format = .png, .width = 1, .height = 1 } };
    var cancel: p.Cancellation = .{};
    const output = try service.inspect(std.testing.allocator, input, &cancel);
    defer std.testing.allocator.free(output.text);
    try std.testing.expectEqualStrings("image description", output.text);
    cancel.cancel();
    try std.testing.expectError(error.Canceled, service.inspect(std.testing.allocator, input, &cancel));
    fake.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, service.inspect(std.testing.allocator, input, &cancel));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    var invalid = input;
    invalid.image.width = max_dimension + 1;
    try std.testing.expectError(error.InvalidImageDimensions, validate(invalid));
    invalid = input;
    invalid.question = "";
    try std.testing.expectError(error.InvalidImageQuestion, validate(invalid));
}
