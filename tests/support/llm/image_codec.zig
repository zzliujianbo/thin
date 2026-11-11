const fixture: image.Input = .{ .image = .{ .data = "abc", .format = .png, .width = 2, .height = 3 }, .question = "What is \"this\"?" };

const response = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"visible text\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"total_tokens\":105,\"prompt_tokens_details\":{\"cached_tokens\":10},\"completion_tokens_details\":{\"reasoning_tokens\":0}}}";

fn allocationCase(a: std.mem.Allocator) !void {
    const wire = try encode(a, fixture, null);
    defer a.free(wire);
    const out = try decode(a, response);
    defer a.free(out.text);
}
