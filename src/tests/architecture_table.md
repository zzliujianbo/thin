架构分层(src/)
| 目录 | 职责 |
|---|---|
| app/ | 进程装配与前端:cli 参数解析、app 资源聚合、session 会话、journal/log_store 诊断 jsonl、session 检查点内的选择元数据、auth_store 密钥存、provider_catalog 内置模型预设 |
| core/ | agent loop 状态机 runtime(模型调用→权限询问→工具执行→上下文压缩→终态)、protocol 协议类型、context token 预算与压缩、config 配置校验、providers 内置服务与凭据槽 |
| llm/ | HTTP 客户端、chat(Chat Completions)与 responses(Responses API)两套适配、sse 流解析、http_pool 连接复用 |
| tools/ | 内置工具 schema 与执行:read_file / write_file / bash / memory(与我手上的工具一一对应) |
| ui/ | tui(主交互界面)、input 行编辑、bridge 前端解耦、markdown 渲染、theme、command_menu 斜杠命令、model_picker/provider_picker 选择器 |
| presentation/ + presentation.zig | 与终端/libc 无关的前端中立展示层(可被其他前端导入) |
| platform/ | 进程、PTY 生成、文件系统、信号中断、termios ABI |
| util/ | JSON、文本宽度、行统计 |
