fn unexpectedPoll(_: []std.c.pollfd) c_int {
    @panic("empty free pool must not be polled");
}
