# SSH 部署入口变更

Thin 不再包含内嵌 SSH 服务端。`thin --daemon` 只提供本 UID 的本机 Unix socket；不要为 Thin 配置 TCP 端口、主机密钥或 SSH 授权名单。

需要 SSH 时，使用[专用 OpenSSH 部署样例](README.md)。由管理员单独配置监听地址、端口与允许登录的 OS 账户，保留管理用 sshd。主机私钥由 sshd 管理；客户端应通过可信渠道核对主机指纹，保留 known_hosts 检查。客户端私钥不传至服务器。

登录后固定执行无参数的 `thin`。它不会启动守护服务：连接已有本地守护服务时，断线只关闭视图；没有守护服务时，任务由独立前台持有，不会转入后台续跑。ForceCommand 不是沙箱，不同信任域应使用不同 OS 账户。
