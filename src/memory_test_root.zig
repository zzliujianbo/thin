//! Offline automatic-memory contracts, storage, extractor and coordinator.
test {
    _ = @import("core/knowledge.zig");
    _ = @import("core/knowledge_codec.zig");
    _ = @import("tools/knowledge_store.zig");
    _ = @import("tools/memory_queue.zig");
    _ = @import("tools/memory_forget_test.zig");
    _ = @import("tests/automatic_memory_runtime_test.zig");
    _ = @import("app/memory_client.zig");
    _ = @import("app/memory_service_test.zig");
    _ = @import("app/memory_app_test.zig");
    _ = @import("app/memory_lifecycle_test.zig");
}
