# 原生 macOS 支持（开发中）

## 分支与边界

- 特性分支：`feat/macos-support`；生产源码基线为 `main` 的 `85a53aa`。
- 本文件是仓库内的公开方案，`.gitignore` 仅为此文件开放例外，其余私有 docs/plans 仍保持忽略。
- Linux 主分支行为保持不变；完成稳定性与回归验收后再合并，不在适配过程中直接修改或合并到 `main`。
- 目标架构：macOS x86_64 和 aarch64；Zig 固定为 0.17.0。
- 最低系统版本须由 SDK/API、本地模式依赖和目标机器验收共同确定，暂不作版本兼容承诺。macOS 不以 libssh 作为依赖或版本门槛。
- 本文是实施计划，不是产品已支持 macOS 的声明。独立探针通过不代表 `thin` 已可构建或运行。

## 交付范围（按当前约定缩减）

- **做**：本地前台 CLI/TUI、`--print`、工具执行、Memory、本地 checkpoint 恢复、实例生命周期内的后台任务，以及本地安装/升级/回滚。
- **不做**：macOS SSH 入口、TCP SSH 监听、常驻 daemon、daemon 会话接入/断线续跑、launchd 或其他服务托管。这些不再是 macOS 发布或合并门槛，也不是需要补齐的“临时缺失”。
- **保留 Linux 功能**：不删除或禁用既有 Linux SSH、daemon 及其测试；Linux 回归仍覆盖原功能。
- **内部 worker/IPC 仍需做**：当前普通前台也启动实例自有 worker、使用本地 Unix socket 和部分 `daemon/` 下的共享代码。这不是用户级常驻 daemon，不能因取消 daemon 支持就整目录删除或跳过安全、回收与持久化边界。
- 本地 `--resume` 等 checkpoint 恢复继续保留；不为 daemon 会话额外实现 attach/takeover。若共享的 attach 逻辑是现有前台所必需，只处理本地所需路径。
- 本轮只是调整计划，尚未实现平台能力开关：当前 macOS 产品构建仍整体被拒绝。后续按下述构建/参数拒绝规则落实，不能把文档约定当成代码已完成。

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
| 构建与安装 | Darwin 使用 LLVM（自有后端限制见下文），macOS 不编译 SSH C 源、不链接/要求 libssh；移除 GNU 专属安装参数，保留原子替换和别名防覆盖；Linux 后端和依赖不变 |
| 服务托管 | macOS 不提供 launchd/常驻服务样例，不安装或隐式拉起服务 |

最新 SDK 存在的接口不一定支持旧系统。例如 `posix_spawn_file_actions_addfchdir` 从 macOS 26 提供，而 `_np` 版本从 10.15 提供；最低版本须显式约束。

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

- 已落地：特性分支、本文、P0 独立探针和失败清理回归；P1a 的文件系统后端、调用收口和原生测试入口。
- 本机候选机制：IPC 身份/目录锚定、WNOWAIT、组内状态分类、owner 死亡 EOF 已通过独立验证。
- 当前产品仍限制 Linux x86_64；新增显式 platform-only 测试模式，不提供 macOS `thin` 可执行文件。
- 未落地：P1 的终端、进程、通知、前台必需的 IPC/registry、平台能力隔离，以及缩减范围后的 P2–P4。SSH、常驻 daemon、launchd 不再列为 macOS 待办。
- 未证明：最低 macOS、原生 arm64、完整产品及 Linux 运行回归、生产并发/压力/异常注入门槛。
- 下一步：继续 P1 其余平台边界；不能把文件系统子集通过当作整个 P1 或产品验收通过。

### P1：平台基础

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

`platform-tests-only` 是显式的受限构建模式。默认安装、显式 install/run 必须失败，不创建产品；正常 macOS 构建仍被拒绝。`tests/macos/test_build_mode.py` 检查这些边界。Linux 正常产品构建仍使用原后端和依赖方式。

本机验证（macOS 26.7.2 x86_64 / Zig 0.17.0）：

- 文件系统 focused 根：Debug 和 ReleaseSmall 各 203/203 通过。
- presentation：Debug 和 ReleaseSmall 各 213/213 通过。
- Python 构建边界与 runner 清理回归：6/6 通过。
- Linux x86_64 focused 根交叉生成/链接 ELF；完整 unit 根及 memory 根语义编译通过，**未执行 Linux 测试**。
- Darwin arm64 focused 根交叉生成/链接 Mach-O，**未原生执行，也不代表 macOS 14 最低版本已验收**。

`daemon/unix.zig`、registry 等本轮只迁移通用文件/锁调用；其 statx 布局、socket、安全绑定与身份后端仍待后续 P1 实现。完整 Linux 运行回归是后续合并门槛，交叉编译不能替代。

### P2：本地产品闭环

完成本地 `--print`、前台 TUI、工具、Memory、本地恢复及当前实例内的后台任务。通过本机隔离 HTTP/TLS/代理和真实 PTY 验收，验证取消、恢复、权限、输出背压与前台退出后的资源回收。

不要求 macOS daemon/SSH 接入、脱离前台后的常驻任务或远程重连；增加不支持参数的负向验收，证明拒绝时没有监听、服务/worker 启动或模型请求等副作用。

### P3：本地安装与发布准备（范围已调整）

原 P3 的 macOS SSH、常驻 daemon 和 launchd 工作取消，不再是未完成项或合并条件。

仅保留本地安装脚本的 BSD 兼容、架构/依赖说明、升级与回滚；不安装或启用后台服务。发布的 macOS 本地版不依赖 libssh，需检查产物动态库依赖。只声明本地模式兼容，不声明 SSH/daemon 能力；Linux 相关部署样例保持原状。

### P4：发布与合并

- Linux x86_64 原有功能（含 SSH/daemon）继续回归；macOS x86_64、macOS aarch64 原生执行本地模式对应的 Debug 与 ReleaseSmall 回归，不要求 macOS SSH/daemon 验收。
- Linux 专属 seccomp/capabilities 探针保留，明确说明 macOS 的不同覆盖，不以移除平台检查代替验收。
- 覆盖退出、超时、忽略 TERM、组长先退出、owner 异常死亡、目录替换、硬链接/FIFO、防护文件、会话锁、IPC 身份和凭据输入。
- macOS 覆盖终端恢复、中文显示、尺寸变化、粘贴、背压、HTTP/TLS/代理、本地恢复及前台退出清理；覆盖不支持模式的明确拒绝和无副作用，不要求 SSH 断线重连或服务常驻。
- 对最低系统版本、两种架构、动态库依赖、安装/升级/回滚给出明确证据与说明。
- 清理不确定、身份校验缺失、数据损坏、终端状态未恢复等阻断问题未关闭时不合并。
- 合并前检查完整分支 diff；不自动 push、发布或合并到 `main`。
