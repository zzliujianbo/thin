#!/usr/bin/env bash
# 只读静态校验：deploy/ 下的 Thin SSH/守护部署样例与 deploy/README.md 的安全默认值。
#
# 本脚本严格只读：不安装、不启用、不重启任何服务，不调用 sshd/systemctl/防火墙，
# 不修改 sshd/PAM 配置，不联网，不需要 root，也不执行样例中的任何命令。
#
# 用法：deploy/check-samples.sh
# 退出码：0 全部通过；1 有失败项。
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/.." && pwd -P)
sshd_conf="$here/sshd_config.thin"
sshd_unit="$here/sshd-thin.service"
daemon_unit="$here/thin-daemon.service"
env_example="$here/daemon.env.example"
doc="$here/README.md"

passes=0
failures=0
pass() { passes=$((passes + 1)); }
fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1"
}

# need_file <path> <label>
need_file() {
    if [[ -f $1 ]]; then
        pass
        return 0
    fi
    fail "$2 不存在：$1"
    return 1
}

# active_lines <file>：输出非空、非注释行（配置语义只看这些行）。
active_lines() {
    grep -Eiv '^[[:space:]]*(#|$)' -- "$1" || true
}

# require_value <file> <key> <expected> <label>
# 要求 key 至少出现一次，且每处取值都等于 expected（OpenSSH 取首处，故须全部一致）。
require_value() {
    local file=$1 key=$2 want=$3 label=$4 total matching
    total=$(grep -Eic "^[[:space:]]*${key}([[:space:]]|\$)" -- "$file" || true)
    if ((total == 0)); then
        fail "$label：缺少 '$key $want'"
        return
    fi
    matching=$(grep -Eic "^[[:space:]]*${key}[[:space:]]+${want}[[:space:]]*\$" -- "$file" || true)
    if ((matching != total)); then
        fail "$label：'$key' 存在非 '$want' 的取值"
        return
    fi
    pass
}

# forbid_key <file> <key> <label>：不允许出现该指令。
forbid_key() {
    local hits
    hits=$(grep -Eic "^[[:space:]]*$2([[:space:]]|\$)" -- "$1" || true)
    if ((hits > 0)); then
        fail "$3：不允许出现 '$2'"
        return
    fi
    pass
}

# forbid_active <file> <extended-regex> <label>：只看生效行（不含注释）。
forbid_active() {
    local hits
    hits=$(active_lines "$1" | grep -Eic -- "$2" || true)
    if ((hits > 0)); then
        fail "$3：生效配置出现禁止内容 /$2/"
        return
    fi
    pass
}

# forbid_text <file> <extended-regex> <label>：整文件（含注释）检查。
forbid_text() {
    local hits
    hits=$(grep -Eic -- "$2" "$1" || true)
    if ((hits > 0)); then
        fail "$3：出现禁止内容 /$2/"
        return
    fi
    pass
}

# require_text <file> <fixed-string> <label>
require_text() {
    if grep -Fq -- "$2" "$1"; then
        pass
        return
    fi
    fail "$3：缺少必需内容 '$2'"
}

# first_value <file> <key>：取第一个匹配指令后面的完整取值（保留原始大小写）。
first_value() {
    awk -v key="$2" '
        tolower($0) ~ "^[[:space:]]*" tolower(key) "([[:space:]]|$)" {
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$1"
}

# 安装路径基准：与 install.sh 的 INSTALL_DIR 默认值保持一致。
install_default=$(sed -nE 's/^install_dir=\$\{INSTALL_DIR:-([^}]*)\}$/\1/p' "$repo/install.sh")
if [[ -z $install_default ]]; then
    fail "无法从 install.sh 解析 INSTALL_DIR 默认值"
    install_default='/usr/local/bin'
fi
expected_binary="$install_default/thin"

check_sshd_config() {
    need_file "$sshd_conf" "sshd 配置样例" || return
    local file=$sshd_conf

    # 端口：唯一、合法，且绝不与管理端口 22 相同。
    local port_count port_value
    port_count=$(grep -Eic '^[[:space:]]*Port([[:space:]]|$)' -- "$file" || true)
    if ((port_count != 1)); then
        fail "sshd 样例：必须恰好有一个 Port，实际 $port_count"
    else
        port_value=$(first_value "$file" Port)
        if [[ ! $port_value =~ ^[0-9]+$ ]]; then
            fail "sshd 样例：Port 取值不是数字：'$port_value'"
        elif ((port_value < 1 || port_value > 65535)); then
            fail "sshd 样例：Port 超出范围：$port_value"
        elif ((port_value == 22)); then
            fail "sshd 样例：禁止与管理端口 22 相同"
        else
            pass
        fi
    fi

    # 认证：OS 账户 + PAM，默认拒绝 root 与空密码。
    require_value "$file" UsePAM yes "sshd 样例"
    require_value "$file" PasswordAuthentication yes "sshd 样例"
    require_value "$file" PermitEmptyPasswords no "sshd 样例"
    require_value "$file" PermitRootLogin no "sshd 样例"
    require_value "$file" PermitTTY yes "sshd 样例"

    # 强制 TUI：不允许 rc/环境绕过，不允许任何转发。
    require_value "$file" PermitUserRC no "sshd 样例"
    require_value "$file" PermitUserEnvironment no "sshd 样例"
    require_value "$file" DisableForwarding yes "sshd 样例"
    require_value "$file" AllowAgentForwarding no "sshd 样例"
    require_value "$file" AllowTcpForwarding no "sshd 样例"
    require_value "$file" AllowStreamLocalForwarding no "sshd 样例"
    require_value "$file" X11Forwarding no "sshd 样例"
    require_value "$file" PermitTunnel no "sshd 样例"
    require_value "$file" GatewayPorts no "sshd 样例"

    # 不允许把本样例当成管理 sshd 的补丁片段，也不提供 sftp。
    forbid_key "$file" Include "sshd 样例（不得 Include 进管理配置）"
    forbid_key "$file" Match "sshd 样例（保持无条件配置）"
    forbid_key "$file" Subsystem "sshd 样例（不提供 sftp）"
    forbid_key "$file" StrictModes "sshd 样例（不得改写 StrictModes）"

    # ForceCommand：唯一，且只是 --connect。
    local fc_count fc_command
    fc_count=$(grep -Eic '^[[:space:]]*ForceCommand([[:space:]]|$)' -- "$file" || true)
    if ((fc_count != 1)); then
        fail "sshd 样例：必须恰好有一个 ForceCommand，实际 $fc_count"
    else
        fc_command=$(first_value "$file" ForceCommand)
        if [[ $fc_command != "$expected_binary --connect" ]]; then
            fail "sshd 样例：ForceCommand 必须是 '$expected_binary --connect'，实际 '$fc_command'"
        else
            pass
        fi
        forbid_active "$file" '(^|[[:space:]])(--daemon|--print|--resume|--attach|--no-log)([[:space:]]|$)' \
            "sshd 样例（登录路径不得携带守护/一次性/恢复参数）"
        forbid_active "$file" '(^|[[:space:]])(nohup|systemctl|setsid|sudo|exec)([[:space:]]|$)' \
            "sshd 样例（登录路径不得启动服务）"
        forbid_active "$file" '(/|[[:space:]])(ba|z|k)?sh([[:space:]]|$)' \
            "sshd 样例（登录不得降级为 shell）"
    fi

    # 允许账户：单一占位账户，明确不含 root。
    local au_count allow_users
    au_count=$(grep -Eic '^[[:space:]]*AllowUsers([[:space:]]|$)' -- "$file" || true)
    if ((au_count != 1)); then
        fail "sshd 样例：必须恰好有一个 AllowUsers，实际 $au_count"
    else
        allow_users=$(sed -nE 's/^[[:space:]]*[Aa][Ll][Ll][Oo][Ww][Uu][Ss][Ee][Rr][Ss][[:space:]]+(.*)$/\1/p' -- "$file" | head -n 1)
        if [[ -z $allow_users ]]; then
            fail "sshd 样例：AllowUsers 为空"
        elif [[ " $allow_users " == *' root '* || $allow_users == root ]]; then
            fail "sshd 样例：AllowUsers 不得包含 root"
        elif [[ $allow_users != 'thinuser' ]]; then
            fail "sshd 样例：AllowUsers 应保留单一占位账户 'thinuser' 待部署者替换，实际 '$allow_users'"
        else
            pass
        fi
    fi

    # 必须显式标注需要替换的项，避免样例被当成可直接上线的配置。
    local markers
    markers=$(grep -c 'THIN:REPLACE' -- "$file" || true)
    if ((markers < 2)); then
        fail "sshd 样例：缺少 THIN:REPLACE 标注（实际 $markers 处）"
    else
        pass
    fi
}

check_daemon_unit() {
    need_file "$daemon_unit" "守护服务样例" || return
    local file=$daemon_unit

    local exec_count exec_line
    exec_count=$(grep -Eic '^[[:space:]]*ExecStart=' -- "$file" || true)
    if ((exec_count != 1)); then
        fail "守护服务：必须恰好有一个 ExecStart，实际 $exec_count"
    else
        exec_line=$(sed -nE 's/^[[:space:]]*ExecStart=(.*)$/\1/p' -- "$file" | head -n 1)
        if [[ $exec_line != "$expected_binary --daemon" ]]; then
            fail "守护服务：ExecStart 必须是 '$expected_binary --daemon'，实际 '$exec_line'"
        else
            pass
        fi
    fi

    # 只以 --daemon 启动：不得变成 SSH 入口、一次性模式或前台恢复，也不得自行脱离 systemd。
    forbid_active "$file" '(^|[[:space:]])(--connect|--print|--attach|--resume|--no-log|--help)([[:space:]]|$)' \
        "守护服务（ExecStart 不得携带其它运行模式参数）"
    forbid_active "$file" '(^|[[:space:]])(ba|z|k)?sh[[:space:]]+-c' "守护服务（不得用 shell -c 包装）"
    forbid_active "$file" '(^|[[:space:]])(nohup|setsid|screen|tmux)([[:space:]]|$)' \
        "守护服务（不得自行脱离 systemd 托管）"

    # 前台托管语义；用户单元不能声明 User=/Group=。
    require_text "$file" 'Type=simple' "守护服务"
    forbid_key "$file" Type=forking "守护服务"
    forbid_key "$file" User "守护服务（用户单元不得声明 User=）"
    forbid_key "$file" Group "守护服务（用户单元不得声明 Group=）"
    forbid_key "$file" PermissionsStartOnly "守护服务"

    # 重启策略存在，且样例说明“重启不重放中断任务”。
    if grep -Eiq '^[[:space:]]*Restart=(on-failure|on-abnormal|always)[[:space:]]*$' -- "$file"; then
        pass
    else
        fail "守护服务：缺少受控的 Restart=on-failure/on-abnormal/always"
    fi
    require_text "$file" '自动重放' "守护服务（必须说明重启不重放任务）"
    require_text "$file" '中断' "守护服务（必须说明中断任务的处理）"
    require_text "$file" 'KillMode=control-group' "守护服务（worker 必须随服务回收）"

    # 环境文件可选加载，且不得把密钥内联进单元。
    local env_lines
    env_lines=$(grep -Ec '^[[:space:]]*EnvironmentFile=-%h/\.config/thin/daemon\.env[[:space:]]*$' -- "$file" || true)
    if ((env_lines != 1)); then
        fail "守护服务：EnvironmentFile 必须是可选加载的 -%h/.config/thin/daemon.env"
    else
        pass
    fi
    forbid_active "$file" 'Environment=.*(KEY|TOKEN|SECRET)=' "守护服务（不得在单元内联密钥）"

    # 用户单元安装目标是 default.target。
    if grep -Eq '^[[:space:]]*WantedBy=default\.target[[:space:]]*$' -- "$file"; then
        pass
    else
        fail "守护服务：安装目标必须是 WantedBy=default.target"
    fi
    forbid_active "$file" 'WantedBy=(multi-user|graphical|basic)\.target' "守护服务（不得使用系统 target）"
}

check_sshd_unit() {
    need_file "$sshd_unit" "专用 sshd 服务样例" || return
    local file=$sshd_unit

    local exec_count exec_line conf_path
    exec_count=$(grep -Eic '^[[:space:]]*ExecStart=' -- "$file" || true)
    if ((exec_count != 1)); then
        fail "专用 sshd 服务：必须恰好有一个 ExecStart，实际 $exec_count"
        return
    fi
    exec_line=$(sed -nE 's/^[[:space:]]*ExecStart=(.*)$/\1/p' -- "$file" | head -n 1)
    conf_path=$(sed -nE 's/.*[[:space:]]-f[[:space:]]+([^[:space:]]+).*/\1/p' <<<"$exec_line")

    if [[ $exec_line == *' -D '* ]]; then
        pass
    else
        fail "专用 sshd 服务：必须以 -D 前台运行交 systemd 托管"
    fi
    if [[ $conf_path == '/etc/ssh/sshd_config.thin' ]]; then
        pass
    else
        fail "专用 sshd 服务：-f 必须指向独立配置 /etc/ssh/sshd_config.thin，实际 '$conf_path'"
    fi

    # 不得用命令行 -o 覆盖安全项，不得复用管理配置，不得顺带改防火墙。
    forbid_active "$file" '\-o[[:space:]]+[A-Za-z]*(ForceCommand|PermitRootLogin|PermitTTY|DisableForwarding|AllowUsers)' \
        "专用 sshd 服务（不得用 -o 覆盖安全项）"
    forbid_active "$file" '(^|[[:space:]])/etc/ssh/sshd_config([[:space:]]|$)' \
        "专用 sshd 服务（不得复用管理配置）"
    forbid_active "$file" '(^|[[:space:]])(modprobe|iptables|ip6tables|nft|ufw|firewall-cmd)([[:space:]]|$)' \
        "专用 sshd 服务（不得顺带修改防火墙）"

    if grep -Eq '^[[:space:]]*WantedBy=multi-user\.target[[:space:]]*$' -- "$file"; then
        pass
    else
        fail "专用 sshd 服务：系统单元安装目标应是 WantedBy=multi-user.target"
    fi
}

check_env_example() {
    need_file "$env_example" "凭据环境样例" || return
    local file=$env_example

    if [[ $file == *.example ]]; then
        pass
    else
        fail "凭据样例：文件名必须以 .example 结尾"
    fi

    local line name value count=0 problems=0
    while IFS= read -r line; do
        [[ -z ${line//[[:space:]]/} ]] && continue
        [[ $line =~ ^[[:space:]]*# ]] && continue
        count=$((count + 1))
        if [[ ! $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            fail "凭据样例：非法行 '$line'"
            problems=$((problems + 1))
            continue
        fi
        name=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ -z $value ]] && continue
        # 只允许占位值，避免把真实密钥提交进仓库。
        if [[ $value != replace-with-your-key ]]; then
            fail "凭据样例：$name 的值必须是占位符 replace-with-your-key"
            problems=$((problems + 1))
        fi
    done <"$file"
    if ((count == 0)); then
        fail "凭据样例：至少需要一个变量占位行"
        problems=$((problems + 1))
    fi
    ((problems == 0)) && pass

    # 整文件检查：连注释也不应出现疑似真实凭据。
    forbid_text "$file" '(sk-[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{12,}|xox[baprs]-|[0-9a-f]{32,})' \
        "凭据样例（不得包含疑似真实密钥）"
    require_text "$file" 'chmod 600' "凭据样例（必须要求 0600）"
    require_text "$file" 'api_key_env' "凭据样例（变量名须与 config.json 的 api_key_env 一致）"
    require_text "$file" 'THIN:REPLACE' "凭据样例（必须标注需替换）"
}

check_doc() {
    need_file "$doc" "部署文档" || return
    local file=$doc
    local required=(
        'thin --daemon'
        'thin --connect'
        'ForceCommand'
        'enable-linger'
        '不是沙箱'
        '不保证'
        '断电'
        '崩溃'
        '不自动重放'
        'api_key_env'
        'systemctl --user stop'
        '端口'
    )
    local item
    for item in "${required[@]}"; do
        require_text "$file" "$item" "部署文档"
    done
    if grep -Fq '默认' "$file" && grep -Fq '前台' "$file"; then
        pass
    else
        fail "部署文档：必须明确默认 thin 仍为前台模式"
    fi
    if grep -Fq '未安装' "$file" && grep -Fq '不执行' "$file"; then
        pass
    else
        fail "部署文档：必须声明样例未安装、部署步骤不执行"
    fi
    if grep -Eiq '强制[[:space:]]?TUI[[:space:]]*(是|等于)[[:space:]]*(一个)?沙箱' "$file"; then
        fail "部署文档：不得把强制 TUI 描述为沙箱"
    else
        pass
    fi
}

check_cross_refs() {
    # sshd ForceCommand 与守护 ExecStart 必须指向同一个安装路径。
    local refs
    refs=$(grep -Fl -- "$expected_binary" "$sshd_conf" "$daemon_unit" 2>/dev/null | wc -l)
    if [[ $refs -eq 2 ]]; then
        pass
    else
        fail "跨文件：sshd ForceCommand 与守护 ExecStart 必须都指向 $expected_binary"
    fi
    # install.sh 只是二进制安装器，不得安装或启用这些服务样例。
    if grep -Fq 'sshd_config.thin' "$repo/install.sh" || grep -Fq 'thin-daemon.service' "$repo/install.sh"; then
        fail "install.sh：不得安装或启用 deploy/ 下的服务样例"
    else
        pass
    fi
}

printf '%s\n' 'Thin 部署样例静态检查（只读，不执行任何部署动作）'
check_sshd_config
check_daemon_unit
check_sshd_unit
check_env_example
check_doc
check_cross_refs

printf '\n通过 %d 项，失败 %d 项\n' "$passes" "$failures"
if ((failures > 0)); then
    exit 1
fi
