#!/bin/sh

# Setup log
exec >> "/root/setup-xidzswrt.log" 2>&1

main() {
    date=$(date +"%d%m%Y")
    date
    echo "Starting XIDZs-WRT configuration."

    # System & Auth
    echo "Setting system identity and root password."
    # OS vars
    RELEASE_FILE="/etc/openwrt_release"
    TTYD_JSON="/usr/share/luci/menu.d/luci-app-ttyd.json"

    # Check OS
    if [ -f "$RELEASE_FILE" ]; then
        echo "Checking system release..."
        if grep -q "ImmortalWrt" "$RELEASE_FILE"; then
            sed -i 's/\(DISTRIB_DESCRIPTION='\''ImmortalWrt [0-9]*\.[0-9]*\.[0-9]*\).*'\''/\1'\''/g' "$RELEASE_FILE"
            [ -f "$TTYD_JSON" ] && sed -i 's|system/ttyd|services/ttyd|g' "$TTYD_JSON"
            BRANCH_VERSION=$(grep 'DISTRIB_DESCRIPTION=' "$RELEASE_FILE" | awk -F"'" '{print $2}')
            echo "ImmortalWrt detected - $BRANCH_VERSION"
        elif grep -q "OpenWrt" "$RELEASE_FILE"; then
            sed -i 's/\(DISTRIB_DESCRIPTION='\''OpenWrt [0-9]*\.[0-9]*\.[0-9]*\).*'\''/\1'\''/g' "$RELEASE_FILE"
            BRANCH_VERSION=$(grep 'DISTRIB_DESCRIPTION=' "$RELEASE_FILE" | awk -F"'" '{print $2}')
            echo "OpenWrt detected - $BRANCH_VERSION"
        else
            echo "Unknown system release."
        fi
    else
        echo "$RELEASE_FILE not found, skipping OS check."
    fi

    # Repos
    echo "Applying custom repos."
    if [ -f /etc/opkg.conf ]; then
        local arch os_ver
        arch=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')
        os_ver=$(grep "VERSION_ID" /etc/os-release | awk -F '"' '{print $2}' | awk -F. '{print $1"."$2}')
        
        # Override version 23.05 to 24.10
        [ "$os_ver" = "23.05" ] && os_ver="24.10"
        
        sed -i 's/option check_signature/# option check_signature/g' /etc/opkg.conf
        echo "src/gz custom_packages https://dl.openwrt.ai/packages-${os_ver}/${arch}/kiddin9/" >> /etc/opkg/customfeeds.conf
        echo "Custom repo integrated."
    elif [ -d /etc/apk ]; then
        echo "apk-based system detected, skipping opkg repo setup."
    else
        echo "opkg.conf not found. Skipping."
    fi
    
    (echo "quenx"; sleep 1; echo "quenx") | passwd >/dev/null 2>&1

    # Core System
    echo "Applying timezone, NTP, and terminal settings."
    uci -q batch <<EOF
set system.@system[0].hostname='XIDZs-WRT'
set system.@system[0].timezone='WIB-7'
set system.@system[0].zonename='Asia/Jakarta'
delete system.ntp.server
add_list system.ntp.server='pool.ntp.org'
add_list system.ntp.server='id.pool.ntp.org'
add_list system.ntp.server='time.google.com'
set luci.@core[0].lang='en'
set luci.main.mediaurlbase='/luci-static/argon'
set ttyd.@ttyd[0].command='/bin/bash --login'
commit system
commit luci
commit ttyd
EOF

    # Network interface and firewall
    echo "Setting network and firewall."
    uci -q batch <<EOF
set network.globals.packet_steering='2'
set network.globals.steering_flows='4096'
delete network.globals.ula_prefix
set network.lan.delegate='0'
delete network.lan.ip6assign
set network.wan=interface
set network.wan.proto='dhcp'
set network.wan.device='eth1'
set network.wan.peerdns='0'
delete network.wan.dns
add_list network.wan.dns='1.1.1.1'
add_list network.wan.dns='8.8.8.8'
set network.tethering=interface
set network.tethering.proto='dhcp'
set network.tethering.device='usb0'
set network.tethering.peerdns='0'
delete network.tethering.dns
add_list network.tethering.dns='1.1.1.1'
add_list network.tethering.dns='8.8.8.8'
delete network.wan6
delete firewall.@zone[1].network
add_list firewall.@zone[1].network='tethering'
add_list firewall.@zone[1].network='wan'
add_list firewall.@zone[1].network='modem'
add_list firewall.@zone[1].network='mm'
set firewall.@zone[1].mtu_fix='1'
commit network
commit firewall
set dhcp.@dnsmasq[0].cachesize='4096'
set dhcp.@dnsmasq[0].min_cache_ttl='60'
set dhcp.@dnsmasq[0].filter_aaaa='1'
set dhcp.lan.ra='disabled'
set dhcp.lan.dhcpv6='disabled'
set dhcp.lan.ndp='disabled'
commit dhcp
EOF
    /etc/init.d/odhcpd disable 2>/dev/null || true
    /etc/init.d/odhcpd stop 2>/dev/null || true

    # Unload unused 8189fs WiFi module on WIFIOFF targets
    grep -q "rmmod 8189fs" /etc/rc.local || sed -i '/exit 0/i rmmod 8189fs 2>/dev/null || true' /etc/rc.local

    # Set CPU governor to schedutil and persist across reboots
    if [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && grep -qw schedutil /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -w "$gov" ] && echo "schedutil" > "$gov"
        done
        grep -q "scaling_governor" /etc/rc.local || sed -i '/exit 0/i for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo schedutil > "$g"; done' /etc/rc.local
    fi

    # Disable balethirq.pl so it does not override rc.local / packet_steering RPS/XPS
    [ -f /usr/sbin/balethirq.pl ] && chmod -x /usr/sbin/balethirq.pl 2>/dev/null || true

    # Enable BBR congestion control if supported by kernel
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        mkdir -p /etc/modules.d /etc/sysctl.d
        echo "tcp_bbr" > /etc/modules.d/99-tcp-bbr
        echo "net.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    fi

    # USB Mode
    [ -f /etc/usb-mode.json ] && sed -i -e '/12d1:15c1/,+5d' -e '/413c:81d7/,+5d' /etc/usb-mode.json

    # UI & Tinyfm
    echo "Applying UI mods (tinyfm)."
    if [ -d /www/tinyfm ]; then
        ln -sfn / /www/tinyfm/rootfs
        [ -d /etc/openclash ] && ln -sfn /etc/openclash /www/tinyfm/openclash
    fi
    
    # LuCI
    inc="/www/luci-static/resources/view/status/include"
    if [ -d "$inc" ]; then
        sed -i "s#_('Firmware Version'),(L.isObject(boardinfo.release)?boardinfo.release.description+' / ':'')+(luciversion||''),#_('Firmware Version'),(L.isObject(boardinfo.release)?boardinfo.release.description+' | build by xidz_x [$date]':''),#g" "$inc"/10_system.js
        sed -i -E 's/icons\/port_%s\.(svg|png)/icons\/port_%s.gif/g' "$inc"/29_ports.js
        if [ -f "$inc/29_ports.js" ]; then
            mv "$inc/29_ports.js" "$inc/11_ports.js"
        fi
    fi

    # NetMonitor: cache-busting, protocol-relative iframe, and HG680P interfaces
    if [ -f /usr/lib/lua/luci/view/netmonitor.htm ]; then
        sed -i 's|"http://" + window\.location\.hostname + "/netmonitor/index\.html"|"/netmonitor/index.html?v=" + Date.now()|g' /usr/lib/lua/luci/view/netmonitor.htm
    fi
    if [ -f /www/netmonitor/index.html ]; then
        sed -i 's|<script src="script\.js"></script>|<script src="script.js?v=1.4.0"></script>|g' /www/netmonitor/index.html
        if ! grep -q '#systemGrid' /www/netmonitor/index.html; then
            awk '/<\/style>/ && !done {
                print "@media (min-width: 640px) {"
                print "  .slider-container { display: grid; grid-template-columns: repeat(auto-fit, minmax(175px, 1fr)); gap: 12px; justify-content: stretch; overflow-x: visible; padding-bottom: 0; }"
                print "  #systemGrid { grid-template-columns: repeat(3, minmax(0, 1fr)); }"
                print "  .slider-item { flex: none; min-width: 0; }"
                print "}"
                print "@media (min-width: 960px) {"
                print "  #systemGrid { grid-template-columns: repeat(6, minmax(0, 1fr)); }"
                print "  #systemGrid .panel-title { font-size: 0.72rem; white-space: nowrap; }"
                print "}"
                done=1
            } { print }' /www/netmonitor/index.html > /tmp/nm_idx.html && mv /tmp/nm_idx.html /www/netmonitor/index.html
        fi
    fi
    if [ -f /www/netmonitor/script.js ]; then
        grep -q "'eth0'" /www/netmonitor/script.js || sed -i "s|'br-lan','eth1'|'br-lan','eth0','eth1'|g; s|'wwan0','wwan1'|'phy0-ap0','wwan0','wwan1'|g" /www/netmonitor/script.js
    fi
    if uci -q get netmonitor.main >/dev/null 2>&1; then
        uci -q batch <<'NMEOF'
delete netmonitor.main.iface
add_list netmonitor.main.iface='br-lan'
add_list netmonitor.main.iface='eth0'
add_list netmonitor.main.iface='wwan0'
add_list netmonitor.main.iface='usb0'
commit netmonitor
NMEOF
    fi
    
    # Disable apk-cheatsheet (OS 25.12+)
    [ -f /etc/profile.d/apk-cheatsheet.sh ] && mv -f /etc/profile.d/apk-cheatsheet.sh /etc/profile.d/apk-cheatsheet.bak
    
    # profile
    sed -i -e 's/\[ -f \/etc\/banner \] && cat \/etc\/banner$/#&/' -e 's/\[ -n "\$FAILSAFE" \].*cat \/etc\/banner\.failsafe$/& || \/usr\/bin\/syntax/' /etc/profile
    
    # Tunnel

    # Web & PHP
    echo "Optimizing uhttpd and PHP."
    uci -q batch <<EOF
set uhttpd.main.ubus_prefix='/ubus'
set uhttpd.main.interpreter='.php=/usr/bin/php-cgi'
set uhttpd.main.index_page='cgi-bin/luci'
add_list uhttpd.main.index_page='index.html'
add_list uhttpd.main.index_page='index.php'
commit uhttpd
EOF

    if [ -f /etc/php.ini ]; then
        cp /etc/php.ini /etc/php.ini.bak
        
        # Optimize PHP settings
        sed -i 's|^memory_limit = .*|memory_limit = 128M|' /etc/php.ini
        sed -i 's|^max_execution_time = .*|max_execution_time = 60|' /etc/php.ini
        sed -i 's|^display_errors = .*|display_errors = Off|' /etc/php.ini
        sed -i 's|^;*date\.timezone =.*|date.timezone = Asia/Jakarta|' /etc/php.ini
        
        echo "PHP optimized."
    else
        echo "php.ini missing."
    fi
    
    [ -d /usr/lib/php8 ] && ln -sf /usr/lib/php8 /usr/lib/php

    echo "XIDZs-WRT configuration completed."
    date
}

# Run
main

# Save to flash
sync

# Exit
exit 0
