//! Offline provider-owned output length contract. No credentials or network.
const std = @import("std");
const cfg = @import("../core/config.zig");
const context = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const thinking = @import("../core/thinking.zig");
const providers = @import("../core/providers.zig");
const catalog = @import("../app/provider_catalog.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const anthropic = @import("../llm/anthropic.zig");
const j = @import("../util/json.zig");
