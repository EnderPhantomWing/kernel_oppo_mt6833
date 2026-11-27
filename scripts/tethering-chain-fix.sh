#!/system/bin/sh
#
# 修复「个人热点 / USB 共享开不了」——netd 的 tetherctrl_counters 链缺失
#
# 背景（在设备上实测确认的完整因果链）：
#   1. netd 的 TetherController::setupIptablesHooks() 依次做三件事：
#        a) setDefaults()                                   -> 正常
#        b) iptables -t mangle -A tetherctrl_mangle_FORWARD ... -j TCPMSS --clamp-mss-to-pmtu
#           (netd 注释：no longer optional, 失败则 tethering 起不来)
#        c) ip6tables/iptables -t filter -N tetherctrl_counters
#   2. 本 ROM 的 iptables(userspace) 不认 --clamp-mss-to-pmtu：
#        iptables v1.8.7 (legacy): unknown option "--clamp-mss-to-pmtu"
#      实测 --set-mss 同样报 unknown option —— 说明 /system 里的
#      libxt_TCPMSS.so 是个没有选项表的空壳扩展（不是只缺某一项）。
#      于是 b) 失败，setupIptablesHooks() 直接 return，c) 永远不执行。
#   3. 开热点时 TetherController::enableNat() 执行
#        ip6tables -t filter -A tetherctrl_FORWARD -g tetherctrl_counters
#      报 "goto 'tetherctrl_counters' is not a chain" -> 返回 -EREMOTEIO(121)
#   4. Tethering 记录 TETHER_ERROR_ENABLE_FORWARDING_ERROR(8)：
#        dumpsys tethering -> ap0 / rndis0 - lastError = 8
#      USB 共享、Wi-Fi 热点同时失效；tether stats 也报 EPERM（同一条链）。
#
# 本脚本开机后把这条计数链补上即可。netd 的 setDefaults() 不会删除它，
# 之后 enableNat() 的 -g 目标存在，NAT / forward 规则就能正常下发。
#
# 安装（KernelSU / Magisk 均可）：
#   adb push scripts/tethering-chain-fix.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/tethering-chain-fix.sh'      # 立即生效
#   adb shell su -c 'cp /data/local/tmp/tethering-chain-fix.sh /data/adb/service.d/'
#   adb shell su -c 'chmod 755 /data/adb/service.d/tethering-chain-fix.sh'
#
# 立即生效后无需重启，直接开一次热点/USB 共享验证。

set -u

# service.d 在 late_start 执行；这里再等一次 boot_completed，确保 iptables 可用
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
done
sleep 2

# v4 / v6 两条计数链；已存在时 -N 会失败，忽略即可
iptables  -t filter -N tetherctrl_counters 2>/dev/null
ip6tables -t filter -N tetherctrl_counters 2>/dev/null

# 留个痕迹，便于确认脚本跑过
log -t tethering-fix "tetherctrl_counters chain ensured (v4=$?), $(date)" 2>/dev/null

exit 0
