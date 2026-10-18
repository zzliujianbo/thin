//! Owned CONNECT/target TLS fixtures; run with zig build test-proxy only.
test {
    _ = @import("tests/proxy_http_test.zig");
}
