//! Separate owned-loopback integration test root; no production entry point.
comptime {
    _ = @import("tests/systemone_http_test.zig");
}
