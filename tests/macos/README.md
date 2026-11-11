# macOS 分阶段验证（P0 / P1）

这里保存 [macOS 实施方案](../../docs/macos-support.md) 的独立机制探针与平台子集回归，**不是 `thin` 已兼容 macOS 的证明**。正常产品构建仍限制 Linux；不调用真实模型 API，不启动或安装系统服务，不打开 TCP 监听。

当前 macOS 目标仅为本地 CLI/TUI、`--print` 和本地会话/工具功能；SSH、常驻 daemon、launchd 不在范围内。前台必需的内部 worker/Unix IPC 仍须适配，Linux 原有 SSH/daemon 及测试不取消。

## P1a：原生文件系统回归

使用 Zig 0.17.0，无需 libssh、Node 或真实凭据：

```sh
zig build test-filesystem -Dplatform-tests-only=true --summary all
zig build test-filesystem -Dplatform-tests-only=true -Doptimize=ReleaseSmall --summary all
zig build test-presentation -Dplatform-tests-only=true --summary all
zig build test-presentation -Dplatform-tests-only=true -Doptimize=ReleaseSmall --summary all
```

`test-filesystem` 包含文件系统、认证、checkpoint、Memory 及相关纯模块。`src/tests/filesystem_portability_test.zig` 验证受保护名称的元数据比较、硬链接、无读权限、符号链接/FIFO/设备、目录替换、打开标志和 AGENTS/技能策略。它也进入 Linux 完整 unit 根。

`platform-tests-only` 不创建产品：默认安装和 install/run 都失败，正常 macOS 产品构建也仍失败；构建边界由 `test_build_mode.py` 验证。不要把本入口的成功解释为本地 CLI/worker 已完成 macOS 适配。后续本地产品须不依赖 libssh，并明确拒绝 daemon/SSH 参数；这些能力开关尚待实现。

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

## 与现有纯 Zig 测试交叉验证

也可直接检查前端中立模块，等价于上面的受限 test-presentation 入口（仍不是完整产品测试）：

```sh
cache=$(mktemp -d)
zig test src/presentation.zig -fllvm --cache-dir "$cache/debug"
zig test src/presentation.zig -fllvm -O ReleaseSmall --cache-dir "$cache/small"
rm -rf "$cache"
```

本机 Zig 0.17.0 的 `-fno-llvm` 产物被 dyld 以 `__CONST_ZIG` 段顺序错误拒绝加载；不要把这个未修复后端当作 Darwin 验收路径。当前 Darwin 独立测试已选择 LLVM；完整生产构建仍待后续 P1/P2。

## 交叉构建（不执行）

以下只检查生成/链接或语义编译，不能替代目标机器回归。跨架构测试必须带 `--test-no-exec`，不要尝试在 Intel Mac 上执行 arm64 产物：

```sh
cache=$(mktemp -d)
zig test src/filesystem_test_root.zig -lc -fno-llvm -target x86_64-linux-gnu --test-no-exec -femit-bin="$cache/fs-linux" --cache-dir "$cache/linux"
zig test src/root.zig -lc -fno-llvm -target x86_64-linux-gnu -fno-emit-bin --cache-dir "$cache/linux"
zig test src/memory_test_root.zig -lc -fno-llvm -target x86_64-linux-gnu -fno-emit-bin --cache-dir "$cache/linux"
zig test src/filesystem_test_root.zig -lc -fllvm -target aarch64-macos.14.0 --test-no-exec -femit-bin="$cache/fs-arm64" --cache-dir "$cache/arm64"
rm -rf "$cache"
```

## 本机验证记录

环境：macOS 26.7.2 x86_64、Zig 0.17.0、Apple clang 21、Python 3.13.1。

- 两个 C 探针使用 `zig cc` 重复 10 次通过，并使用系统 clang 编译执行通过。
- runner 清理回归 3 项、构建边界回归 3 项通过；现有 `tests/test_workflow.py` 回归 9 项通过。
- 文件系统 focused 根 Debug 与 ReleaseSmall 各 203/203 通过。
- 前端中立 Zig 测试：LLVM Debug 与 ReleaseSmall 各 213/213 通过；非 LLVM 的已知失败如上。
- 两个 C 探针及文件系统 focused 根以 `-target aarch64-macos.14.0` 交叉编译/链接通过；未原生执行，不据此确定系统最低版本。
- Linux x86_64 focused 根生成/链接 ELF；完整 unit 根与 memory 根语义编译通过，未运行 Linux 测试。
- 纯 libproc 的僵尸查询曾失败；当前通过的是带有实际 sysctl 元数据补充的候选机制，不是跳过失败项。

## 尚未证明

- 探针结果不代表生产 `spawn`、前台 IPC、Runtime 或 TUI 已完成移植。SSH、常驻 daemon、launchd 已排除在 macOS 范围之外，不是待补齐的验收项。
- `fork` 只是这里创建实验 fixture 的方式，不代表生产后端已选定多线程 fork。
- 同 UID 的自有连接不代替跨 UID、real/effective credentials 差异及完整攻击面验证。
- 目录替换是受控注入，不代表完整并发竞态、socket 叶节点替换、恶意 SCM 消息或资源压力已验收。
- `LOCAL_PEERPID` 和 fd 归属仍需覆盖生产中所有转交路径；不把 audit token 宣称为冻结的连接时身份。
- 元数据失败注入不代替真实权限/资源错误测试；探针不覆盖所有 `libproc/sysctl` 截断和进程退出竞态，也不证明生产级父进程监测已正确接入取消流程。
- 当前机器的通过不代表 Apple Silicon 或最低 macOS 版本通过。
- 正式合并仍须满足主方案缩减后的 P1–P4、本地模式/不支持参数负向验收，以及 Linux 原有功能回归门槛；不要求 macOS SSH/daemon 测试。
