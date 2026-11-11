# macOS 分阶段验证（P0 / P1）

这里保存 [macOS 实施方案](../../docs/macos-support.md) 的独立机制探针与平台子集回归。当前 Intel Mac 本地产品已合并，支持本地 CLI/TUI，不支持 SSH 或常驻服务。下文测量是原 macOS 分支的历史记录，不是本轮测试迁移后的新 Mac 验收；探针本身不替代产品验收。

当前 macOS 目标仅为本地 CLI/TUI、`--print` 和本地会话/工具功能；SSH、常驻 daemon、launchd 不在范围内。前台必需的内部 worker/Unix IPC 仍须适配，Linux 原有 SSH/daemon 及测试不取消。

## P1a：原生文件系统回归

使用 Zig 0.17.0，无需 libssh、Node 或真实凭据：

```sh
zig build test-filesystem -Dplatform-tests-only=true --summary all
zig build test-filesystem -Dplatform-tests-only=true -Doptimize=ReleaseSmall --summary all
zig build test-presentation -Dplatform-tests-only=true --summary all
zig build test-presentation -Dplatform-tests-only=true -Doptimize=ReleaseSmall --summary all
zig build test-terminal -Dplatform-tests-only=true --summary all
```

`test-filesystem` 包含文件系统、认证、checkpoint、Memory 及相关纯模块。`tests` 中的文件系统测试验证受保护名称的元数据比较、硬链接、无读权限、符号链接/FIFO/设备、目录替换、打开标志和 AGENTS/技能策略，也进入 Linux 完整 unit 根。测试源由 `tests/layout.json` 映射，在本地缓存中组合后编译；不要直接对业务 `src` 运行 `zig test`，否则可能得到零测试的假成功。

`platform-tests-only` 不创建产品：默认安装和 install/run 都失败；构建边界由 `test_build_mode.py` 验证。正常 Intel Mac 本地产品构建已开放，不依赖 libssh，并明确拒绝 daemon/SSH 参数；本平台子集入口仍不替代完整产品验收。

## P0：独立机制探针

C 探针需要原生 macOS、Python 3、Zig 0.17.0（或 Xcode Command Line Tools 的 clang）；P1 构建边界测试必须使用 Zig：

```sh
python3 -B tests/macos/run.py
python3 -B tests/macos/run.py --repeat 10
python3 -B tests/macos/run.py --cc clang
python3 -B tests/macos/run.py --probe ipc
python3 -B -m unittest discover -s tests/macos -p 'test_*.py' -v
```

默认编译器为 `$CC`，未设置时使用 `zig cc`。C 编译启用 `-std=c11 -Wall -Wextra -Werror`；源码使用系统头文件，不手写 Darwin 结构 ABI。二进制与 IPC fixture 位于 runner 在 `/private/tmp` 创建的私有临时目录，不产生仓库内构建产物；`THIN_MACOS_P0_TMPDIR` 只负责向 IPC 探针传递这个目录。

探针只管理自己创建的子进程、进程组和临时目录；父端轮询/等待有 deadline，失败也执行回收。runner 为命令创建独立 session，超时或中断时先 TERM，再在不 reap 组长的情况下发最终组 KILL；C 进程探针须在 TERM 宽限期内回收它另建的进程组。临时目录由 Python 兜底移除。`test_runner.py` 覆盖 leader 在 TERM 后退出、同组 child 忽略 TERM 的失败路径。不要以 root 或 setuid 身份运行；真实/有效 UID 和 GID 不一致不在此探针覆盖范围内。

## 覆盖范围

### `ipc_probe.c`

- 单线程 helper 从已打开的目录 fd `fchdir`，绑定单组件相对名。
- 通过 `SCM_RIGHTS` 传回已绑定但未监听的 socket，helper 关闭副本并退出。
- 实际服务进程负责 `listen`；客户端在 accept 前后读到的 PID 都必须是该服务进程，而非 helper。
- 服务端校验客户端的内核 PID/UID/GID；错误的预期 PID 不匹配。
- socket 节点为本 UID、0600；连接配置 `SO_NOSIGPIPE`，关闭对端后的写入不会杀死测试进程。
- 在 bind 之前、之后分别替换目录路径，验证 socket 仍落在原目录 inode，错误的发布路径被拒绝。
- 清理前校验 socket 类型、UID、dev/inode，拒绝删除被替换成普通文件的节点。

`SO_NOSIGPIPE` 在连接建立且对端尚未关闭时设置。这也是后续生产后端应采用的初始化时序；不应等首次写失败后再补设选项。

### `process_probe.c`

- `waitid(WNOWAIT)` 重复观察后，仍可由精确 `waitpid` 回收原始退出状态。
- 从单个 PID 的缓冲区开始扩容，完整列出组长和后台后代。
- 区分“两个活成员”“僵尸组长 + 活后代”“仅僵尸组长”；组长始终保持未 reap，最后组信号之后才释放 PID 所有权。
- 仅有 libproc 不足：本机 `PROC_PIDTBSDINFO` 无法读取僵尸；补用 `sysctl(KERN_PROC_PID)` 并验证结构长度、PID、组和状态，不以 ESRCH 直接推断死亡。
- 元数据失败注入必须报错，不能误判空组。
- owner 被 SIGKILL 后，worker 的专用生命周期管道先从“非 EOF”变成 EOF；该机制不依赖 TUI。
- 主探针收到 TERM/INT 后进入有界清理，子 fixture 恢复默认信号行为。

本机对 all-zombie 组发送 KILL 可能返回 EPERM。fixture 清理只在其专用完成管道已 EOF、精确 WNOWAIT 也证明组长已退出时接受；该特例不能直接作为生产清理成功的普遍规则。

## 前端中立测试入口

使用上面的 `zig build test-presentation -Dplatform-tests-only=true` 标准入口；测试通过 layout 与缓存组合恢复，不再直接测试业务源文件。

历史分支记录中，本机 Zig 0.17.0 的非 LLVM 产物曾被 dyld 以 `__CONST_ZIG` 段顺序错误拒绝加载。当前 Darwin 构建使用 LLVM；后续本地产品验收记录见主方案 P2。

## 历史交叉构建说明（未执行目标测试）

原分支曾对 Linux x86_64 与 Darwin arm64 测试根作生成、链接或语义检查，结果记录在下文。原始测试根现已迁入 `tests`，旧 raw 命令不再适用。产品 `check` 的跨编译也只证明产品编译，不代表目标平台测试已运行；这些历史结果不扩大当前 Intel Mac 范围。

## 原 macOS 分支本机验证记录（历史）

环境：macOS 26.7.2 x86_64、Zig 0.17.0、Apple clang 21、Python 3.13.1。

- 两个 C 探针使用 `zig cc` 重复 10 次通过，并使用系统 clang 编译执行通过。
- runner 清理回归 3 项、构建边界回归 3 项通过；现有 `tests/test_workflow.py` 回归 9 项通过。
- 文件系统 focused 根 Debug 与 ReleaseSmall 各 203/203 通过。
- 前端中立 Zig 测试：LLVM Debug 与 ReleaseSmall 各 213/213 通过；非 LLVM 的已知失败如上。
- 两个 C 探针及文件系统 focused 根以 `-target aarch64-macos.14.0` 交叉编译/链接通过；未原生执行，不据此确定系统最低版本。
- Linux x86_64 focused 根生成/链接 ELF；完整 unit 根与 memory 根语义编译通过，未运行 Linux 测试。
- 纯 libproc 的僵尸查询曾失败；当前通过的是带有实际 sysctl 元数据补充的候选机制，不是跳过失败项。

## 尚未证明

- 这些探针结果本身不证明生产 `spawn`、前台 IPC、Runtime 或 TUI 的验收；本地产品已有后续分支验收记录，见主方案 P2。SSH、常驻 daemon、launchd 已排除在 macOS 范围之外，不是待补齐的验收项。
- `fork` 只是这里创建实验 fixture 的方式，不代表生产后端已选定多线程 fork。
- 同 UID 的自有连接不代替跨 UID、real/effective credentials 差异及完整攻击面验证。
- 目录替换是受控注入，不代表完整并发竞态、socket 叶节点替换、恶意 SCM 消息或资源压力已验收。
- `LOCAL_PEERPID` 和 fd 归属仍需覆盖生产中所有转交路径；不把 audit token 宣称为冻结的连接时身份。
- 元数据失败注入不代替真实权限/资源错误测试；探针不覆盖所有 `libproc/sysctl` 截断和进程退出竞态，也不证明生产级父进程监测已正确接入取消流程。
- 当前机器的通过不代表 Apple Silicon 或最低 macOS 版本通过。
- 本轮测试源码迁移后的 Mac 回归尚未执行；不得把上述历史记录当作本轮验收，不要求 macOS SSH/daemon 测试。
