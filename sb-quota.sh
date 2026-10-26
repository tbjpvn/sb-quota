#!/bin/bash
# =========================================================
# sing-box.sh 插件：代理流量限制（单文件，用链接安装，与 proxyip 插件同一套机制）
#
# 安装/更新: bash <(curl -Ls https://raw.githubusercontent.com/<用户名>/<仓库>/main/sb-quota.sh)
# 卸载:      bash <(curl -Ls 同上链接) uninstall
# 状态:      bash <(curl -Ls 同上链接) status
#
# 原理：sb 快捷指令每次从 GitHub 拉取最新主脚本运行。安装时把 /etc/sing-box/sb.sh 改成
#       「拉主脚本 -> 经过各插件的注入器 -> 运行」；本插件的注入器接在已有插件(如 proxyip)之后，
#       在「WARP分流管理」菜单末尾追加入口，序号 = 此时菜单现有最大序号 + 1。
#       主脚本本身不被修改；注入任一步失败都原样放行，sb 不受影响。
# 多插件：sb.sh 按文件名顺序串联 plugins/*-inject.sh (proxyip 在前、quota 在后)，
#       需要使用已打补丁的 proxyip.sh，这样两个插件谁先装、谁后装/更新/卸载都不会互相冲掉。
# =========================================================
export LANG=en_US.UTF-8
PLUGIN_TITLE="代理流量限制 (定时流量上限，超限切断)"
work_dir="${SB_WORK_DIR:-/etc/sing-box}"
conf_dir="${work_dir}/conf"
plugin_dir="${work_dir}/plugins"
wrapper="${work_dir}/sb.sh"
wrapper_marker="plugin wrapper"   # 子串匹配, 与 proxyip 插件共用同一种 sb.sh 包装
inject="${plugin_dir}/quota-inject.sh"
payload_file="${plugin_dir}/quota.sh"

red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
die()    { red "$1"; exit 1; }

[ -z "$SB_WORK_DIR" ] && [ "$EUID" -ne 0 ] && die "请在root用户下运行脚本"

# 注入到主脚本里的功能代码 (流量限制全部实现)
write_payload() {
cat > "$payload_file" << 'QUOTA_PAYLOAD_EOF'
# >>> sb-plugin:quota >>>
# 插件: 代理流量限制 (由 sb-quota 插件注入, 请勿手动编辑; 卸载请运行插件脚本 uninstall)
quota_bin="${work_dir}/quota-monitor.sh"
quota_state="${work_dir}/quota.json"
quota_api_conf="${conf_dir}/clash_api.json"
quota_outbound_file="${conf_dir}/outbounds.json"

# =========================
# 代理流量限制 (按出站统计, 定时窗口内超限切断, 窗口结束自动解除并重新计量)
# 原理: sing-box Clash API 提供每条连接的上下行字节, 常驻监控服务每3秒累加到对应出站;
#       超限后把该出站替换为不可达的占位出站(路由规则不变), 窗口结束后换回原出站。
# =========================
quota_fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b >= 1073741824)      printf "%.2fGB", b/1073741824;
        else if (b >= 1048576)    printf "%.2fMB", b/1048576;
        else if (b >= 1024)       printf "%.1fKB", b/1024;
        else                      printf "%dB", b }'
}

quota_fmt_secs() {
    local s=${1:-0}
    [ "$s" -lt 0 ] && s=0
    printf "%dh%02dm" $((s/3600)) $(((s%3600)/60))
}

quota_is_pos_num() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$1" 'BEGIN{exit !(v>0)}'
}

# 供 warp_manage 出站列表显示限流状态
quota_tag_flag() {
    local tag=$1 line q_used q_lim q_blk
    [ -f "$quota_state" ] || return 0
    line=$(jq -r --arg t "$tag" '.limits[$t] // empty | "\(.used // 0)\t\(.limit_bytes)\t\(.blocked // false)\t\(.action // "block")"' "$quota_state" 2>/dev/null)
    [ -z "$line" ] && return 0
    IFS=$'\t' read -r q_used q_lim q_blk q_act <<< "$line"
    if [ "$q_blk" = "true" ] && [ "$q_act" = "direct" ]; then
        echo -e " ${yellow}[已超限·已回落本机IP]${re}"
    elif [ "$q_blk" = "true" ]; then
        echo -e " ${red}[已超限·流量已切断]${re}"
    else
        echo -e " ${skyblue}[限流 $(quota_fmt_bytes "$q_used")/$(quota_fmt_bytes "$q_lim")]${re}"
    fi
}

# 生成监控脚本 (独立运行, 不依赖本脚本)
quota_write_monitor() {
    cat > "$quota_bin" << 'QEOF'
#!/bin/bash
# sing-box 代理流量限制监控 —— 由 sing-box.sh 自动生成，请勿手动编辑
WORK_DIR="__WORK_DIR__"
CONF_DIR="${WORK_DIR}/conf"
OUT_FILE="${CONF_DIR}/outbounds.json"
STATE="${WORK_DIR}/quota.json"
SEEN="${WORK_DIR}/quota.seen.json"
LOCK="${WORK_DIR}/quota.lock"
LOG="${WORK_DIR}/quota.log"
INTERVAL=3

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

locked() {
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9; "$@" ) 9>"$LOCK"
    else
        local i=0 rc
        while ! mkdir "$LOCK.d" 2>/dev/null; do
            i=$((i+1)); [ "$i" -gt 100 ] && rm -rf "$LOCK.d"
            sleep 0.1
        done
        "$@"; rc=$?
        rmdir "$LOCK.d" 2>/dev/null
        return $rc
    fi
}

st_edit() { jq "$@" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }

sb_reload() {
    local sb="${WORK_DIR}/sing-box"
    if [ -x "$sb" ] && ! "$sb" check -C "$CONF_DIR" >/dev/null 2>&1; then
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet sing-box 2>/dev/null || return 0
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null
    elif command -v rc-service >/dev/null 2>&1; then
        local pid
        pid=$(cat /var/run/sing-box.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null; then
            return 0
        fi
        rc-service sing-box restart >/dev/null 2>&1
    fi
}

# 超限: 先在状态里记下原出站, 再换成占位出站并重载
do_block() {
    local tag=$1 now orig act stub
    now=$(date +%s)
    act=$(jq -r --arg t "$tag" '.limits[$t].action // "block"' "$STATE")
    if [ "$act" = "direct" ]; then
        stub=$(jq -nc --arg t "$tag" '{type:"direct",tag:$t}')
    else
        stub=$(jq -nc --arg t "$tag" '{type:"socks",tag:$t,server:"127.0.0.1",server_port:1}')
    fi
    orig=$(jq -c --arg t "$tag" '[.outbounds[] | select(.tag == $t)][0] // empty' "$OUT_FILE" 2>/dev/null)
    if [ -z "$orig" ]; then
        log "$tag 已超限, 但 outbounds.json 中找不到该出站, 移除其限制记录"
        st_edit --arg t "$tag" 'del(.limits[$t])'
        return 1
    fi
    st_edit --arg t "$tag" --argjson o "$orig" --argjson n "$now" \
        '.limits[$t] |= (.blocked = true | .blocked_at = $n | .orig = $o)'
    cp "$OUT_FILE" "$OUT_FILE.quota.bak"
    jq --arg t "$tag" --argjson s "$stub" \
        '.outbounds |= map(if .tag == $t then $s else . end)' \
        "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
    if ! sb_reload; then
        mv "$OUT_FILE.quota.bak" "$OUT_FILE"
        st_edit --arg t "$tag" --argjson r $((now+60)) \
            '.limits[$t] |= (del(.blocked, .blocked_at, .orig) | .retry_after = $r)'
        log "$tag 超限处理失败(配置校验/重载未通过), 60秒后重试"
        return 1
    fi
    rm -f "$OUT_FILE.quota.bak"
    if [ "$act" = "direct" ]; then log "$tag 已超限, 已回落为本机默认IP直连"; else log "$tag 已超限, 出站已切断"; fi
}

# 解除限制并重启计量 (已切断则先换回原出站)
do_reset() {
    local tag=$1 now blocked orig
    now=$(date +%s)
    blocked=$(jq -r --arg t "$tag" '.limits[$t].blocked // false' "$STATE")
    if [ "$blocked" = "true" ]; then
        orig=$(jq -c --arg t "$tag" '.limits[$t].orig // empty' "$STATE")
        if [ -z "$orig" ]; then
            log "$tag 解除失败: 状态文件中缺少原出站配置"
            return 1
        fi
        cp "$OUT_FILE" "$OUT_FILE.quota.bak"
        jq --arg t "$tag" --argjson o "$orig" \
            '.outbounds |= map(if .tag == $t then $o else . end)' \
            "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
        if ! sb_reload; then
            mv "$OUT_FILE.quota.bak" "$OUT_FILE"
            st_edit --arg t "$tag" --argjson r $((now+60)) '.limits[$t].retry_after = $r'
            log "$tag 解除失败(配置校验/重载未通过), 保持切断状态, 60秒后重试"
            return 1
        fi
        rm -f "$OUT_FILE.quota.bak"
    fi
    st_edit --arg t "$tag" --argjson n "$now" \
        '.limits[$t] |= (del(.blocked, .blocked_at, .orig, .retry_after) | .used = 0 | .window_start = $n)'
    log "$tag 已解除限制并重启计量"
}

tick_apply() {
    local now=$1 resp=$2 tag win ws blk retry out
    [ -f "$STATE" ] || return 0

    # 1) 统计窗口到期: 已切断的解除并重新计量, 未切断的清零开新窗口
    while IFS=$'\t' read -r tag win ws blk retry; do
        [ -z "$tag" ] && continue
        [ $((now - ws)) -lt "$win" ] && continue
        [ "$retry" -gt "$now" ] && continue
        if [ "$blk" = "true" ]; then
            do_reset "$tag"
        else
            st_edit --arg t "$tag" --argjson n "$now" '.limits[$t] |= (.used = 0 | .window_start = $n)'
            log "$tag 统计窗口结束, 已重新计量"
        fi
    done < <(jq -r '.limits | to_entries[] | [.key, .value.window_sec, .value.window_start, (.value.blocked // false), (.value.retry_after // 0)] | @tsv' "$STATE")

    # 2) 累加各出站新增流量 (按连接差值, 跨轮询去重)
    if [ -n "$resp" ]; then
        [ -f "$SEEN" ] || echo '{}' > "$SEEN"
        out=$(printf '%s' "$resp" | jq --slurpfile st "$STATE" --slurpfile seen "$SEEN" '
            ($st[0]) as $s | ($seen[0] // {}) as $p |
            ((.connections // []) | map({id: .id, tag: (((.chains // []) | last) // ""), t: ((.upload // 0) + (.download // 0))})) as $cur |
            ($cur | map({tag: .tag, d: (if .t >= ($p[.id] // 0) then .t - ($p[.id] // 0) else .t end)})
                  | group_by(.tag) | map({key: .[0].tag, value: (map(.d) | add)}) | from_entries) as $delta |
            {
              state: ($s | .limits |= with_entries(
                  if ((.value.blocked // false) | not) and (($delta[.key] // 0) > 0)
                  then .value.used = ((.value.used // 0) + $delta[.key])
                  else . end)),
              seen: ($cur | map({key: .id, value: .t}) | from_entries)
            }' 2>/dev/null)
        if [ -n "$out" ]; then
            printf '%s' "$out" | jq '.state' > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
            printf '%s' "$out" | jq -c '.seen' > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
        fi
    fi

    # 3) 超限的出站切断
    while IFS= read -r tag; do
        [ -n "$tag" ] && do_block "$tag"
    done < <(jq -r --argjson now "$now" '.limits | to_entries[]
        | select(((.value.blocked // false) | not) and ((.value.used // 0) >= .value.limit_bytes) and ((.value.retry_after // 0) <= $now))
        | .key' "$STATE")
}

tick() {
    local port secret resp now
    [ -f "$STATE" ] || return 0
    now=$(date +%s)
    port=$(jq -r '.clash.port // empty' "$STATE")
    secret=$(jq -r '.clash.secret // empty' "$STATE")
    resp=""
    if [ -n "$port" ]; then
        resp=$(curl -s --max-time 3 -H "Authorization: Bearer ${secret}" "http://127.0.0.1:${port}/connections" 2>/dev/null)
        printf '%s' "$resp" | jq -e 'type == "object" and has("connections")' >/dev/null 2>&1 || resp=""
    fi
    locked tick_apply "$now" "$resp"
}

cli_set() {
    local tag=$1 lim=$2 win=$3 act=${4:-block} now
    [ -f "$STATE" ] || return 1
    now=$(date +%s)
    if [ "$(jq -r --arg t "$tag" '.limits[$t].blocked // false' "$STATE")" = "true" ]; then
        do_reset "$tag" || return 1
    fi
    st_edit --arg t "$tag" --argjson l "$lim" --argjson w "$win" --argjson n "$now" --arg a "$act" \
        '.limits[$t] = {limit_bytes: $l, window_sec: $w, window_start: $n, used: 0, action: $a}'
}

cli_del() {
    local tag=$1
    [ -f "$STATE" ] || return 0
    if [ "$(jq -r --arg t "$tag" '.limits[$t].blocked // false' "$STATE")" = "true" ]; then
        do_reset "$tag" || return 1
    fi
    st_edit --arg t "$tag" 'del(.limits[$t])'
}

cli_forget() {
    [ -f "$STATE" ] || return 0
    st_edit --arg t "$1" 'del(.limits[$t])'
}

case "$1" in
    daemon) while true; do tick; sleep "$INTERVAL"; done ;;
    set)    locked cli_set "$2" "$3" "$4" "$5" ;;
    reset)  locked do_reset "$2" ;;
    del)    locked cli_del "$2" ;;
    forget) locked cli_forget "$2" ;;
    *)      echo "usage: $0 daemon|set TAG BYTES SECS [block|direct]|reset TAG|del TAG|forget TAG"; exit 1 ;;
esac
QEOF
    sed -i "s#__WORK_DIR__#${work_dir}#" "$quota_bin"
    chmod 700 "$quota_bin"
}

quota_service_start() {
    quota_write_monitor
    if command_exists systemctl; then
        cat > /etc/systemd/system/sb-quota.service << EOF
[Unit]
Description=sing-box proxy traffic quota monitor
After=sing-box.service

[Service]
Type=simple
ExecStart=/bin/bash ${quota_bin} daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sb-quota >/dev/null 2>&1
        systemctl restart sb-quota >/dev/null 2>&1
    elif command_exists rc-service; then
        cat > /etc/init.d/sb-quota << EOF
#!/sbin/openrc-run
description="sing-box proxy traffic quota monitor"
command="/bin/bash"
command_args="${quota_bin} daemon"
command_background=true
pidfile="/var/run/sb-quota.pid"

depend() {
    need net
    after sing-box
}
EOF
        chmod +x /etc/init.d/sb-quota
        rc-update add sb-quota default >/dev/null 2>&1
        rc-service sb-quota restart >/dev/null 2>&1
    fi
}

quota_service_stop() {
    if command_exists systemctl && [ -f /etc/systemd/system/sb-quota.service ]; then
        systemctl disable --now sb-quota >/dev/null 2>&1
        rm -f /etc/systemd/system/sb-quota.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    if command_exists rc-service && [ -f /etc/init.d/sb-quota ]; then
        rc-service sb-quota stop >/dev/null 2>&1
        rc-update del sb-quota default >/dev/null 2>&1
        rm -f /etc/init.d/sb-quota
    fi
}

# 确保状态文件与 Clash API 配置存在; 新增了API配置时 quota_api_added=1 (需要重载 sing-box 才生效)
quota_enable_api() {
    quota_api_added=0
    local port secret check_output
    if [ ! -f "$quota_state" ]; then
        port=$(get_free_port 20000 60000)
        secret=$(openssl rand -hex 16)
        jq -n --argjson p "$port" --arg s "$secret" '{clash:{port:$p, secret:$s}, limits:{}}' > "$quota_state"
        chmod 600 "$quota_state"
        echo '{}' > "${work_dir}/quota.seen.json"
    fi
    if [ ! -f "$quota_api_conf" ]; then
        port=$(jq -r '.clash.port' "$quota_state")
        secret=$(jq -r '.clash.secret' "$quota_state")
        jq -n --arg addr "127.0.0.1:${port}" --arg s "$secret" \
            '{experimental:{clash_api:{external_controller:$addr, secret:$s}}}' > "$quota_api_conf"
        check_output=$(validate_singbox_config)
        if [ $? -ne 0 ]; then
            red "当前 sing-box 内核无法启用 Clash API（流量统计依赖它）：\n"
            echo "$check_output" | head -10
            rm -f "$quota_api_conf"
            [ "$(jq '.limits | length' "$quota_state" 2>/dev/null)" = "0" ] && rm -f "$quota_state" "${work_dir}/quota.seen.json"
            return 1
        fi
        quota_api_added=1
    fi
    return 0
}

# 没有任何限制时, 关闭监控服务并移除 Clash API 配置; 移除了API配置时 quota_api_removed=1
quota_cleanup_if_empty() {
    quota_api_removed=0
    [ -f "$quota_state" ] || return 0
    [ "$(jq '.limits | length' "$quota_state" 2>/dev/null)" = "0" ] || return 0
    quota_service_stop
    rm -f "$quota_state" "${work_dir}/quota.seen.json" "${work_dir}/quota.lock" "${work_dir}/quota.log" "$quota_bin"
    if [ -f "$quota_api_conf" ]; then
        rm -f "$quota_api_conf"
        quota_api_removed=1
    fi
}

# 删除出站时同步清理其限制记录 (调用方随后会 reload)
quota_forget() {
    local tag=$1
    [ -f "$quota_state" ] || return 0
    jq -e --arg t "$tag" '.limits[$t]' "$quota_state" >/dev/null 2>&1 || return 0
    bash "$quota_bin" forget "$tag"
    quota_cleanup_if_empty
}

quota_show() {
    local rows now
    now=$(date +%s)
    if [ ! -f "$quota_state" ] || [ "$(jq '.limits | length' "$quota_state" 2>/dev/null)" = "0" ]; then
        echo "  暂无已设置的流量限制"
        return
    fi
    if ! service_is_running "sb-quota"; then
        yellow "  ⚠ 监控服务 sb-quota 未运行，流量不会被统计，请重新设置一次限制以拉起服务"
    fi
    rows=$(jq -r '.limits | to_entries[] | [.key, (.value.used // 0), .value.limit_bytes, .value.window_sec, .value.window_start, (.value.blocked // false), (.value.action // "block")] | @tsv' "$quota_state")
    while IFS=$'\t' read -r q_tag q_used q_lim q_win q_ws q_blk q_act; do
        local left=$((q_ws + q_win - now))
        local status
        local act_txt="超限后阻断"
        [ "$q_act" = "direct" ] && act_txt="超限后回落本机IP"
        if [ "$q_blk" = "true" ] && [ "$q_act" = "direct" ]; then
            status="${yellow}已超限·已回落本机IP${re}，$(quota_fmt_secs "$left")后自动恢复"
        elif [ "$q_blk" = "true" ]; then
            status="${red}已超限·已切断${re}，$(quota_fmt_secs "$left")后自动解除"
        else
            status="${green}计量中${re}，窗口剩余 $(quota_fmt_secs "$left")，${act_txt}"
        fi
        echo -e " - ${yellow}${q_tag}${re}  $(quota_fmt_bytes "$q_used") / $(quota_fmt_bytes "$q_lim")  周期$(quota_fmt_secs "$q_win")  ${status}"
    done <<< "$rows"
}

# 选择一个出站: 参数1=candidates 来源(all=所有可限流出站 / limited=已设置限制的出站); 结果写入 quota_pick_tag
quota_pick_tag() {
    local mode=$1 tags=() i=1 t
    quota_pick_tag_result=""
    if [ "$mode" = "limited" ]; then
        [ -f "$quota_state" ] && tags=($(jq -r '.limits | keys[]' "$quota_state" 2>/dev/null))
    else
        tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' "$quota_outbound_file" 2>/dev/null))
    fi
    if [ ${#tags[@]} -eq 0 ]; then
        if [ "$mode" = "limited" ]; then yellow "没有已设置限制的出站。"; else yellow "没有可限流的出站，请先添加代理出站或本地IP出站。"; fi
        sleep 2; return 1
    fi
    echo ""
    for t in "${tags[@]}"; do
        echo -e "  ${green}${i}.${re} ${yellow}${t}${re}$(quota_tag_flag "$t")"
        i=$((i+1))
    done
    echo -e "  ${purple}0. 返回${re}"
    reading "\n请输入编号或标签: " q_in
    [ -z "$q_in" ] || [ "$q_in" = "0" ] && return 1
    if [[ "$q_in" =~ ^[0-9]+$ ]]; then
        [ "$q_in" -ge 1 ] && [ "$q_in" -le "${#tags[@]}" ] || { red "编号无效！"; sleep 1; return 1; }
        quota_pick_tag_result="${tags[$((q_in-1))]}"
    else
        for t in "${tags[@]}"; do [ "$t" = "$q_in" ] && quota_pick_tag_result="$t"; done
        [ -z "$quota_pick_tag_result" ] && { red "标签 '${q_in}' 不存在！"; sleep 1; return 1; }
    fi
    return 0
}

quota_set_limit() {
    clear
    green "=== 设置/修改 流量限制 ===\n"
    yellow "统计口径: 该出站的 上行+下行 总流量 (1GB=1024MB)。\n超限后按你选择的方式处理(阻断 或 回落本机默认IP)，统计周期结束时自动恢复并重新计量。\n修改已有限制会清零计量并重新开始周期。"
    quota_pick_tag all || return
    local tag="$quota_pick_tag_result" q_gb q_hours q_act act limit_bytes window_sec
    reading "流量上限 (GB，可小数，如 20): " q_gb
    quota_is_pos_num "$q_gb" || { red "流量上限必须是大于0的数字"; sleep 2; return; }
    reading "统计周期 (小时，可小数，如 12): " q_hours
    quota_is_pos_num "$q_hours" || { red "统计周期必须是大于0的数字"; sleep 2; return; }
    echo ""
    green "超限后的处理方式:"
    echo -e "  ${green}1. 阻断出站${re} —— 该代理/出站无法再使用，相关流量直接失败"
    echo -e "  ${green}2. 回落本机默认IP${re} —— 命中该出站的流量改走本机默认IP直连，仍可正常出站"
    reading "请选择 [1/2，直接回车默认1]: " q_act
    act="block"; [ "$q_act" = "2" ] && act="direct"
    limit_bytes=$(awk -v g="$q_gb" 'BEGIN{printf "%.0f", g*1073741824}')
    window_sec=$(awk -v h="$q_hours" 'BEGIN{printf "%.0f", h*3600}')
    [ "$window_sec" -lt 60 ] && { red "统计周期不能小于1分钟"; sleep 2; return; }

    quota_enable_api || { sleep 2; return; }
    quota_write_monitor
    if ! bash "$quota_bin" set "$tag" "$limit_bytes" "$window_sec" "$act"; then
        red "设置失败，请查看 ${work_dir}/quota.log"; sleep 2; return
    fi
    if [ "$quota_api_added" = "1" ]; then
        reload_singbox || { red "sing-box 重载失败，限制未生效"; sleep 2; return; }
    fi
    quota_service_start
    if [ "$act" = "direct" ]; then
        green "\n已设置: ${tag} 每 ${q_hours} 小时最多 ${q_gb} GB，超限后回落为本机默认IP直连。"
    else
        green "\n已设置: ${tag} 每 ${q_hours} 小时最多 ${q_gb} GB，超限后阻断该出站。"
    fi
    sleep 2
}

quota_reset_limit() {
    clear
    green "=== 解除限制并重启计量 ===\n"
    quota_pick_tag limited || return
    local tag="$quota_pick_tag_result"
    if bash "$quota_bin" reset "$tag"; then
        green "\n${tag} 已解除限制，计量已清零并重新开始。"
    else
        red "\n解除失败，请查看 ${work_dir}/quota.log"
    fi
    sleep 2
}

quota_cancel_limit() {
    clear
    green "=== 取消流量限制 ===\n"
    quota_pick_tag limited || return
    local tag="$quota_pick_tag_result"
    if ! bash "$quota_bin" del "$tag"; then
        red "取消失败，请查看 ${work_dir}/quota.log"; sleep 2; return
    fi
    quota_cleanup_if_empty
    [ "$quota_api_removed" = "1" ] && reload_singbox
    green "\n${tag} 的流量限制已取消。"
    sleep 2
}

quota_menu() {
    while true; do
        clear
        echo ""
        green "=== 代理流量限制 ===\n"
        green "已设置的限制 (已用 / 上限):"
        quota_show
        echo ""
        green "1. 设置/修改流量限制"
        skyblue "----------------------"
        green "2. 手动解除限制并重启计量"
        skyblue "----------------------"
        red "3. 取消流量限制"
        skyblue "----------------------"
        green "4. 刷新状态"
        skyblue "----------------------"
        purple "0. 返回上级菜单"
        skyblue "------------"
        reading "请输入选择: " q_choice
        case "${q_choice}" in
            1) quota_set_limit ;;
            2) quota_reset_limit ;;
            3) quota_cancel_limit ;;
            4) ;;
            0) return ;;
            *) red "无效选项"; sleep 1 ;;
        esac
    done
}

# ---- 接入主脚本钩子 ----
sbhook_outbound_flag__quota()    { quota_tag_flag "$@"; }
sbhook_outbound_deleted__quota() { quota_forget "$@"; }
sbhook_uninstall__quota()        { quota_service_stop >/dev/null 2>&1 || true; }
# <<< sb-plugin:quota <<<
QUOTA_PAYLOAD_EOF
}

# 注入器: 从 stdin 读主脚本, 追加菜单与代码后输出到 stdout; 任何一步不满足都原样输出
write_inject() {
cat > "$inject" << 'QUOTA_INJECT_EOF'
#!/bin/bash
payload="$(cd "$(dirname "$0")" && pwd)/quota.sh"
tmp=$(mktemp) || exit 1
cat > "$tmp"
out=$(mktemp) || { cat "$tmp"; rm -f "$tmp"; exit 0; }
trap 'rm -f "$tmp" "$out"' EXIT
passthrough() { cat "$tmp"; exit 0; }

[ -s "$payload" ] || passthrough
grep -q '^quota_menu()' "$tmp" && passthrough          # 主脚本仍内置该功能, 不重复注入
grep -q '^sb_run_hooks()' "$tmp" || passthrough        # 主脚本过旧, 没有插件钩子
grep -q '^warp_manage() {' "$tmp" || passthrough

# 序号 = 「WARP分流管理」菜单里现有最大序号 + 1 (已含前面插件注入的入口)
n=$(awk '/^warp_manage\(\) \{/{f=1;next} f&&/^\}/{f=0} f&&match($0,/^[ \t]+[0-9]+\)/){s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); if(s+0>m)m=s+0} END{print m+0}' "$tmp")
[ "${n:-0}" -ge 1 ] || passthrough
n=$((n+1))

awk -v N="$n" -v payload="$payload" '
/^warp_manage\(\) \{/ { inw=1 }
inw && /^\}/ { inw=0 }
inw && !m && /purple "0\. 返回主菜单"/ {
    print "    green \"" N ". 代理流量限制 (插件，定时流量上限，超限切断)\""
    print "    skyblue \"----------------------\""
    m=1
}
inw && !c && /^[ \t]+0\)[ \t]+menu ;;/ {
    print "        " N ")  quota_menu; warp_manage ;;"
    c=1
}
!t && /^# ---- 参数解析入口 ----/ {
    while ((getline line < payload) > 0) print line
    close(payload)
    t=1
}
{ print }
END { if (!(m && c && t)) exit 3 }
' "$tmp" > "$out" || passthrough

bash -n "$out" 2>/dev/null || passthrough
cat "$out"
QUOTA_INJECT_EOF
chmod +x "$inject"
}

# 重写 sb.sh: 串联 plugins 下所有 *-inject.sh (与 proxyip 插件的写法完全一致)
write_wrapper() {
    local url=$1 stages="" f
    for f in "${plugin_dir}"/*-inject.sh; do
        [ -f "$f" ] && stages="${stages} | bash ${f}"
    done
    cat > "$wrapper" << EOF
#!/usr/bin/env bash
# sb-plugin wrapper
bash <(curl -Ls ${url}${stages}) "\$@"
EOF
    chmod +x "$wrapper"
}

# 取 sb.sh 里的流水线 <(curl ... | bash ...) 去掉外壳后的内容, 用于预览序号
wrapper_pipeline() { grep -oE '<\(curl [^)]*\)' "$wrapper" | head -1 | sed -E 's/^<\(//; s/\)$//'; }

preview_menu_no() {
    local pl
    pl=$(wrapper_pipeline)
    [ -n "$pl" ] || return 0
    timeout 40 bash -c "$pl" 2>/dev/null | grep -E '^[[:space:]]+[0-9]+\)[[:space:]]+quota_menu;' | head -1 | grep -oE '[0-9]+' | head -1
}

do_install() {
    [ -x "${work_dir}/sing-box" ] && [ -f "$wrapper" ] || die "未检测到已安装的 sing-box / sb 快捷指令，请先用主脚本安装 sing-box。"
    command -v jq >/dev/null 2>&1 || die "缺少 jq，请先用主脚本安装依赖。"
    if grep -q '^warp_manage()' "$wrapper"; then
        die "${wrapper} 是完整的主脚本而不是在线启动器，本插件只支持启动器/插件包装方式。"
    fi

    local url bak="${wrapper}.quota.bak" is_wrapped=0
    grep -q "$wrapper_marker" "$wrapper" && is_wrapped=1
    mkdir -p "$plugin_dir"
    url=$(cat "${plugin_dir}/main_url" 2>/dev/null)
    [ -z "$url" ] && url=$(grep -oE 'https://[^ )"]+' "$wrapper" | head -1)
    url="${MAIN_URL:-$url}"
    [ -n "$url" ] || die "未能识别主脚本地址，请指定后重试: MAIN_URL=主脚本raw链接 bash <(curl -Ls 本插件链接)"

    write_payload; write_inject
    bash -n "$payload_file" && bash -n "$inject" || die "插件文件语法检查失败，已中止（未修改 sb 快捷指令）"
    [ -f "${plugin_dir}/main_url" ] || echo "$url" > "${plugin_dir}/main_url"

    cp -f "$wrapper" "$bak"
    # 普通启动器: 先另存原文件; 已是插件包装(含 proxyip 的)则保留已有备份
    [ "$is_wrapped" = 0 ] && [ ! -f "${wrapper}.orig" ] && [ ! -f "${wrapper}.quota.orig" ] && cp -f "$wrapper" "${wrapper}.quota.orig"
    write_wrapper "$url"
    grep -q "quota-inject.sh" "$wrapper" || { cp -f "$bak" "$wrapper"; die "接入 sb.sh 失败，已还原"; }
    chmod +x "$wrapper"
    if [ ! -e /usr/bin/sb ] && [ -z "$SB_WORK_DIR" ]; then
        ln -sf "$wrapper" /usr/bin/sb && touch "${plugin_dir}/quota_sb_link_created"
    fi

    green "\n代理流量限制插件安装完成。"
    local no
    no=$(preview_menu_no)
    if [ -n "$no" ]; then
        green "菜单位置: sb → 10. WARP分流管理 → ${no}. 代理流量限制 (重新运行 sb 生效)"
    else
        yellow "预演未生成菜单入口(主脚本不是拆分后的版本、网络取不到或结构不符)，sb 仍会照常运行，只是暂时没有该菜单。"
    fi
    [ -f "${work_dir}/quota.json" ] && yellow "检测到已有的流量限制数据，已原样沿用。"
    return 0
}

reload_sb() {
    local sb="${work_dir}/sing-box"
    [ -x "$sb" ] && ! "$sb" check -C "$conf_dir" >/dev/null 2>&1 && { yellow "sing-box 配置校验未通过，未重载"; return 1; }
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet sing-box 2>/dev/null || return 0
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart >/dev/null 2>&1
    fi
}

do_uninstall() {
    local state="${work_dir}/quota.json" bin="${work_dir}/quota-monitor.sh" tag ans failed=0 blocked=""
    read -r -p "确定卸载「代理流量限制」插件并清除其数据吗? (y/n): " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "已取消"; exit 0; }

    # 先把被切断/回落的出站恢复成原配置, 否则卸载后出站会一直停留在占位状态
    if [ -f "$state" ] && command -v jq >/dev/null 2>&1; then
        blocked=$(jq -r '.limits | to_entries[] | select(.value.blocked // false) | .key' "$state" 2>/dev/null)
        if [ -n "$blocked" ]; then
            [ -f "$bin" ] || die "有被切断的出站但监控脚本已丢失，无法自动恢复。请先在菜单里随便设置一次限制(会重建监控脚本)并解除后再卸载"
            for tag in $blocked; do
                bash "$bin" reset "$tag" || { failed=1; yellow "出站 ${tag} 恢复失败"; }
            done
            [ "$failed" = 1 ] && die "部分出站未能恢复原配置，已中止卸载(未删除任何数据)，请查看 ${work_dir}/quota.log"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/sb-quota.service ]; then
        systemctl disable --now sb-quota >/dev/null 2>&1
        rm -f /etc/systemd/system/sb-quota.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/sb-quota ]; then
        rc-service sb-quota stop >/dev/null 2>&1
        rc-update del sb-quota default >/dev/null 2>&1
        rm -f /etc/init.d/sb-quota
    fi
    rm -f "$state" "${work_dir}/quota.seen.json" "${work_dir}/quota.lock" "${work_dir}/quota.log" "$bin"
    rm -rf "${work_dir}/quota.lock.d"
    if [ -f "${conf_dir}/clash_api.json" ]; then
        rm -f "${conf_dir}/clash_api.json"
        reload_sb
    fi

    # 还原 sb.sh: 只摘掉本插件的注入器, 其它插件(proxyip)的注入器保留
    local others=0 url
    url=$(cat "${plugin_dir}/main_url" 2>/dev/null)
    rm -f "$inject"
    if ls "${plugin_dir}"/*-inject.sh >/dev/null 2>&1; then others=1; fi
    if [ -f "$wrapper" ] && grep -q "$wrapper_marker" "$wrapper"; then
        if [ "$others" = 1 ]; then
            write_wrapper "$url"
        elif [ -f "${wrapper}.quota.orig" ]; then
            mv -f "${wrapper}.quota.orig" "$wrapper"
        elif [ -f "${wrapper}.orig" ]; then
            mv -f "${wrapper}.orig" "$wrapper"
        elif [ -n "$url" ]; then
            printf '#!/usr/bin/env bash\nbash <(curl -Ls %s) $1\n' "$url" > "$wrapper"
        else
            red "无法还原 sb.sh (缺少备份和主脚本地址)，请用主脚本重新安装以重建 sb 快捷指令"
        fi
        chmod +x "$wrapper"
    fi
    rm -f "${wrapper}.quota.bak"
    [ "$others" = 0 ] && rm -f "${wrapper}.quota.orig"
    if [ "$others" = 0 ] && [ -z "$SB_WORK_DIR" ] && [ -f "${plugin_dir}/quota_sb_link_created" ] && [ -L /usr/bin/sb ]; then
        rm -f /usr/bin/sb
    fi
    rm -f "$payload_file" "${plugin_dir}/quota_sb_link_created"
    # main_url 为各插件共用, 其它插件还在就保留
    [ "$others" = 0 ] && rm -f "${plugin_dir}/main_url"
    rmdir "$plugin_dir" 2>/dev/null
    green "\n插件已卸载，菜单项与数据已清除。"
}

do_status() {
    if [ -f "$wrapper" ] && grep -q "quota-inject.sh" "$wrapper"; then
        local no; no=$(preview_menu_no)
        green "已接入 sb.sh，菜单位置: 10. WARP分流管理 → ${no:-?}. 代理流量限制"
    else
        yellow "未接入 (${wrapper} 里没有本插件的注入器；若刚更新过 proxyip 插件，请重新运行本插件安装命令)"
    fi
    if [ -f "${work_dir}/quota.json" ] && command -v jq >/dev/null 2>&1; then
        echo "已设置限制的出站数: $(jq '.limits | length' "${work_dir}/quota.json" 2>/dev/null)"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet sb-quota 2>/dev/null && echo "监控服务 sb-quota: 运行中" || echo "监控服务 sb-quota: 未运行"
    fi
}

case "${1:-install}" in
    install|-i)    do_install ;;
    uninstall|-u)  do_uninstall ;;
    status|-s)     do_status ;;
    *) echo "用法: bash 本脚本 [install|uninstall|status]"; exit 1 ;;
esac
