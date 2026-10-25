# 历史外部 sshd 入口：部署说明

> **当前入口已选择内嵌 SSH D 架构，见 [EMBEDDED-SSH.md](EMBEDDED-SSH.md)。** 下文及 `sshd_config.thin`、`sshd-thin.service` 保留为旧方案记录，不应按下文为 D 安装额外 sshd/PAM 入口。`thin-daemon.service` 默认无 TCP 监听；启用内嵌 SSH 需显式 `--ssh-listen`。以下历史记录不表示本轮内嵌 SSH 已完成验收或部署。

本文件说明如何部署本仓库 `deploy/` 下的样例。样例**未安装、未启用**，本文件中的命令只是步骤说明，**不执行**：不安装服务、不修改 `/etc/ssh`、PAM 或防火墙、不联网、不调用推理 API。

设计背景与产品决策见仓库外的方案草案 `thin-docs/daemon-ssh-sessions.md`。本文只讲部署边界与可审查的最简配置。

## 实现状态

本地代码（CLI、守护服务、前台 worker、typed TUI、客户端、会话注册表与写租约）及隔离离线验收入口均已落地。隔离验收覆盖：无服务时的拒绝、断线续跑、并行项目与 `/ls`、takeover 与前后台互通及历史、审批、守护服务停止时的资源回收。本文不报告具体测试数量；完整 Debug 与 ReleaseSmall 的聚合结果须以对应冻结源码上的验收证据为准，本文件不以局部通过替代完整通过。

`deploy/` 下的 SSH 样例**未安装、未启用**；真实 SSH/PAM/systemd/linger 登录链路、目标环境 logout 行为与 PTY 尺寸变化均未获授权、未执行。因此本文件不宣称任何环境已上线、已验证登录链路或已通过部署验收。第 5 节清单是部署后的人工检查项，不是本轮结果。

## 1. 运行模式

| 命令 | 行为 |
| --- | --- |
| `thin` | 默认前台模式。不监听端口、不启动常驻服务、不自动进入守护模式。 |
| `thin --daemon` | 显式进入该 UID 的守护服务模式，由 systemd 用户服务托管。 |
| `thin --connect` | SSH 的 ForceCommand 目标：TUI 连接本 UID 已运行的守护服务。 |
| `thin --attach <id>` / `thin --resume <id>` | 连接/恢复既有会话，同样不会隐式拉起守护服务。 |
| `thin --print "..."` | 一次性模式，与守护/连接模式互斥。 |

关键约束：

- 守护服务只能由 `thin --daemon` 显式启动。普通 `thin`、`--connect`、`--attach`、`--resume` 都不会启动它；守护未运行时 `--connect` 明确报错并非零退出，SSH 会话随即结束。
- `--connect` 不携带、也不接受 `--daemon` 参数；样例里的 ForceCommand 字符串由管理员固定，客户端无法追加参数。
- 三种模式互斥，冲突时明确报错，不静默切换。

## 2. 拓扑与所有权

```text
ssh -tt -p <PORT> <user>@<host>
        │  专用 OpenSSH 实例（独立端口，系统账户 + PAM，必须有 PTY）
        │  ForceCommand  = <install-dir>/thin --connect
        ▼
thin --connect  （以登录 UID 运行，随 SSH 断开退出，不持有任务所有权）
        │  本机 AF_UNIX，校验对端 UID
        ▼
systemd --user: thin-daemon  （独立生命周期，经管理员授权 linger 后与登录无关）
        ├── 会话 worker（各自项目根、Runtime、任务、子任务、后台命令）
        └── 会话与展示快照、写租约、checkpoint 保存
```

- 一个 OS 用户对应一个守护服务，再下面才是多个会话。会话数没有固定配额；资源不足时明确失败。
- worker 属于守护服务的 cgroup，不是 SSH 会话的子进程。SSH 断线只撤销视图与控制权，不取消任务。
- 每个会话始终只有一个 Runtime、一个工具执行 owner、一个 checkpoint 写租约。

## 3. 样例文件

| 文件 | 安装位置 | 安装者 |
| --- | --- | --- |
| `deploy/sshd_config.thin` | `/etc/ssh/sshd_config.thin`（0600 root） | 管理员 |
| `deploy/sshd-thin.service` | `/etc/systemd/system/sshd-thin.service` | 管理员 |
| `deploy/thin-daemon.service` | `~/.config/systemd/user/thin-daemon.service` | 该用户 |
| `deploy/daemon.env.example` | `~/.config/thin/daemon.env`（0600，需替换内容） | 该用户 |
| `deploy/check-samples.sh` | 不安装，仅本地静态校验 | 任何人 |

样例中的安装路径都是 `/usr/local/bin/thin`，与 `install.sh` 的 `INSTALL_DIR` 默认值一致。若改用其它目录，必须同时改 `sshd_config.thin` 的 ForceCommand 与 `thin-daemon.service` 的 ExecStart（`check-samples.sh` 会检查两处一致）。

标有 `THIN:REPLACE` 的行必须由部署者按本机情况替换：端口、允许账户、密钥值、必要时安装路径。样例**不能**原样上线。

`install.sh` 只安装二进制和 `t` 别名，不安装这些样例，也不创建 systemd 单元。

## 4. 部署步骤（仅说明，本轮不执行）

1. **安装二进制**：`./install.sh`（或 `INSTALL_DIR=... ./install.sh`）。样例要求的路径与之一致。
2. **凭据**：`install -Dm0600 deploy/daemon.env.example ~/.config/thin/daemon.env`，编辑该文件填入真实密钥，`chmod 600`。变量名必须与 `~/.thin/config.json` 中对应 provider 的 `api_key_env` 完全一致。
3. **守护服务**：复制 `thin-daemon.service` 到 `~/.config/systemd/user/`，`systemctl --user daemon-reload`，再 `systemctl --user enable --now thin-daemon`。
4. **退出登录后常驻**：需要管理员授权 `loginctl enable-linger <账户>`。没有 linger 时，用户 systemd 实例在该账户最后一个会话退出后会被清理，守护会话随之结束。不能靠在 SSH 里 `nohup`/后台启动替代这个授权。
5. **专用 SSH 入口**：把 `sshd_config.thin` 放到 `/etc/ssh/sshd_config.thin`（0600 root），先做只读语法校验：`sshd -t -f /etc/ssh/sshd_config.thin`；再安装 `sshd-thin.service` 并启用。该实例与管理用 sshd 完全独立。
6. **端口与防火墙**：开放 `THIN:REPLACE` 指定的端口、绑定地址与防火墙放行属于单独的部署授权；样例不改动任何防火墙规则，也不覆盖管理端口 22。
7. **回滚/停服**：见第 8 节。

## 5. 校验清单

只读校验（不启动服务）：

```sh
deploy/check-samples.sh                      # 样例与文档的静态安全默认值
sshd -t -f /etc/ssh/sshd_config.thin         # 需要管理员与已放置的配置
systemd-analyze --user verify ~/.config/systemd/user/thin-daemon.service
```

部署后人工确认：

- `ssh -tt -p <PORT> <user>@<host>` 只得到 Thin 界面；没有 shell 提示符。
- 不带 `-tt`（无 PTY）的连接被拒绝或以错误结束，不降级为一次性模式或 shell。
- `ssh -p <PORT> <user>@<host> true` 仍然只得到 Thin 界面（ForceCommand 覆盖客户端命令）。
- `ssh -L`/`-R`/`-A`/`-X` 在本入口失败（转发被关闭）。
- `ssh -p <PORT> root@<host>` 被拒绝。
- 在该账户 ~/.ssh/rc、~/.ssh/environment 放置标记内容不生效（`PermitUserRC no`、`PermitUserEnvironment no`）。
- `ss -ltnp` 显示专用端口属于 `sshd-thin`，管理端口 22 仍由原 sshd 提供且行为不变。
- `systemctl --user status thin-daemon` 正常；`loginctl show-user <账户> -p Linger` 为 `yes`。
- 断线后重新连接仍能看到同一会话继续运行；`systemctl --user restart thin-daemon` 之后，中断的会话标记为 interrupted，**没有**自动重新提交任务或重放工具调用。

## 6. 安全边界

- **认证属于 OpenSSH/PAM**：Thin 不读取 `/etc/shadow`，不保存登录密码，也不维护第二套账户密码。账户锁定、过期、MFA、密码策略由管理员决定，样例不放开这些限制。本样例复用发行版既有的 `/etc/pam.d/sshd` 栈，不修改任何 PAM 配置；需要独立 PAM 策略时由管理员另行提供，不属于本样例范围。
- **账户前提**：ForceCommand 由 sshd 用该账户的登录 shell 执行，所以登录 shell 必须是可用 shell（`nologin`/`false` 会直接失败）。账户缺失、被锁定或无可用认证方式时登录失败，不回退到任何其它入口。
- **默认拒绝 root 与空密码**：`PermitRootLogin no`、`PermitEmptyPasswords no`；`AllowUsers` 只列一个占位账户，必须替换为实际账户。
- **必须有 PTY**：`PermitTTY yes`，`--connect` 在无 TTY 时明确失败。
- **禁止转发与用户 rc**：`DisableForwarding yes` 加各单项 `no`，`PermitUserRC no`、`PermitUserEnvironment no`；样例不声明 `Subsystem`，因此不提供 sftp/scp。
- **不覆盖管理入口**：样例是独立 sshd 实例的完整配置 `-f` 文件，不 Include 进 `/etc/ssh/sshd_config`，不改动 `sshd.service`。
- **强制 TUI 不是沙箱**：Thin 内的 bash 工具仍拥有该 OS 账户本身的权限（可读写该账户可访问的一切、可发起网络请求）。ForceCommand 只保证"登录后只能进入 Thin"，不构成权限隔离或资源限制。
- **文件权限**：sshd 配置与主机密钥由 root 持有；`~/.thin/config.json`、`daemon.env`、运行时 socket 与索引均为 0600/0700，只有该 UID 可访问。不同 UID 不能互相列会话或连接。
- **凭据不进入 SSH 与环境扩散**：密钥只放在 0600 的 `daemon.env` 或 `config.json` 的 `api_key`/`api_key_env`；SSH 客户端环境不会被复制给守护服务或工具。

## 7. 中断语义：不保证任务连续

- 会话进程内已经完成的任务边界（用户/助手提交、完整工具结果、压缩、finished）会增量写入 checkpoint；守护服务重启或机器崩溃后，可从最后一次完整边界恢复。
- **不保证断电/崩溃后的任务连续**：正在执行的推理请求、正在跑的工具、网络连接、审批令牌和后台进程句柄都无法恢复。这类会话被标记为 interrupted，需要用户显式 `--attach`/`--resume` 后重新决定是否继续。
- **重启不重放**：`Restart=on-failure` 只重启服务进程本身。Thin 不自动重放已中断的任务，不重新提交收费推理请求，也不会按遗留 PID 去重新发信号。
- 会话的请求超时、工具预算、低价保护与危险命令显式审批在守护模式下同样生效；"断线不取消"不等于移除这些限制。
- 无人连接时遇到需要审批的危险操作，保持等待，绝不放行。

## 8. 停服与回滚

```sh
systemctl --user stop thin-daemon            # 取消/通知/join 会话后退出，会话标记为中断
systemctl --user disable thin-daemon
loginctl disable-linger <账户>               # 需管理员授权
# 需要管理员：
systemctl disable --now sshd-thin
rm -f /etc/systemd/system/sshd-thin.service /etc/ssh/sshd_config.thin /run/sshd-thin.pid
systemctl daemon-reload
```

- 停止守护服务会取消并保存可保存的会话状态；不会自动重放任务。
- 停掉专用 sshd 实例只关闭 Thin 登录入口，不影响管理端口 22 的既有 SSH。
- 回滚不需要改回 PAM、防火墙或现有 sshd 配置，因为这些样例从未修改它们。

## 9. 已落地接口与验收边界

样例与本文依赖的本地接口已写入 `src/`；下列 1–6 描述当前实现，7 列出验收边界。本节只同步语义，不构成上线或验收结论。

1. 运行模式：`thin` 为普通前台；只有显式 `thin --daemon` 启动该 UID 的守护服务。`--connect`、`--attach`、`--resume` 都不会隐式拉起守护服务；与 `--print` 等模式互斥时明确报错。
2. 端点与对端校验：`$XDG_RUNTIME_DIR/thin/daemon.sock`（目录 0700、socket 0600）；未设置可用 `XDG_RUNTIME_DIR` 时回退 `/tmp/thin-<uid>`（同样 0700/0600）。接受连接时校验对端 UID（`SO_PEERCRED`）。
3. 会话发现：`~/.thin/session-index/<project-key>/<id>.json` 只作定位/状态摘要，可重建；权威仍是项目下 `.thin/sessions/<id>.session` 的 checkpoint 与固定 `.resume-lock`。
4. 写权限：固定 lock inode + CAS 决定执行/保存权；锁文件不删除、不抢占。所有 Runtime 都必须持有租约；`--resume --no-log` 也不例外：禁用日志只关闭 checkpoint/日志发布，不等于允许同一会话出现第二个 Runtime。受理前若锁目录不可用，直接拒绝任务且不发起 HTTP；受理后的可选日志或保存失败只影响日志/持久化，不重放主任务。
5. 恢复不重放：从 checkpoint 恢复不自动重放工具调用或推理请求；守护服务重启后中断会话标记为 interrupted，需要显式 `--attach`/`--resume`。空 idle 会话若只有固定锁或空 discovery 元数据、没有 checkpoint，不视为已保存；存在 checkpoint 时保留私有定位记录。恢复的 history 异步到达，缺失恢复来源的错误保留原有分类。
6. 会话命令（`--connect` 的 launcher）：从 HOME 开始；`/cd` 只改变 launcher 目录，下一次输入才在所选目录创建固定根会话，原会话及其根目录不变；`/detach` 不取消会话。命令为 `/attach [--takeover] <id>`（`/attch` 为兼容别名）、`/ls [--running] [--page N]`、`/close [--force] <id>`、`/exit`。
   - `/ls` 默认列出全部已登记会话；`--running` 只保留实时 busy 或待审批（pending）的记录，并把探测超时/状态不明的记录显式标为 unknown，不把“活进程”一律算作忙。
   - `/close` 是否针对当前视图由 worker epoch + busy 原子判断；对非当前、经 owner 管理器停止的会话（前台自有或 daemon 自有）统一要求 `--force`，以避免“probe 之后又新起任务”的竞态。外部前台所有者需要先取得 controller，再原子关闭。
7. 验收边界：
   - 隔离离线验收入口覆盖本节所述行为；完整 Debug 与 ReleaseSmall 的聚合结果以对应冻结源码上的验收证据为准。
   - 真实 SSH/PAM/systemd/linger 登录链路、PTY 尺寸变化、目标环境 logout 后常驻均未授权测试。
   - 第 5 节列出的部署后人工检查项目前没有任何一项在本机执行过。
   - 管理员整体停止 `thin-daemon` 时会显式取消并 join 其拥有的资源（会话、子任务、后台命令），该路径已纳入隔离离线验收；真实服务下的端到端行为仍随上述 SSH/systemd 边界未验收。
   - 会话与服务日志仍交由 systemd 日志与既有会话存储，样例不指定额外日志路径。
