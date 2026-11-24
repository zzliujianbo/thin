# Thin 部署：本机守护服务与可选的专用 OpenSSH 入口

本地使用无需 SSH。Thin 不包含 SSH 服务端，两种启动方式都不监听 TCP。需要远程登录时，由管理员单独部署专用 OpenSSH 实例；不改动管理用 sshd。

本文件说明如何部署本仓库 `deploy/` 下的样例。样例**未安装、未启用**，本文件中的命令只是步骤说明，**不执行**：不安装服务、不修改 `/etc/ssh`、PAM 或防火墙、不联网、不调用推理 API。

这些部署步骤适用于 Linux。macOS 只支持在本地终端运行无参数的 `thin`，不提供守护服务。

## 实现状态

本文区分本机 Unix socket、会话所有权和实际 SSH 登录链路。离线测试的结果以对应版本的验收记录为准，不能代替目标环境的部署验收。

`deploy/` 下的 SSH 样例**未安装、未启用**；真实 SSH/PAM/systemd/linger 登录链路、目标环境 logout 行为与 PTY 尺寸变化均未获授权、未执行。因此本文件不宣称任何环境已上线、已验证登录链路或已通过部署验收。第 5 节清单是部署后的人工检查项，不是本轮结果。

## 1. 运行模式

| 命令 | 行为 |
| --- | --- |
| `thin` | 默认交互入口。自动连接本 UID 已运行的本地守护服务；没有守护服务时以独立前台运行，不会隐式启动服务。 |
| `thin --daemon` | 显式启动该 UID 的本机守护服务，只监听私有 Unix socket，可由 systemd 用户服务托管。 |

从 IPC v8 升级到 v9：先结束运行中的任务，退出旧客户端并停止旧会话 worker；替换 `thin` 二进制，重启已有守护服务，再打开 `thin`。客户端、守护服务和 worker 版本不同会在握手时被拒绝，不会自动替换旧进程。

如需降级，请在升级前私密备份配置和会话。新版可读取旧检查点；新版保存含工具结果的检查点时，即使没有拒绝操作也会写入 `denied: false`，旧版无法读取这类检查点。降回 v7 时也应使用添加 `openai` 连接前的备份。

在普通输入框中，`Ctrl+D` 删除光标右侧的字符，光标在末尾时不做操作。输入框为空且没有运行或排队的任务时，按一次 `Ctrl+D` 退出 Thin；它不会用来停止任务。

这两种是全部公开启动方式。SSH 样例使用管理员固定的 `ForceCommand /usr/local/bin/thin`，不加参数，不采用客户端指定的命令。

### 出站 HTTP(S) 请求如何选代理

| 配置 | 行为 |
| --- | --- |
| 未设置 `proxy` 或设置为 `null` | 按目标协议读取 `HTTPS_PROXY` 或 `HTTP_PROXY`。非空小写变量优先，`NO_PROXY` / `no_proxy` 可指定直连目标。 |
| 显式设置 `proxy` | 推理和图片请求沿用模型名单，名单外直连。登录、令牌刷新和目录查询不属于某个模型，使用指定代理，不受名单或 `NO_PROXY` 影响。 |

独立前台示例：`HTTPS_PROXY=http://127.0.0.1:7890 thin`。系统代理地址使用不带账号密码的 HTTP(S) URL，不读取 `ALL_PROXY`。使用守护服务时，在 `~/.config/thin/daemon.env` 设置变量并重启服务；仅在连接它的终端里 `export` 不会改变服务的环境。该规则也适用于 Codex 授权码交换、令牌刷新，以及官方目录和公共元数据查询。本机 Unix socket 通信和浏览器里的授权页面不由 Thin 的 HTTP 代理控制。

### 使用 OpenAI API Key

在 `/login` 选择 `OpenAI API`，把 OpenAI 平台的 API Key 粘贴到隐藏输入框并按 Enter。然后在 `/model` 选择 `openai/…` 下的模型。请求发往 `https://api.openai.com/v1`，使用该 Key 所属 API 项目的额度，与下面的 ChatGPT 浏览器登录相互独立。不要在聊天或命令行中输入 Key。

### 通过 SSH 登录 OpenAI Codex

在 Thin 运行 `/login`，选择 OpenAI Codex，把显示的授权链接复制到本机浏览器并登录。授权后浏览器会跳转到 `http://localhost:1455/auth/callback`。Thin 不监听这个端口；即使浏览器显示无法连接，也可以复制地址栏里的**完整回调地址**，粘贴回 Thin 的专用登录框并按 Enter。不要把它粘贴到聊天或 shell。整个过程不需要设备码、修改设备码权限或设置 SSH 端口转发。已有凭据可以继续使用。

## 2. 拓扑与所有权

```text
ssh -tt -p <PORT> <user>@<host>
        │  专用 OpenSSH 实例（独立端口，系统账户 + PAM，必须有 PTY）
        │  ForceCommand /usr/local/bin/thin
        ▼
thin（以登录 UID 运行）
  ├── 已有守护服务：通过 AF_UNIX 连接，校验对端 UID
  │     └── thin-daemon 持有会话 worker、任务、子任务和后台命令
  └── 没有守护服务：独立前台持有会话与任务
```

- 一个 OS 用户对应一个守护服务，再下面才是多个会话。会话数没有固定配额；资源不足时明确失败。
- 已连接守护服务时，worker 属于守护服务的 cgroup。SSH 断线只关闭视图；只要守护服务仍运行，它持有的任务就可以继续。重新登录后可用 `/resume` 选回该会话；另一终端仍在控制时不会被抢占。
- 独立前台时，SSH 断线导致前台退出，其任务也随之终止，不会自动移交守护服务。需要断线续跑时，应在登录前显式启动用户守护服务，并确认登录账户能访问同一个运行时 socket。
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
2. **守护服务凭据**（使用环境变量时）：`install -Dm0600 deploy/daemon.env.example ~/.config/thin/daemon.env`，编辑该文件填入真实密钥，`chmod 600`。变量名必须与 `~/.thin/config.json` 中对应 provider 的 `api_key_env` 完全一致。
3. **守护服务**（需要断线续跑时）：复制 `thin-daemon.service` 到 `~/.config/systemd/user/`，`systemctl --user daemon-reload`，再 `systemctl --user enable --now thin-daemon`。
4. **退出登录后常驻**：需要管理员授权 `loginctl enable-linger <账户>`。没有 linger 时，用户 systemd 实例可能在该账户最后一个会话退出后被清理；此时守护会话也结束。不能靠在 SSH 里 `nohup`/后台启动替代这个授权。
5. **专用 SSH 入口**：把 `sshd_config.thin` 放到 `/etc/ssh/sshd_config.thin`（0600 root），先做只读语法校验：`sshd -t -f /etc/ssh/sshd_config.thin`；再安装 `sshd-thin.service` 并启用。该实例与管理用 sshd 完全独立。
6. **端口与防火墙**：样例 sshd 只绑定 `127.0.0.1:2222`；对外绑定地址、端口与防火墙放行属于单独的部署授权；样例不改动任何防火墙规则，也不覆盖管理端口 22。
7. **回滚/停服**：见第 8 节。

## 5. 校验清单

只读校验（不启动服务）：

```sh
deploy/check-samples.sh                      # 样例与文档的静态安全默认值
sshd -t -f /etc/ssh/sshd_config.thin         # 需要管理员与已放置的配置
systemd-analyze --user verify ~/.config/systemd/user/thin-daemon.service
```

部署后人工确认（`<host>` 在回环样例下为本机 `127.0.0.1`）：

- `ssh -tt -p <PORT> <user>@<host>` 只得到 Thin 界面；没有 shell 提示符。
- 使用 `ssh -T`（禁用 PTY）的连接被拒绝或以错误结束，不降级为一次性模式或 shell。
- `ssh -tt -p <PORT> <user>@<host> true` 仍然只得到 Thin 界面（ForceCommand 覆盖客户端命令）。
- `ssh -L`/`-R`/`-A`/`-X` 在本入口失败（转发被关闭）。
- `ssh -p <PORT> root@<host>` 被拒绝。
- 在该账户 ~/.ssh/rc、~/.ssh/environment 放置标记内容不生效（`PermitUserRC no`、`PermitUserEnvironment no`）。
- `ss -ltnp` 显示专用端口属于 `sshd-thin`，管理端口 22 仍由原 sshd 提供且行为不变。
- `systemctl --user status thin-daemon` 正常；`loginctl show-user <账户> -p Linger` 为 `yes`。
- 有守护服务时，断线后重新登录并接回原会话，确认任务没有取消或重放。没有守护服务时，登录进入独立前台；断线后确认没有守护服务被启动、前台任务没有续跑。
- `systemctl --user restart thin-daemon` 之后，中断的会话标记为 interrupted，**没有**自动重新提交任务或重放工具调用。

## 6. 安全边界

- **认证属于 OpenSSH/PAM**：Thin 不读取 `/etc/shadow`，不保存登录密码，也不维护第二套账户密码。账户锁定、过期、MFA、密码策略由管理员决定，样例不放开这些限制。本样例复用发行版既有的 `/etc/pam.d/sshd` 栈，不修改任何 PAM 配置；需要独立 PAM 策略时由管理员另行提供，不属于本样例范围。
- **账户前提**：ForceCommand 由 sshd 用该账户的登录 shell 执行，所以登录 shell 必须是可用 shell（`nologin`/`false` 会直接失败）。账户缺失、被锁定或无可用认证方式时登录失败，不回退到任何其它入口。
- **默认拒绝 root 与空密码**：`PermitRootLogin no`、`PermitEmptyPasswords no`；`AllowUsers` 只列一个占位账户，必须替换为实际账户。
- **必须有 PTY**：`PermitTTY yes` 允许 sshd 分配 PTY；交互 TUI 需要终端。无 PTY 时不应获得 shell。
- **禁止转发与用户 rc**：`DisableForwarding yes` 加各单项 `no`，`PermitUserRC no`、`PermitUserEnvironment no`；样例不声明 `Subsystem`，因此不提供 sftp/scp。
- **不覆盖管理入口**：样例是独立 sshd 实例的完整配置 `-f` 文件，不 Include 进 `/etc/ssh/sshd_config`，不改动 `sshd.service`。
- **强制 TUI 不是沙箱**：Thin 内的 bash 工具仍拥有该 OS 账户本身的权限（可读写该账户可访问的一切、可发起网络请求）。ForceCommand 只保证"登录后只能进入 Thin"，不构成权限隔离或资源限制。不要把同一 UID 分给互不信任的使用者。
- **文件权限**：sshd 配置与主机密钥由 root 持有；`~/.thin/config.json`、`daemon.env`、运行时 socket 与索引均为 0600/0700，只有该 UID 可访问。不同 UID 不能互相列会话或连接。
- **凭据不进入 SSH 与环境扩散**：密钥只放在 0600 的 `daemon.env` 或 `config.json` 的 `api_key`/`api_key_env`；不要通过 SSH 转发凭据。SSH 登录不会给已运行的用户守护服务补充环境变量；独立前台也不会自动读取该服务的 `daemon.env`。需要两种模式共用凭据时可用该账户的私有 `config.json`。

## 7. 中断语义：不保证任务连续

- 会话进程内已经完成的任务边界（用户/助手提交、完整工具结果、压缩、finished）会增量写入 checkpoint；守护服务重启或机器崩溃后，可从最后一次完整边界恢复。
- **不保证断电/崩溃后的任务连续**：正在执行的推理请求、正在跑的工具、网络连接、审批令牌和后台进程句柄都无法恢复。这类会话被标记为 interrupted，需要用户在 TUI 中用 `/resume` 恢复已保存会话，再决定是否继续。
- **重启不重放**：`Restart=on-failure` 只重启服务进程本身。Thin 不自动重放已中断的任务，不重新提交收费推理请求，也不会按遗留 PID 去重新发信号。
- 会话的请求超时、工具预算与危险命令显式审批在守护模式下同样生效；"断线不取消"不等于移除这些限制。
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

- 停止守护服务会取消并保存可保存的会话状态；不会自动重放任务。这不会关闭 SSH 入口：只要专用 sshd 仍在运行，新登录就可以进入独立前台。若要撤下远程入口，应停用专用 sshd。
- 停掉专用 sshd 实例只关闭 Thin 登录入口，不影响管理端口 22 的既有 SSH。
- 回滚不需要改回 PAM、防火墙或现有 sshd 配置，因为这些样例从未修改它们。

## 9. 部署接口与验收边界

下列 1–6 描述样例依赖的接口，7 说明验收边界。静态校验不验证产品或登录链路。

1. 运行模式：只有显式 `thin --daemon` 才启动该 UID 的守护服务。无参数 `thin` 选择已有守护服务或独立前台；本地和 SSH 登录使用相同规则。
2. 端点与对端校验：`$XDG_RUNTIME_DIR/thin/daemon.sock`（目录 0700、socket 0600）；`XDG_RUNTIME_DIR` 未设置或为空时回退 `/tmp/thin-<uid>`（同样 0700/0600）。接受连接时校验对端 UID（`SO_PEERCRED`）。
3. 会话发现：`~/.thin/session-index/<project-key>/<id>.json` 只作定位/状态摘要，可重建；权威仍是项目下 `.thin/sessions/<id>.session` 的 checkpoint 与固定 `.resume-lock`。
4. 写权限：固定 lock inode + CAS 决定执行/保存权；锁文件不删除、不抢占。所有 Runtime 都必须持有租约；任何恢复（包括 TUI `/resume`）也不例外，同一会话不能出现第二个 Runtime。受理前若锁目录不可用，直接拒绝任务且不发起 HTTP；受理后的可选日志或保存失败只影响日志/持久化，不重放主任务。
5. 恢复不重放：从 checkpoint 恢复不自动重放工具调用或推理请求；守护服务重启后中断会话标记为 interrupted，可在 TUI 中使用 `/resume` 恢复已保存会话。空 idle 会话若只有固定锁或空 discovery 元数据、没有 checkpoint，不视为已保存；存在 checkpoint 时保留私有定位记录。恢复的 history 异步到达，缺失恢复来源的错误保留原有分类。
6. TUI 会话命令只有 `/new` 和 `/resume`。`/new` 始终在启动目录创建。连接 daemon 时，`/resume` 跨项目列出 daemon 托管的会话，包括重启前已保存的历史；独立前台只列启动目录内的历史。选中运行中的会话可接回原任务；Esc 只退出列表，不停止任务。
7. 验收边界：
   - 产品行为须在对应版本上单独验收；旧版的离线结果不验证新 CLI。
   - 真实 SSH/PAM/systemd/linger 登录链路、PTY 尺寸变化、目标环境 logout 后常驻均未授权测试。
   - 第 5 节列出的部署后人工检查项目前没有任何一项在本机执行过。
   - 管理员整体停止 `thin-daemon` 时会显式取消并 join 其拥有的资源（会话、子任务、后台命令），该路径已纳入隔离离线验收；真实服务下的端到端行为仍随上述 SSH/systemd 边界未验收。
   - 会话与服务日志仍交由 systemd 日志与既有会话存储，样例不指定额外日志路径。
