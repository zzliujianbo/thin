# 原生 macOS 支持（开发中）

## 分支与边界

- 特性分支：`feat/macos-support`；生产源码基线为 `main` 的 `85a53aa`。
- 本文件是仓库内的公开方案，`.gitignore` 仅为此文件开放例外，其余私有 docs/plans 仍保持忽略。
- Linux 主分支行为保持不变；完成稳定性与回归验收后再合并，不在适配过程中直接修改或合并到 `main`。
- 当前目标架构仅为 **macOS x86_64（Intel Mac）**；Zig 固定为 0.17.0。Apple Silicon/aarch64 适配和实机验收明确不做，不列为待办或完成门槛；已有通用代码不因此删除。
- 最低 macOS 版本及其他 Mac 机器的兼容验证明确不做，不列为待办、发布或完成门槛；仅报告当前机器实测环境，不作未经验证的版本/异机兼容承诺。macOS 不以 libssh 作为依赖或版本门槛。
- 本文记录实施计划与实测证据：当前 Intel Mac 已通过本地模式构建、单元及隔离端到端验收，但不据此承诺最低系统版本、其他机器或生产压力下的发布兼容性。

## 交付范围（按当前约定缩减）

- **做**：本地前台 CLI/TUI、`--print`、工具执行、Memory、本地 checkpoint 恢复及实例生命周期内的后台任务。用户随后追加授权 `install.sh` 的 Intel macOS 安装适配及隔离验收；真实系统安装仍由用户手动操作。
- **不做**：macOS SSH 入口、TCP SSH 监听、常驻 daemon、daemon 会话接入/断线续跑、launchd 或其他服务托管。这些不再是 macOS 发布或合并门槛，也不是需要补齐的“临时缺失”。
- **保留 Linux 功能**：不删除或禁用既有 Linux SSH、daemon 及其测试；Linux 回归仍覆盖原功能。
- **内部 worker/IPC 仍需做**：当前普通前台也启动实例自有 worker、使用本地 Unix socket 和部分 `daemon/` 下的共享代码。这不是用户级常驻 daemon，不能因取消 daemon 支持就整目录删除或跳过安全、回收与持久化边界。
- 本地 `--resume` 等 checkpoint 恢复继续保留；不为 daemon 会话额外实现 attach/takeover。若共享的 attach 逻辑是现有前台所必需，只处理本地所需路径。
- 产品能力开关与 Darwin 本地后端代码已完成，本机 Debug/ReleaseSmall 产品构建、完整单元和四套既有本地端到端验收均通过；最低 macOS 版本及其他 Mac 机器验证明确排除。
- 先按用户要求完成代码、统一构建/单元测试并停止；随后经明确授权完成既有 CLI/TUI 端到端验收，再追加安装脚本适配及临时目录验收。用户现已授权提交并推送 `feat/macos-support`；不向真实安装目录安装，不发布或合并到 `main`。

## 不可降低的约束

1. 文件访问保留 dirfd 锚定、逐级 nofollow、设备/inode 身份复核、原子发布与固定 inode 锁。
2. IPC 必须双向校验内核身份，保留 `hello.pid == kernel peer_pid`；身份不可用时拒绝连接。
3. 超时或取消后执行有界 TERM → KILL 清理；未确认清理不能报告成功。最终组信号前保留直接子进程的 PID 所有权。
4. 前台 owner 退出/崩溃时必须有界回收自己的 worker 与工具子进程；后台任务只在当前实例生命周期内运行。既有 Linux daemon 的断连语义保持不变，但不要求在 macOS 实现。
5. 凭据不进入命令行，不通过普通磁盘临时文件替代匿名 curl 输入；取消后 join 所有借用输入的任务。
6. 会话恢复不得自动重放模型请求或工具调用。

## 平台拆分

保持 Runtime、模型协议和主要渲染逻辑不变，在 `src/platform/` 的公共接口后选择 Linux/Darwin 实现。逐步移除 `app/`、`core/`、`tools/`、`daemon/` 对 `fs.linux`、Linux errno、`statx` 的直接依赖；不为没有差异的逻辑复制整套后端。

| 范围 | Darwin 候选实现 / 验收重点 |
| --- | --- |
| 文件元数据 | `fstat/fstatat` 与统一文件身份；优先采用 Zig 正确处理 ABI 别名的声明或窄 C shim |
| 受保护对象身份 | 已改为固定候选 fd + 无跟随叶节点元数据比较；不在 Darwin 仿造 `O_PATH`，不使用会进入设备 open 的 `O_EVTONLY` |
| 系统路径 | 明确处理 `/tmp`、`/var` 系统别名；不放开任意项目路径的符号链接 |
| 进程启动 | 评估 `posix_spawn`、明确 fd allowlist、cwd fd、信号掩码与进程组；启动失败不能通知为已执行 |
| 退出与回收 | Darwin `waitid(WNOWAIT)` + 精确 `waitpid`；`libproc` 枚举组成员，必要时以 `sysctl(KERN_PROC_PID)` 补充僵尸元数据；检测截断、查询失败与 deadline |
| owner 生命周期 | 专用生命周期管道，只有 owner 持有写端；EOF 触发 worker 取消，不复用 TUI 连接 |
| Unix socket | `getpeereid` + `LOCAL_PEERPID`；独立 helper 仅 bind，再传 fd 给实际进程 listen；须先通过 P0 |
| 终端 | Linux 保留显式 glibc ABI，Darwin 使用经 canary/roundtrip 验证的 ABI；平台化 ioctl/flags/errno/locale |
| 通知 | 非阻塞管道，写满合并通知，drain 后复查真实队列；关闭前 join 所有生产者 |
| curl 输入 | 可取消的有界并发管道，防止大配置死锁，保留不落盘和密钥不进入 argv 的边界 |
| SSH / 常驻 daemon | 不做 macOS 后端；编译期排除监听器、SSH C 源和 daemon supervisor，保留前台需要的共享 worker/IPC；Linux 现有路径不变 |
| 构建与安装 | Darwin 使用 LLVM（自有后端限制见下文），macOS 不编译 SSH C 源、不链接/要求 libssh；Linux 后端和依赖不变。`install.sh` 支持系统 Bash 3.2 与 BSD 工具；Darwin 用系统 Perl 的原子 symlink/rename 保留 exact-leaf 发布语义 |
| 服务托管 | macOS 不提供 launchd/常驻服务样例，不安装或隐式拉起服务 |

最新 SDK 存在的接口不一定支持旧系统。例如 `posix_spawn_file_actions_addfchdir` 从 macOS 26 提供，而 `_np` 版本从 10.15 提供；这里只记录 API 差异，不扩展最低版本或异机验收。

## 阶段与门槛

### P0：风险验证

先编写独立探针，不改变生产构建的平台限制，不接触真实模型 API、系统服务、SSH 配置或外部监听。

- IPC：helper 在目录 fd 内绑定单组件名称，以 `SCM_RIGHTS` 传回已绑定未监听的 socket；实际服务进程复核节点后 listen。
- 验证 helper 退出、fd 转交以及 accept 前后，客户端仍看到真实服务进程 PID；服务端看到真实客户端 PID/UID。
- 目录被 rename/替换时，bind 必须仍落在原 inode，且绝不发布错误路径；清理只允许删除匹配的 socket inode。
- 进程：`WNOWAIT` 保留回收权；僵尸组长不能掩盖活后代；只有僵尸的组与仍有执行进程的组必须可区分。
- owner 被 SIGKILL 后，worker 的专用生命周期管道必须收到 EOF；不允许其他进程继承写端而使检测失效。
- 验证这些候选机制不等于已完成生产级并发、异常注入和资源压力验收。

独立探针入口与结果说明见 `tests/macos/README.md`。

#### 已验证的工具链约束

在 macOS 26.7.2 x86_64、Zig 0.17.0 上直接测试 `src/presentation.zig`（绕过产品构建的平台限制）：

- `-fllvm` Debug：213/213 通过。
- `-fllvm -O ReleaseSmall`：213/213 通过。
- `-fno-llvm`：生成的测试程序被 dyld 以 `segment '__CONST_ZIG' vm address out of order` 拒绝加载，未修复该编译器后端问题。

因此后续 Darwin 构建必须显式选择已验证的 LLVM 路径，不能沿用当前全局 `use_llvm=false`。这不表示生产 `zig build` 已通过，也不替代 Linux 回归。

两个 C 探针另以 `zig cc -target aarch64-macos.14.0` 交叉构建出 arm64 Mach-O；这里只确认可编译/链接，没有在 arm64 或 macOS 14 上执行，不能据此确定最低系统版本。

#### 已验证的进程查询约束

`proc_listpgrppids` 能列出未回收的僵尸组长，但本机 `proc_pidinfo(PROC_PIDTBSDINFO)` 对它返回 `0/ESRCH`。纯 libproc 候选在“僵尸组长 + 活后代”和“仅僵尸组长”两种场景均失败，不能把 ESRCH 当作已退出或空组。

探针改为仅在该情形下调用 `sysctl(KERN_PROC_PID)`，要求完整结构、正确 PID/进程组和有效状态，再进行分类。这样保留了对活后代与僵尸的区分。元数据失败注入必须返回不确定/错误，不得得到空组。

这是已验证的补充查询机制，不是生产级并发扫描策略已完成：实际后端仍须处理列表变化、权限不足、截断及持续 fork 等情况。

#### 当前落地状态

- 已验证基础：P0 独立机制、P1a 文件系统，以及 P1b 终端/通知独立测试。
- 已实现并通过完整单元及本地端到端：Darwin 进程启动/回收、本地 IPC/registry、owner 生命周期管道、匿名请求输入、产品构建与能力隔离；Runtime、工具、Memory、checkpoint 和实例后台任务通过这些共享边界运行，不重写业务协议。
- macOS 构建图已开放 x86_64/aarch64 本地产品；不编译 SSH C 源、不链接 libssh。`check` 只编译，不安装或执行产品。
- 最新验证：本机 macOS x86_64 Debug/ReleaseSmall 产品与 PTY 驱动构建通过，两模式完整 unit 根各 **1903 通过、9 项 Linux 专属跳过、0 失败**；四套既有端到端两模式均通过，详见 P2。
- 最终修复后 Linux x86_64 完整 unit 根语义编译通过，没有 Linux 原生执行。此前 Darwin arm64 产品交叉链接通过，未在最终修复后重跑，也不属于本轮交付范围。
- Linux 原生运行及生产压力未验证；mock 验收不等于真实提供方或外网 TLS/代理已验证。最低 macOS 版本、其他 Mac 机器及 Apple Silicon 验证明确定为不做，不是待办或完成门槛。以上端到端阶段未运行安装、发布、推送或合并；后续安装脚本与推送授权见 P3。

### P1：平台基础

**执行优先级：先打通 macOS 本地 CLI 的 `--print` 编译与运行主链路。** 不擅自扩展额外探针或验收范围；主链路不依赖的完善项后置。保留必要回归以及既定文件/IPC 安全、实例自有进程有界回收约束，不用跳过平台实现换取表面编译成功。

收口文件身份、flags/errno、终端 ABI、启动/回收、通知、可执行文件定位与 IPC。平台单元测试、竞态测试通过，Linux 对应回归不退化。

只移植前台必需的内部 worker、Unix socket、发现/写租约及回收逻辑；不移植常驻 daemon supervisor。不能以“不启用 daemon”为理由跳过前台实际使用的平台层，也不在本轮擅自改成单进程架构。

构建与能力隔离还须实现：

- macOS 产品不编译 `ssh_keys.c` / `ssh_transport.c`，不要求 libssh 头文件或动态库；终端/入口的 SSH 引用通过编译期分派或明确的禁用实现隔离，不能为满足链接而保留实际监听/认证路径。
- macOS 的 `--daemon`、`--connect`、`--ssh-listen` 和内部 SSH 入口应明确报告不支持；禁用功能不能静默降级到前台、打开端口、启动 worker 或发起模型请求。帮助信息应反映平台能力。
- 内部 worker 只启用前台 owner 路径，不接受 daemon owner；本地 checkpoint 恢复仍按原先安全规则执行。
- Linux 产品仍编译并运行原 SSH/daemon 路径，不通过全局删除模块或改为一律禁用来实现 macOS 范围缩减。

#### P1a：文件系统（已实现，待完整平台回归）

- `src/platform/filesystem_native.zig` 收口 typed `std.c.O`、flock、符号 errno 与设备/inode 身份。Linux 使用 statx；Darwin 使用 std.c 正确选择 ABI 的 fstat/fstatat。
- 移除 `fs.linux` 接口及调用方的 Linux 文件打开位、锁位和错误编号。保留原 flags 和策略，包括技能目录发现允许的符号链接，不顺便放宽或收紧业务权限。
- 移除只适用于 Linux 的公开 `openPath`：工具保护检查改用 `sameObjectAt(candidate_fd, parent_fd, leaf)`。候选 fd 全程保持打开，固定其 inode；受保护名称只做无跟随元数据查询，不读取内容、不打开 FIFO/设备、不缓存结果，也不承诺锁住未来的命名空间变更。
- 不能使用 `O_EVTONLY` 冒充 O_PATH：核查 XNU 后确认仍可能进入 VNOP_OPEN/设备驱动 open。此次实现通过避免打开受保护叶节点解决需求，而不是模拟元数据句柄。
- `src/tests/filesystem_portability_test.zig` 覆盖硬链接、无读权限文件、符号链接/FIFO/设备元数据、目录/叶节点替换、flags，以及 AGENTS/技能发现策略；同时进入完整 Linux unit 根。
- `src/filesystem_test_root.zig` 独立组合文件、认证、checkpoint、Memory 和相关纯模块测试，不导入 TTY、SSH、worker 传输。
- 日志测试的 fd 计数在 Darwin 使用 `/dev/fd`，仅用于测试，不是 IPC 的 fd 锚定绑定替代方案。

运行入口：

```sh
zig build test-filesystem -Dplatform-tests-only=true --summary all
zig build test-filesystem -Dplatform-tests-only=true -Doptimize=ReleaseSmall --summary all
zig build test-presentation -Dplatform-tests-only=true --summary all
```

`platform-tests-only` 是显式的受限构建模式。该模式默认安装、显式 install/run 必须失败，不创建产品；正常 macOS 产品构建已开放并通过后续集中验证。`tests/macos/test_build_mode.py` 检查这些边界。Linux 正常产品构建仍使用原后端和依赖方式。

本机验证（macOS 26.7.2 x86_64 / Zig 0.17.0）：

- 文件系统 focused 根：Debug 和 ReleaseSmall 各 203/203 通过。
- presentation：Debug 和 ReleaseSmall 各 213/213 通过。
- Python 构建边界与 runner 清理回归：6/6 通过。
- Linux x86_64 focused 根交叉生成/链接 ELF；完整 unit 根及 memory 根语义编译通过，**未执行 Linux 测试**。
- Darwin arm64 focused 根交叉生成/链接 Mach-O，**未原生执行，也不代表 macOS 14 最低版本已验收**。

P1a 当时只迁移通用文件/锁调用；`daemon/unix.zig`、registry 的其余后端现已在后续代码中实现，验证状态见当前落地状态。完整 Linux 运行回归是后续合并门槛，交叉编译不能替代。

#### P1b：终端与通知（核心及本地产品验收已通过）

- Darwin 使用 libc termios ABI；Linux 保留原 glibc 60 字节布局及 SSH 路径。终端 flags、errno、ioctl、poll 和流控按目标平台处理，macOS 终端链路不引用 SSH C 符号。
- Darwin wakeup 使用 NONBLOCK/CLOEXEC pipe，保留 Linux eventfd；pipe drain 有界，调用方仍以实际工作队列为准。pipe+fcntl 不具备原子 CLOEXEC 保证，后续 spawn 必须使用默认关闭及明确 FD 白名单。
- locale 只设置 CTYPE，保留其他类别；启动时间使用目标 `time_t`。独立 C SDK 检查校验 termios、locale、ioctl 和流控 ABI；Darwin 恢复比较只排除内核维护的 PENDIN/FWASWRITTEN 状态。
- `zig build test-terminal -Dplatform-tests-only=true --summary all`：终端根 Debug/ReleaseSmall 各 301/301 通过。Linux 完整 unit/终端根语义编译、Darwin arm64 终端根链接通过，均不代表异机原生执行。
- 撤掉偏离优先级的额外 controlling-PTY 探针，不恢复该探针。本地产品闭环改用既有 PTY 夹具，实测结果见 P2，平台测试本身不替代产品验收。

#### P1c：其余本地后端与产品入口（代码与集中单元验证完成）

- `darwin_process.c` / `process_darwin.zig`：posix_spawn、cwd dirfd、信号/进程组、默认关闭及 FD 白名单、WNOWAIT、libproc/sysctl 组状态分类、有界回收；保留 Linux fork/procfs 路径。
- `metadata.zig` / `ipc_native.zig` / `darwin_ipc.c`：目标元数据、已知系统路径别名、dirfd 锚定 helper bind/SCM_RIGHTS、真实服务 listen、内核 peer PID/UID、身份一致才清理。
- `daemon/spawn.zig` / `worker.zig`：Darwin 只允许前台 owner，专用 pipe 检测 owner 死亡；仅传 reader，退出取消/join/保存；共享通信按目标 errno/poll 运行。
- `anonymous_input.zig`：Linux 保留 memfd，Darwin 并发有界可取消 pipe 输入；借用配置在退出前 join，不落普通磁盘文件、不把密钥放进 argv。
- `capabilities.zig` / CLI / 入口：Mac 不支持的服务/SSH 模式在配置、worker 或请求创建前拒绝；Linux 服务功能保持原路径。帮助文本区分平台。
- `build.zig`：Darwin LLVM + 本地 C shim，Linux 保留原后端/libssh；新增 `check` 编译步骤，不触发安装。

集中验证入口为 `zig build check test-unit --summary all` 及 ReleaseSmall 单元测试；这些不是安装或端到端验收。遇到测试崩溃使构建 runner 等待时，实际采用编译完整 unit 根后直接执行二进制记录全部进度，该阶段两模式各 1902 通过、9 跳过、0 失败；P2 修复后再次完整回归，最新为各 1903/9/0。Darwin 配置 32 MiB 主栈，避免 LLVM Debug 下多个有界 metadata/Session 副本导致栈溢出，Linux 栈策略不变。

集中修复包含：SCM_RIGHTS 接收前保留原 socket FD 引用（避免 XNU 将监听器标记读关闭）、PTY 测试目标 NONBLOCK/状态位、目标目录删除标志、配置 fixture 密钥可写所有权，以及平台化 help 断言。临时诊断已移除。不运行安装脚本，不自动发布或合并。

### P2：本地产品闭环

#### 当前追加验收（用户已授权，已完成）

上一轮在单元测试通过后按约定停止；用户随后明确授权继续 **Intel Mac CLI/TUI 端到端验证**。该端到端阶段不涉及 Apple Silicon、SSH、常驻 daemon、安装、推送或合并；后续安装与推送授权独立记录于 P3。

复用现有 `test-app`（含 CLI Chat/Responses、工具/审批、中文/流式/窗口变化及真实 checkpoint 恢复）、`test-memory-app`、`test-memory-background`、`test-background`。不运行依赖 daemon 的 resume-menu，也不为本轮引入 tmux/额外探针。所有应用只用独占 HOME/项目/XDG 与本地 loopback 模拟服务、伪凭据；不调用付费 API。

现有 PTY 夹具在 Darwin 由驱动/controller 持有 session，Thin 使用独立 foreground 进程组，使退出后仍可在原 slave 严格核对恢复（不重开终端伪造默认状态）；仅归一化已验证的 PENDIN/FWASWRITTEN。后台存活/退出用 kill(pid, 0) 与有界本机 ps 联合观察，僵尸/查询不确定不算已回收；成功必须同时证明 PID 消失及服务 loopback 连接被拒绝，fixture lease 保底只在成功断言之后或失败清理时使用。

本轮修复两个真实 Darwin 运行问题：

- `Root.open` 接受经根用户身份/预期目标核验的 `/tmp`、`/var` 系统别名；归一化集中于 `filesystem_native.systemPath`，其余项目符号链接仍被逐级 nofollow 拒绝。新增回归覆盖合法别名与用户链接拒绝。恢复夹具用真实 canonical 项目路径校验新上下文，不放松历史隔离断言。
- XNU 间接 `/dev/tty` 描述符可在 poll 中返回 POLLNVAL；Darwin C helper 改开内核报告的实际 tty 节点新描述符，并核对 nofollow、设备/inode、session 及 foreground group。Linux 仍使用原 `/dev/tty` 路径。临时生产诊断已移除。

最终本机结果（macOS 26.7.2 x86_64，Zig 0.17.0，LLVM，32 MiB 主栈）：

| 既有验收入口 | Debug | ReleaseSmall | 实际覆盖证据 |
| --- | --- | --- | --- |
| `app_mock.mjs`（`test-app`，不加子集参数） | 通过 | 通过 | 每模式 93 条 PASS 标签（含夹具自检）；CLI Chat/Responses、工具/取消、真实 PTY、selection restore、完整 Chat/Responses checkpoint 恢复 |
| `memory_auto_mock.mjs`（`test-memory-app`） | 通过 | 通过 | 每模式 primary=7、helper=5；先答后辅助、drain、保存/检索、Off、日志、无旧 jobs、interrupt |
| `memory_background_mock.py`（`test-memory-background`） | 通过 | 通过 | 每模式 3 个独占 PTY，primary=7、helper=7；运行中下一轮输入、FIFO、已保存事实、退出取消及原 slave 恢复 |
| `background_mock.py`（`test-background`） | 通过 | 通过 | 每模式 CLI 6 个并发真实 loopback 服务及退出回收；单 TUI 跨两任务保持同一服务、显式 stop、退出及原 slave 恢复 |
| 完整 `src/root.zig` 单元回归 | 1903 通过 / 9 跳过 / 0 失败 | 1903 通过 / 9 跳过 / 0 失败 | 包含本轮系统别名与 nofollow 回归；9 项为 Linux 专属 |

本机产物及日志目录：`/tmp/thin-macos-e2e.30XEQI`（临时证据，不是仓库产物）。最终文件为 `app-{debug,small}.log`、`memory-cli-{debug,small}.log`、`memory-tui-{debug,small}.log`、`background-{debug,small}.log`、`unit-{debug,small}.log`，产品与驱动在 `bin/`。完整 unit 根编译后直接运行，避免构建协议掩盖崩溃进度；Linux 最终语义检查见 `linux-semantic.log`。

复跑使用上述既有脚本与同模式产品/PTY 驱动，`TMPDIR=/tmp`；app 入口必须不带 `--resume-only` 或 `--selection-restore-only` 等子集开关。全部为私有配置与 loopback HTTP/真实 PTY，不以这些结果宣称真实提供方、外网 TLS/代理或生产压力已验证。本轮验收至此结束。

不要求 macOS daemon/SSH 接入、脱离前台后的常驻任务或远程重连；增加不支持参数的负向验收，证明拒绝时没有监听、服务/worker 启动或模型请求等副作用。

### P3：本地安装与发布准备（范围已调整）

macOS SSH、常驻 daemon、launchd、Apple Silicon、最低系统版本及其他 Mac 机器验证明确不做，不列为待办或完成门槛。

用户追加授权修改 `install.sh` 支持 Intel macOS 安装，并提交推送当前特性分支。脚本仍以当前用户构建 ReleaseSmall，只在目标目录需权限时使用 sudo，不改 shell 配置，不安装或启用服务。默认安装 `/usr/local/bin/thin` 并创建相对别名 `t -> thin`，可用 `INSTALL_DIR` 指定其他绝对目录；Zig 固定 0.17.0。

- Linux 保留 GNU `ln -sT` / `mv -fT`。Darwin BSD 工具没有等价 `-T`，使用预检后的系统 Perl `symlink` / `rename` 内建操作，精确作用于目标叶节点；不把目标目录当容器、不跟随指向目录的目标链接，保留原子替换及别名竞态拒绝。
- 移除 Darwin 不适用的调用形式；以函数而非空数组分派 sudo，兼容系统 Bash 3.2 的 `set -u`。仅允许 Intel Darwin；不为 Apple Silicon 扩展安装支持。
- 复用 `tests/install_test.sh`：Darwin 原生与 Linux 命令分派两种各 8 条 PASS，覆盖构建/复制/发布失败保护、临时文件清理、文件/链接/目录 alias 竞态、权限、含空格路径、重复升级、悬空别名和目标目录保护。Linux 分派在本机用受控包装器模拟 GNU exact-leaf 命令，不等同于 Linux 原生执行。
- 实际执行脚本构建并安装到 `/tmp/thin-macos-install.yxW73G/installed bin`：真实 ReleaseSmall 产品与 `t` 的 `--help` 一致，权限 0755，相对别名正确，无 libssh 动态依赖；未写真实安装目录。证据为同一临时目录的 `fixture-{Darwin,Linux}.log`、`actual-install.log`、`installed-help.log`、`alias-help.log`。
- 补齐既有 `test-terminal` 构建图对 Darwin C helper 的链接；`zig build test-terminal -Dplatform-tests-only=true --summary all` 再次通过 301/301 和独立 SDK ABI 检查，日志为 `terminal-build-regression.log`。此前 P2 完整单元/E2E 结果不重算为安装测试。

真实安装由用户手动运行：

```sh
./install.sh
# 或使用无需 sudo 的用户目录（PATH 由用户自行配置）
INSTALL_DIR="$HOME/.local/bin" ./install.sh
```

安装需要 Zig 0.17.0 及 macOS 编译工具链/SDK；Darwin 原子发布还需要系统 Perl，不要求 GNU coreutils、libssh 或 Python。不声明未测试的整机升级/回滚；Linux 部署样例保持原状。

### P4：发布与合并

- Linux x86_64 原有功能（含 SSH/daemon）继续回归；当前仅要求 macOS x86_64 原生执行本地模式对应的 Debug 与 ReleaseSmall 回归，不要求 Apple Silicon 或 macOS SSH/daemon 验收。
- Linux 专属 seccomp/capabilities 探针保留，明确说明 macOS 的不同覆盖，不以移除平台检查代替验收。
- 覆盖退出、超时、忽略 TERM、组长先退出、owner 异常死亡、目录替换、硬链接/FIFO、防护文件、会话锁、IPC 身份和凭据输入。
- macOS 覆盖终端恢复、中文显示、尺寸变化、粘贴、背压、HTTP/TLS/代理、本地恢复及前台退出清理；覆盖不支持模式的明确拒绝和无副作用，不要求 SSH 断线重连或服务常驻。
- 记录当前 Intel Mac 实测环境与动态库依赖；最低 macOS 版本、其他 Mac 机器、Apple Silicon、macOS SSH/常驻 daemon/launchd 明确不做，不作为待办或门槛。安装/升级/回滚由用户手动操作。
- 清理不确定、身份校验缺失、数据损坏、终端状态未恢复等阻断问题未关闭时不合并。
- 合并前检查完整分支 diff；仅按本次明确授权提交并推送 `feat/macos-support`，不发布或合并到 `main`。
