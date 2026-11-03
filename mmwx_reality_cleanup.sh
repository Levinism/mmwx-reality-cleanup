#!/usr/bin/env bash
# 妙妙屋X：在 embedded 模式下清理所有 REALITY 入站（与端口号无关）
# 本地：sudo bash mmwx_reality_cleanup.sh [--dry-run | --yes]
# 批量：bash mmwx_reality_cleanup.sh --hosts servers.txt
# servers.txt 每行：SSH用户名@IP SSH端口号（端口可省略，默认为22）
set -Eeuo pipefail

CFG='/usr/local/etc/xray/config.json'
AGENT_CFG='/etc/mmw-agent/config.yaml'
SELF="${BASH_SOURCE[0]}"

usage() {
  cat <<'EOF'
用法：
  sudo bash mmwx_reality_cleanup.sh             # 列出所有 REALITY 入站，人工确认后清理
  sudo bash mmwx_reality_cleanup.sh --dry-run   # 只检查，不改配置
  sudo bash mmwx_reality_cleanup.sh --yes       # 确认清理全部 REALITY 入站（无人值守）
  bash mmwx_reality_cleanup.sh --hosts hosts.txt # 经 SSH 批量预览、统一确认、逐台执行

hosts.txt 示例：
  root@203.0.113.10 29692
  root@198.51.100.20 22

注意：这里无法仅靠本地配置分辨「面板已删除」与「仍在使用」的节点。
因此本脚本会清理每台目标服务器上的全部 REALITY 入站；其他入站不删除。
EOF
}

say() { printf '%s\n' "$*"; }
die() { say "[错误] $*" >&2; exit 1; }
warn() { say "[警告] $*" >&2; }

remote_exec() {
  local host="$1" port="$2" opt="$3"
  # 仅支持无交互的 SSH 密钥登录；非 root 用户需免密 sudo。
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
      -p "$port" "$host" \
      'if [ "$(id -u)" -eq 0 ]; then exec bash -s -- '"$opt"'; else exec sudo -n bash -s -- '"$opt"'; fi' < "$SELF"
}

run_fleet() {
  local hostfile="$1" line host port extra i bad=0 failures=0
  [[ -f "$hostfile" ]] || die "服务器清单不存在：$hostfile"
  [[ -f "$SELF" ]] || die '批量运行必须从脚本文件启动，不能通过标准输入执行。'
  command -v ssh >/dev/null 2>&1 || die '当前电脑没有 ssh 命令。'
  local -a hosts=() ports=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    read -r host port extra <<< "$line"
    [[ -z "${extra:-}" ]] || die "清单格式错误（每行至多两列）：$line"
    [[ "$host" =~ ^[a-zA-Z0-9_.@:-]+$ && "$host" != -* ]] || die "不支持的 SSH 主机名：$host"
    port="${port:-22}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "无效 SSH 端口：$port"
    (( 10#$port >= 1 && 10#$port <= 65535 )) || die "SSH 端口超范围：$port"
    hosts+=("$host"); ports+=("$port")
  done < "$hostfile"
  ((${#hosts[@]} > 0)) || die '服务器清单是空的。'

  say "[批量预检] 共 ${#hosts[@]} 台，检查每台服务器的 REALITY 入站（此阶段不会修改配置）："
  for ((i=0; i<${#hosts[@]}; i++)); do
    say "\n===== ${hosts[i]}:${ports[i]} ====="
    if ! remote_exec "${hosts[i]}" "${ports[i]}" '--dry-run'; then
      warn "${hosts[i]} 预检失败。"; bad=1
    fi
  done
  ((bad == 0)) || die '至少有一台预检失败。为避免批量半途清理，当前不执行任何删除。'

  say ''
  say '【影响范围】以上服务器上的全部 REALITY 入站都会被移除；即使它们仍是有效节点。'
  say '其他协议不会主动删除。每台服务器将独立备份并重启 mmw-agent（产生短暂断线）。'
  local confirm=''
  if [[ -r /dev/tty ]]; then
    read -r -p '如果确认批量执行，请输入 DELETE_ALL_REALITY ：' confirm < /dev/tty || true
  fi
  [[ "$confirm" == 'DELETE_ALL_REALITY' ]] || { say '已取消，未进行删除。'; return 0; }
  for ((i=0; i<${#hosts[@]}; i++)); do
    say "\n===== 正在清理 ${hosts[i]}:${ports[i]} ====="
    if ! remote_exec "${hosts[i]}" "${ports[i]}" '--yes'; then
      warn "${hosts[i]} 清理失败，请查看该服务器输出和备份。"; failures=$((failures+1))
    fi
  done
  ((failures == 0)) || die "有 $failures 台清理失败，其余服务器的改动不会自动撤销。"
  say '[完成] 所有目标服务器已执行清理；请用旧的 V2Ray 节点再次验证。'
}

run_local() {
  local dry="$1" yes="$2"
  ((EUID == 0)) || die '请使用 root 运行（例如 sudo bash mmwx_reality_cleanup.sh）。'
  command -v jq >/dev/null 2>&1 || die '缺少 jq。请先安装，例如 Debian/Ubuntu: apt install jq；RHEL: dnf install jq。'
  command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl：这个脚本仅支持 systemd 部署的 mmw-agent。'
  [[ -r "$CFG" && -f "$CFG" ]] || die "未找到配置文件：$CFG"
  [[ ! -L "$CFG" ]] || die "配置文件是符号链接；为避免覆盖错误路径，本脚本不自动修改。"
  [[ -r "$AGENT_CFG" ]] || die "未找到 Agent 配置：$AGENT_CFG"
  local mode
  mode="$(sed -n 's/^[[:space:]]*xray_mode:[[:space:]]*//p' "$AGENT_CFG" | head -n1 | tr -d '"' | tr -d "'" | awk '{print $1}')"
  [[ "$mode" == 'embedded' ]] || die "当前 xray_mode=${mode:-未识别}；本脚本仅适用于 embedded 模式，不作任何修改。"
  systemctl cat mmw-agent.service >/dev/null 2>&1 || die '没有找到 mmw-agent.service，不继续操作。'
  systemctl is-active --quiet mmw-agent.service || die 'mmw-agent 目前没有运行；为避免意外启动它，先检查服务状态。'
  jq -e '(.inbounds | type) == "array"' "$CFG" >/dev/null || die 'config.json 无效，或没有 inbounds 数组。'

  local count
  count="$(jq '[.inbounds[] | select((.streamSettings.security // "" | ascii_downcase) == "reality")] | length' "$CFG")"
  say "[检测] $(hostname)；模式：embedded；配置：$CFG"
  if (( count == 0 )); then
    say '[结果] 配置文件中没有 REALITY 入站，无需修改或重启。'
    return 0
  fi
  say "[检测] 共发现 $count 个 REALITY 入站（全部在本次清理范围）："
  jq -r '.inbounds[] | select((.streamSettings.security // "" | ascii_downcase) == "reality") | "  tag=\(.tag // "(无tag)")  port=\(.port // "(无端口)")  protocol=\(.protocol // "(未知)")"' "$CFG"

  (( dry == 0 )) || { say '[预检] 未做任何修改。'; return 0; }
  if (( yes == 0 )); then
    local confirm=''
    if [[ -r /dev/tty ]]; then
      read -r -p '确认删除以上所有 REALITY 入站？请输入 DELETE_ALL_REALITY ：' confirm < /dev/tty || true
    fi
    [[ "$confirm" == 'DELETE_ALL_REALITY' ]] || { say '已取消，未做任何修改。'; return 0; }
  fi

  # 确认项来自修改前配置。每台服务器单独创建含时间戳的私有备份。
  local backup stamp tmp before_hash now_hash old_total new_total new_reality
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${CFG}.bak.reality-${stamp}-$$"
  umask 077
  cp -a -- "$CFG" "$backup" || die '备份失败，不进行删除。'
  chmod 600 "$backup"
  say "[备份] $backup"
  before_hash="$(sha256sum "$CFG" | awk '{print $1}')"
  tmp="$(mktemp "${CFG}.tmp.XXXXXXXX")" || die '无法创建临时配置文件。'
  trap '[[ -z "${tmp:-}" ]] || rm -f -- "$tmp"' EXIT
  cp -a -- "$CFG" "$tmp" || die '复制原文件元数据失败。'
  jq '.inbounds |= map(select((.streamSettings.security // "" | ascii_downcase) != "reality"))' "$CFG" > "$tmp" || die '生成配置失败，原文件未修改。'
  jq -e '(.inbounds | type) == "array"' "$tmp" >/dev/null || die '新配置 JSON 校验失败。'
  new_reality="$(jq '[.inbounds[] | select((.streamSettings.security // "" | ascii_downcase) == "reality")] | length' "$tmp")"
  old_total="$(jq '.inbounds | length' "$CFG")"
  new_total="$(jq '.inbounds | length' "$tmp")"
  ((new_reality == 0 && new_total == old_total - count)) || die '新旧入站数量不符，已终止。'
  now_hash="$(sha256sum "$CFG" | awk '{print $1}')"
  [[ "$now_hash" == "$before_hash" ]] || die '运行过程中原配置被其他程序修改，已终止，避免覆盖新配置。'
  chown --reference="$CFG" "$tmp"
  chmod --reference="$CFG" "$tmp"
  mv -f -- "$tmp" "$CFG"
  tmp=''
  say "[修改] 已从本机配置中删除 $count 个 REALITY 入站，其余入站保留。"
  if ! systemctl restart mmw-agent.service; then
    warn 'Agent 重启失败。配置仍已清理，请查看 journalctl -u mmw-agent -n 80 --no-pager；备份路径见上。'
    return 1
  fi
  sleep 3
  if ! systemctl is-active --quiet mmw-agent.service; then
    warn 'Agent 重启后没有正常运行！不要直接恢复旧 REALITY，先检查 journalctl 和其他依赖。'
    return 1
  fi
  say '[检查] mmw-agent 正在运行。'
  local remaining port active_ports=0
  remaining="$(jq '[.inbounds[] | select((.streamSettings.security // "" | ascii_downcase) == "reality")] | length' "$CFG")"
  if ((remaining > 0)); then
    warn "配置文件中又出现 $remaining 个 REALITY 入站，可能被主控或 Agent 回写！"
    return 1
  fi
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r port; do
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      if ss -H -lntp "sport = :$port" 2>/dev/null | grep -q .; then
        warn "旧端口 $port 仍被进程监听：请检查是否有另一个入站、动态注入或其他服务。"
        active_ports=$((active_ports+1))
      else
        say "[已关闭] 原 REALITY 端口 $port 没有 TCP 监听。"
      fi
    done < <(jq -r '.inbounds[] | select((.streamSettings.security // "" | ascii_downcase) == "reality") | .port | tostring' "$backup" | sort -u)
  else
    warn '系统没有 ss 命令，跳过监听端口检查。'
  fi
  ((active_ports == 0)) || die '仍有旧端口在监听，需要进一步检查；磁盘配置已修改，未自动回滚。'
  say '[成功] 已移除本机配置中的全部 REALITY 入站。请从 V2Ray 客户端重新建立连接测试。'
  say '[提示] 如果端口后续恢复，请排查主控再次下发/Agent 回写，并核对主控版本。'
}

main() {
  local dry=0 yes=0 hostfile=''
  while (($#)); do
    case "$1" in
      --dry-run) dry=1 ;;
      --yes) yes=1 ;;
      --hosts) shift; (($#)) || die '--hosts 缺少文件路径'; hostfile="$1" ;;
      -h|--help) usage; return 0 ;;
      *) die "不认识的选项：$1（使用 --help 查看用法）" ;;
    esac
    shift
  done
  if [[ -n "$hostfile" ]]; then
    ((dry == 0 && yes == 0)) || die '--hosts 不可与 --dry-run 或 --yes 同时使用。'
    run_fleet "$hostfile"
  else
    run_local "$dry" "$yes"
  fi
}
main "$@"
