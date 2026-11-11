//! 工具层集成测试：验证路径约束、memory 命名空间保护、审批前的校验，以及文件/命令工具结果的 UTF-8 与续读偏移。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const t = @import("../tools/tools.zig");
const j = @import("../util/json.zig");

/// 测试用配置：provider 地址为不可达的占位主机，防止误连真实服务。
const configuration = cfg.Config{
    .limits = .{ .low_price_input = false },
    .provider = .{ .base_url = "http://unused.invalid", .api_key_env = "FAKE_KEY" },
    .model = .{ .name = "fake", .context_tokens = 32768 },
};

// 验证：写入 .thin 或 memory 目录被拒绝（UseMemoryTool），越界写入被拒绝（OutsideRoot），合法 memory 写入只生成待审批描述且不落盘。

// 验证：文件读取的 offset/limit 按字节计算但不切断 UTF-8 字符，bash 输出中的 UTF-8 保持完整。

// 逐个失败分配点注入 OOM：原子提交若已成功，工具必须能返回预先准备的成功结果。
