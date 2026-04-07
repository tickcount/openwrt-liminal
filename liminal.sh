#!/bin/sh
# liminal.sh
# OpenWRT 24.10 / BusyBox ash
# Developer: Salvatore (GitHub: @tickcount)
# Credits: @immalware — config download service (https://t.me/immalware)

set -eu

SCRIPT_NAME="$(basename "$0")"
BACKUP_DIR=""
LIMINAL_VERSION="1.0"

# ─── Colors (soft white-blue-violet palette) ─────────────────────────

W="\033[1;37m"                # white bold
B="\033[38;5;111m"            # soft blue
V="\033[38;5;141m"            # soft violet
A="\033[38;5;183m"            # soft lavender (accents)
DIM="\033[38;5;245m"          # dim gray
OK="\033[38;5;114m"           # soft green
ERR="\033[38;5;174m"          # soft rose/red
NC="\033[0m"

log()  { printf '%s\n' "$*"; }
warn() { echo -e "${ERR}warning:${NC} $*" >&2; }
die()  { echo -e "${ERR}error:${NC} $*" >&2; exit 1; }
PAUSE() { echo -ne "\n${DIM}Press Enter...${NC}"; read dummy; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ─── Backup / Restore ────────────────────────────────────────────────

init_backup() {
    _reason="${1:-Manual}"
    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/root/liminal-backups/${TS}"
    mkdir -p "$BACKUP_DIR"
    cp /etc/config/network  "$BACKUP_DIR/network.bak"
    cp /etc/config/firewall "$BACKUP_DIR/firewall.bak"
    [ -f /etc/config/podkop ] && cp /etc/config/podkop "$BACKUP_DIR/podkop.bak" || true
    echo "$_reason" > "$BACKUP_DIR/.reason"
    date '+%Y-%m-%d %H:%M:%S' > "$BACKUP_DIR/.date"
}

BACKUP_BASE="/root/liminal-backups"
AUTOBACKUP_OFF="/root/liminal-backups/.noautobackup"

autobackup_enabled() { ! [ -f "$AUTOBACKUP_OFF" ]; }

restore_backups() {
    log "Restoring backups from $BACKUP_DIR ..."
    [ -f "$BACKUP_DIR/network.bak" ]  && cp "$BACKUP_DIR/network.bak"  /etc/config/network
    [ -f "$BACKUP_DIR/firewall.bak" ] && cp "$BACKUP_DIR/firewall.bak" /etc/config/firewall
    [ -f "$BACKUP_DIR/podkop.bak" ]   && cp "$BACKUP_DIR/podkop.bak"   /etc/config/podkop || true
    /etc/init.d/network reload   >/dev/null 2>&1 || true
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop restart >/dev/null 2>&1 || true
}

on_error() {
    trap - INT TERM HUP
    echo ""
    exit 1
}

trap on_error INT TERM HUP

# Flag for cancellable sections
_CANCELLED=0

# Call at start of cancellable flow (create, rename, etc.)
trap_cancel() {
    _CANCELLED=0
    trap '_CANCELLED=1; trap on_error INT' INT
}

# Call at end to restore default trap
trap_restore() {
    trap on_error INT
}

# Check if cancelled
is_cancelled() { [ "$_CANCELLED" -eq 1 ]; }

# ─── Input helpers ────────────────────────────────────────────────────

prompt() {
    _var="$1"; _q="$2"; _def="${3:-}"
    if [ -n "$_def" ]; then
        printf "%s [%s]: " "$_q" "$_def"
    else
        printf "%s: " "$_q"
    fi
    read -r _ans || true
    # Check if Ctrl+C was pressed during read
    is_cancelled && { eval "$_var="; return 1; }
    # Strip control characters
    _ans="$(printf '%s' "${_ans:-}" | tr -d '\001-\037\177')"
    [ -z "${_ans:-}" ] && _ans="$_def"
    eval "$_var=\$_ans"
}

confirm() {
    _q="$1"; _def="${2:-y}"
    if [ "$_def" = "y" ]; then
        printf "%s ${B}1)${NC} ${OK}Yes${NC}  ${B}2)${NC} ${DIM}No${NC}  [1]: " "$_q"
    else
        printf "%s ${B}1)${NC} ${DIM}Yes${NC}  ${B}2)${NC} ${ERR}No${NC}  [2]: " "$_q"
    fi
    read -r _ans || true
    _ans="$(printf '%s' "${_ans:-}" | tr -d '\001-\037\177')"
    case "${_ans:-}" in
        1|y|Y|yes) return 0 ;;
        2|n|N|no) return 1 ;;
        "") [ "$_def" = "y" ] && return 0 || return 1 ;;
        *) [ "$_def" = "y" ] && return 0 || return 1 ;;
    esac
}

# ─── Validators ───────────────────────────────────────────────────────

validate_ifname() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$' || { warn "Invalid interface name: $1"; return 1; }
}

validate_zone_name() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$' || { warn "Invalid firewall zone name: $1"; return 1; }
}

validate_ipv4() {
    printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { warn "Invalid IPv4 address: $1"; return 1; }
    OLDIFS="$IFS"; IFS='.'; set -- $1; IFS="$OLDIFS"
    for o in "$@"; do
        [ "$o" -ge 0 ] 2>/dev/null || { warn "Invalid IPv4 address: $1"; return 1; }
        [ "$o" -le 255 ] 2>/dev/null || { warn "Invalid IPv4 address: $1"; return 1; }
    done
}

validate_port() {
    case "$1" in ''|*[!0-9]*) warn "Port must be numeric"; return 1 ;; esac
    [ "$1" -ge 1 ]     2>/dev/null || { warn "Port must be >= 1"; return 1; }
    [ "$1" -le 65535 ] 2>/dev/null || { warn "Port must be <= 65535"; return 1; }
}

validate_cidr_ipv4() {
    printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' \
        || { warn "Invalid IPv4 CIDR: $1"; return 1; }
    ip_part="${1%/*}"; mask_part="${1#*/}"
    validate_ipv4 "$ip_part" || return 1
    [ "$mask_part" -ge 0 ]  2>/dev/null || { warn "Invalid CIDR mask: $1"; return 1; }
    [ "$mask_part" -le 32 ] 2>/dev/null || { warn "Invalid CIDR mask: $1"; return 1; }
}

# ─── Network math ─────────────────────────────────────────────────────

mask_from_cidr() {
    cidr="$1"; prefix="${cidr#*/}"
    validate_cidr_ipv4 "$cidr"
    full=$((prefix / 8)); rem=$((prefix % 8))
    oct1=0; oct2=0; oct3=0; oct4=0
    i=1
    while [ "$i" -le 4 ]; do
        if [ "$full" -ge "$i" ]; then
            val=255
        elif [ "$full" -eq $((i - 1)) ] && [ "$rem" -gt 0 ]; then
            val=$((256 - 2 ** (8 - rem)))
        else
            val=0
        fi
        case "$i" in
            1) oct1="$val" ;; 2) oct2="$val" ;;
            3) oct3="$val" ;; 4) oct4="$val" ;;
        esac
        i=$((i + 1))
    done
    printf '%s.%s.%s.%s\n' "$oct1" "$oct2" "$oct3" "$oct4"
}

network_base_from_cidr() {
    cidr="$1"; ip="${cidr%/*}"; mask="$(mask_from_cidr "$cidr")"
    OLDIFS="$IFS"; IFS='.'
    set -- $ip;   ip1="$1"; ip2="$2"; ip3="$3"; ip4="$4"
    set -- $mask; m1="$1";  m2="$2";  m3="$3";  m4="$4"
    IFS="$OLDIFS"
    printf '%s.%s.%s.%s/%s\n' \
        $((ip1 & m1)) $((ip2 & m2)) $((ip3 & m3)) $((ip4 & m4)) "${cidr#*/}"
}

cidr_contains_ip() {
    cidr="$1"; ip="$2"
    base="$(network_base_from_cidr "$cidr")"; base_ip="${base%/*}"
    mask="$(mask_from_cidr "$cidr")"
    OLDIFS="$IFS"; IFS='.'
    set -- $ip;      ip1="$1"; ip2="$2"; ip3="$3"; ip4="$4"
    set -- $mask;    m1="$1";  m2="$2";  m3="$3";  m4="$4"
    set -- $base_ip; b1="$1";  b2="$2";  b3="$3";  b4="$4"
    IFS="$OLDIFS"
    [ $((ip1 & m1)) -eq "$b1" ] && [ $((ip2 & m2)) -eq "$b2" ] && \
    [ $((ip3 & m3)) -eq "$b3" ] && [ $((ip4 & m4)) -eq "$b4" ]
}

# ─── UCI / firewall queries ──────────────────────────────────────────

uci_network_exists() { uci -q get "network.$1" >/dev/null 2>&1; }

zone_exists() {
    i=0
    while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
        [ "$(uci -q get "firewall.@zone[$i].name" || true)" = "$1" ] && return 0
        i=$((i+1))
    done
    return 1
}

list_zones() {
    i=0
    while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
        uci -q get "firewall.@zone[$i].name" || true
        i=$((i+1))
    done
}

find_zone_index() {
    i=0
    while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
        if [ "$(uci -q get "firewall.@zone[$i].name" || true)" = "$1" ]; then
            echo "$i"; return 0
        fi
        i=$((i+1))
    done
    return 1
}

find_zone_for_interface() {
    _ifname="$1"; i=0
    while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
        _networks="$(uci -q get "firewall.@zone[$i].network" || true)"
        for _net in $_networks; do
            if [ "$_net" = "$_ifname" ]; then
                uci -q get "firewall.@zone[$i].name" || true
                return 0
            fi
        done
        i=$((i+1))
    done
    return 1
}

forwarding_exists() {
    src="$1"; dst="$2"; i=0
    while uci -q get "firewall.@forwarding[$i]" >/dev/null 2>&1; do
        cur_src="$(uci -q get "firewall.@forwarding[$i].src"  || true)"
        cur_dst="$(uci -q get "firewall.@forwarding[$i].dest" || true)"
        [ "$cur_src" = "$src" ] && [ "$cur_dst" = "$dst" ] && return 0
        i=$((i+1))
    done
    return 1
}

rule_exists_by_name() {
    name="$1"; i=0
    while uci -q get "firewall.@rule[$i]" >/dev/null 2>&1; do
        [ "$(uci -q get "firewall.@rule[$i].name" || true)" = "$name" ] && return 0
        i=$((i+1))
    done
    return 1
}

port_in_use() {
    port="$1"
    if have_cmd ss; then
        ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$"
        return $?
    fi
    if have_cmd netstat; then
        netstat -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
        return $?
    fi
    die "Neither 'ss' nor 'netstat' is available"
}

firewall_port_in_use() {
    port="$1"; i=0
    while uci -q get "firewall.@rule[$i]" >/dev/null 2>&1; do
        rule_port="$(uci -q get "firewall.@rule[$i].dest_port" || true)"
        if [ "$rule_port" = "$port" ]; then
            uci -q get "firewall.@rule[$i].name" || echo "unnamed-rule-$i"
            return 0
        fi
        i=$((i+1))
    done
    return 1
}

interface_device_exists() { ip link show "$1" >/dev/null 2>&1; }

# ─── Auto-detection helpers ──────────────────────────────────────────

detect_router_lan_ip() {
    _ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
    [ -n "$_ip" ] && { printf '%s\n' "$_ip"; return 0; }

    _ip="$(ip -4 addr show br-lan 2>/dev/null | awk '/inet / {print $2}' | head -n1)"
    _ip="${_ip%/*}"
    [ -n "$_ip" ] && { printf '%s\n' "$_ip"; return 0; }

    _ip="$(ip -4 addr show lan 2>/dev/null | awk '/inet / {print $2}' | head -n1)"
    _ip="${_ip%/*}"
    [ -n "$_ip" ] && { printf '%s\n' "$_ip"; return 0; }

    return 1
}

generate_zone_name() {
    _ifname="$1"; _candidate="$_ifname"
    if zone_exists "$_candidate"; then
        _n=1
        while zone_exists "${_ifname}_${_n}"; do _n=$((_n + 1)); done
        _candidate="${_ifname}_${_n}"
    fi
    printf '%s\n' "$_candidate"
}

generate_rule_name() {
    _ifname="$1"; _candidate="Allow-AWG-${_ifname}"
    if rule_exists_by_name "$_candidate"; then
        _n=1
        while rule_exists_by_name "Allow-AWG-${_ifname}-${_n}"; do _n=$((_n + 1)); done
        _candidate="Allow-AWG-${_ifname}-${_n}"
    fi
    printf '%s\n' "$_candidate"
}

# ─── AWG key generation ──────────────────────────────────────────────

generate_awg_keys() {
    priv="$(awg genkey)" || die "Failed to generate AWG private key"
    pub="$(printf '%s' "$priv" | awg pubkey)" || die "Failed to derive AWG public key"
    printf '%s\n%s\n' "$priv" "$pub"
}

# ─── Precondition checks ─────────────────────────────────────────────

ensure_required_tools() {
    have_cmd uci  || die "Missing command: uci"
    have_cmd ubus || die "Missing command: ubus"
    have_cmd fw4  || die "Missing command: fw4"
    have_cmd grep || die "Missing command: grep"
    have_cmd awk  || die "Missing command: awk"
    have_cmd ip   || die "Missing command: ip"
    (have_cmd ss || have_cmd netstat) || die "Need 'ss' or 'netstat'"
}

ensure_base_firewall() {
    zone_exists "wan" || die "Firewall zone 'wan' not found"
    zone_exists "lan" || die "Firewall zone 'lan' not found"
}

ensure_wan_masq() {
    wan_idx="$(find_zone_index "$WAN_ZONE" || true)"
    [ -n "$wan_idx" ] || die "Firewall zone '$WAN_ZONE' not found"
    masq="$(uci -q get "firewall.@zone[$wan_idx].masq" || true)"
    if [ "$masq" != "1" ]; then
        warn "Masquerading disabled on '$WAN_ZONE'. VPN clients may lack internet."
        if confirm "Enable masquerading on '$WAN_ZONE'?" "y"; then
            uci set "firewall.@zone[$wan_idx].masq=1"
        fi
    fi
}

check_dangerous_forwarding() {
    dst_zone="$1"
    if forwarding_exists "$WAN_ZONE" "$dst_zone"; then
        warn "Existing forwarding: $WAN_ZONE -> $dst_zone"
        warn "This is usually unsafe for a VPN zone."
    fi
}

# ─── Podkop ───────────────────────────────────────────────────────────

podkop_present() { uci -q get podkop.settings >/dev/null 2>&1; }

podkop_has_interface() {
    ifname="$1"
    current="$(uci -q get podkop.settings.source_network_interfaces || true)"
    [ -z "$current" ] && return 1
    for item in $current; do [ "$item" = "$ifname" ] && return 0; done
    return 1
}

add_podkop_interface() {
    ifname="$1"
    podkop_has_interface "$ifname" && {
        log "Podkop already contains interface '$ifname'."
        return 0
    }
    uci add_list podkop.settings.source_network_interfaces="$ifname"
    uci commit podkop
}

remove_podkop_interface() {
    ifname="$1"
    podkop_has_interface "$ifname" || return 0
    uci del_list podkop.settings.source_network_interfaces="$ifname"
    uci commit podkop
}

# ─── Enumerate AWG interfaces ────────────────────────────────────────

get_awg_interfaces() {
    # Only return interfaces created by Liminal
    uci show network 2>/dev/null \
        | grep "\._is_liminal='1'" \
        | sed "s/\._is_liminal=.*//" \
        | sed "s/network\.//"
}

get_all_awg_interfaces() {
    # All amneziawg interfaces (including non-liminal)
    uci show network 2>/dev/null \
        | grep "\.proto='amneziawg'" \
        | sed "s/\.proto=.*//" \
        | sed "s/network\.//"
}

# ─── WAN IP detection (Endpoint) ─────────────────────────────────────

detect_wan_ip() {
    # OpenWRT: IPv4 Upstream -> Address
    if have_cmd ifstatus && have_cmd jsonfilter; then
        _ip="$(ifstatus wan 2>/dev/null \
            | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)"
        [ -n "$_ip" ] && { printf '%s\n' "$_ip"; return 0; }
    fi
    _wan_dev="$(uci -q get network.wan.device 2>/dev/null \
        || uci -q get network.wan.ifname 2>/dev/null || true)"
    if [ -n "$_wan_dev" ]; then
        _ip="$(ip -4 addr show "$_wan_dev" 2>/dev/null \
            | awk '/inet / {print $2}' | head -n1)"
        _ip="${_ip%/*}"
        [ -n "$_ip" ] && { printf '%s\n' "$_ip"; return 0; }
    fi
    return 1
}

# ─── Peer helpers ─────────────────────────────────────────────────────

get_ip_prefix() {
    # "10.10.10.1/24" → "10.10.10"
    _addr="$1"; _ip="${_addr%/*}"
    printf '%s\n' "$_ip" | sed 's/\.[0-9]*$//'
}

count_peers() {
    _iface="$1"
    _pt="amneziawg_${_iface}"
    _cnt="$(uci -q show network 2>/dev/null | grep -c "^network\..*=${_pt}$" 2>/dev/null)"
    echo "${_cnt:-0}"
}

count_active_peers() {
    _iface="$1"
    have_cmd awg || { echo "0"; return; }
    awg show 2>/dev/null | awk -v iface="$_iface" -v th=120 '
        /^interface:/ { cur=$2 }
        cur==iface && /latest handshake:/ {
            sub(/.*latest handshake: /,"")
            if (/never/) next
            t=0; for(i=1;i<=NF;i++){
                if($i~/^[0-9]+$/){n=$i;u=$(i+1)
                    if(u~/^second/)t+=n
                    else if(u~/^minute/)t+=n*60
                    else if(u~/^hour/)t+=n*3600
                    else if(u~/^day/)t+=n*86400}
            }
            if(t<=th) a++
        }
        END { print a+0 }
    '
}

active_peer_names() {
    # Returns comma-separated list of active peer names
    _iface="$1"; _pt="amneziawg_${_iface}"
    have_cmd awg || return
    _names=""
    _awg_out="$(awg show "$_iface" 2>/dev/null)"
    _pi=0
    while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
        _pk="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"
        _desc="$(uci -q get "network.@${_pt}[$_pi].description" || true)"
        [ -z "$_pk" ] && { _pi=$((_pi+1)); continue; }
        [ -z "$_desc" ] && _desc="peer$((_pi+1))"
        _sec="$(echo "$_awg_out" | awk -v pk="$_pk" '
            /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                sub(/.*latest handshake: /,"");
                if(/never/){print 9999999;exit}
                t=0;for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                    if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                    else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                print t;exit}')"
        [ "${_sec:-9999999}" -le 120 ] 2>/dev/null && \
            _names="${_names:+${_names}, }${_desc}"
        _pi=$((_pi+1))
    done
    echo "$_names"
}

get_peer_handshake() {
    # Returns human-readable handshake for a peer by public key
    # $1=iface, $2=public_key
    _iface="$1"; _pk="$2"
    have_cmd awg || { echo "-"; return; }
    awg show "$_iface" 2>/dev/null | awk -v pk="$_pk" '
        /peer:/ { cur=$NF }
        cur==pk && /latest handshake:/ {
            sub(/.*latest handshake: /,"")
            if (/never/) { print "never"; found=1; exit }
            t=0; for(i=1;i<=NF;i++){
                if($i~/^[0-9]+$/){n=$i;u=$(i+1)
                    if(u~/^second/)t+=n
                    else if(u~/^minute/)t+=n*60
                    else if(u~/^hour/)t+=n*3600
                    else if(u~/^day/)t+=n*86400}
            }
            if(t<60) printf "%ds\n",t
            else if(t<3600) printf "%dm\n",int(t/60)
            else if(t<86400) printf "%dh %dm\n",int(t/3600),int((t%3600)/60)
            else printf "%dd %dh\n",int(t/86400),int((t%86400)/3600)
            found=1; exit
        }
        END { if(!found) print "-" }
    '
}

get_peer_rx() {
    _iface="$1"; _pk="$2"
    have_cmd awg || return
    awg show "$_iface" 2>/dev/null | awk -v pk="$_pk" '
        /peer:/ { cur=$NF }
        cur==pk && /transfer:/ {
            sub(/.*transfer: /,"")
            # "1.24 MiB received, 3.47 MiB sent"
            match($0, /(.+) received/, a)
            if (RSTART) print a[1]
            else { split($0, p, ","); sub(/^ */, "", p[1]); sub(/ received.*/, "", p[1]); print p[1] }
            exit
        }
    '
}

get_peer_tx() {
    _iface="$1"; _pk="$2"
    have_cmd awg || return
    awg show "$_iface" 2>/dev/null | awk -v pk="$_pk" '
        /peer:/ { cur=$NF }
        cur==pk && /transfer:/ {
            sub(/.*transfer: /,"")
            match($0, /, (.+) sent/, a)
            if (RSTART) print a[1]
            else { split($0, p, ","); sub(/^ */, "", p[2]); sub(/ sent.*/, "", p[2]); print p[2] }
            exit
        }
    '
}

get_peer_endpoint_live() {
    _iface="$1"; _pk="$2"
    have_cmd awg || return
    awg show "$_iface" 2>/dev/null | awk -v pk="$_pk" '
        /peer:/ { cur=$NF }
        cur==pk && /endpoint:/ {
            sub(/.*endpoint: /,"")
            print
            exit
        }
    '
}

get_peer_keepalive_live() {
    _iface="$1"; _pk="$2"
    have_cmd awg || return
    awg show "$_iface" 2>/dev/null | awk -v pk="$_pk" '
        /peer:/ { cur=$NF }
        cur==pk && /persistent keepalive:/ {
            sub(/.*persistent keepalive: /,"")
            print
            exit
        }
    '
}

list_used_hosts() {
    _iface="$1"; _prefix="$2"
    _pt="amneziawg_${_iface}"
    uci -q show network 2>/dev/null \
        | grep "=${_pt}$" \
        | sed "s/^network\.//; s/=${_pt}$//" \
        | while read -r _sec; do
            uci -q get "network.${_sec}.allowed_ips" 2>/dev/null || true
        done \
        | sed -n "s/.*${_prefix}\.\([0-9]\{1,3\}\)\/32.*/\1/p" \
        | sort -n -u
}

pick_free_ip() {
    _iface="$1"; _prefix="$2"
    _used="$(list_used_hosts "$_iface" "$_prefix")"
    _x=2
    while [ "$_x" -le 254 ]; do
        if echo "$_used" | grep -qx "$_x" 2>/dev/null; then
            _x=$((_x + 1)); continue
        fi
        printf '%s.%s/32\n' "$_prefix" "$_x"
        return 0
    done
    die "No free IPs in ${_prefix}.2-254"
}

awg_iface_show_val() {
    # $1 = iface, $2 = key (e.g. "h1", "listening port")
    have_cmd awg || return 0
    awg show "$1" 2>/dev/null \
        | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" \
        | head -n1 || true
}

# ─── Amnezia config output ───────────────────────────────────────────

emit_peer_config() {
    _iface="$1"; _client_priv="$2"; _client_v4="$3"; _client_v6="$4"
    _server_pub="$5"; _conf="$6"; _host="$7"; _port="$8"

    _H1="$(awg_iface_show_val "$_iface" "h1")"; [ -n "$_H1" ] || _H1="1"
    _H2="$(awg_iface_show_val "$_iface" "h2")"; [ -n "$_H2" ] || _H2="2"
    _H3="$(awg_iface_show_val "$_iface" "h3")"; [ -n "$_H3" ] || _H3="3"
    _H4="$(awg_iface_show_val "$_iface" "h4")"; [ -n "$_H4" ] || _H4="4"
    _I1="$(awg_iface_show_val "$_iface" "i1")"; [ -n "$_I1" ] || _I1="0"

    _MTU="$(uci -q get "network.${_iface}.mtu" || echo "1280")"

    _conf_crlf="$(printf "%s" "$_conf" | sed 's/$/\r/')"

    _AWG_JSON="$(jq -n \
      --arg pr "$_client_priv" \
      --arg i1 "$_I1" \
      --arg v4 "$_client_v4" \
      --arg v6 "${_client_v6:-}" \
      --arg pp "$_server_pub" \
      --arg cf "$_conf_crlf" \
      --arg h1 "$_H1" --arg h2 "$_H2" --arg h3 "$_H3" --arg h4 "$_H4" \
      --arg host "$_host" \
      --arg port "$_port" \
      --arg mtu "$_MTU" \
      '{
          H1: $h1, H2: $h2, H3: $h3, H4: $h4,
          I1: $i1, Jc: "120", Jmax: "911", Jmin: "23", S1: "0", S2: "0",
          allowed_ips: ["0.0.0.0/0", "::/0"],
          client_ip: (if $v6 != "" then ($v4 + ", " + $v6) else $v4 end),
          client_priv_key: $pr,
          config: $cf,
          hostName: $host,
          mtu: ($mtu|tonumber),
          port: ($port|tonumber),
          server_pub_key: $pp
      }'
    )"

    _AMNEZIA_JSON="$(jq -n \
      --arg last "$_AWG_JSON" \
      --arg name "AWG $_iface" \
      --arg host "$_host" \
      --arg port "$_port" \
      '{
          containers: [{
              container: "amnezia-awg",
              awg: {
                  isThirdPartyConfig: true,
                  last_config: $last,
                  port: $port,
                  transport_proto: "udp"
              }
          }],
          defaultContainer: "amnezia-awg",
          description: $name,
          hostName: $host
      }'
    )"

    _VPN_KEY="vpn://$(printf "%s" "$_AMNEZIA_JSON" \
        | base64 -w 0 2>/dev/null \
        || printf "%s" "$_AMNEZIA_JSON" | base64)"

    echo ""
    echo -e "${V}── Peer Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    echo ""
    echo -e "${A}AmneziaVPN key:${NC}"
    echo "$_VPN_KEY"
    echo ""

    _conf_b64="$(printf "%s" "$_conf" \
        | base64 -w 0 2>/dev/null \
        || printf "%s" "$_conf" | base64)"
    echo -e "${A}Download:${NC} https://immalware.vercel.app/download?filename=awg_${_iface}.conf&content=${_conf_b64}"
    echo ""

    if have_cmd qrencode; then
        echo -e "${A}QR Code:${NC}"
        qrencode -t ANSIUTF8 "$_conf" 2>/dev/null || true
        echo ""
    fi
}

# ─── Reconstruct peer config from UCI ─────────────────────────────

reconstruct_peer_config() {
    _iface="$1"; _idx="$2"
    _pt="amneziawg_${_iface}"

    _client_priv="$(uci -q get "network.@${_pt}[$_idx].private_key" || true)"
    [ -z "$_client_priv" ] && { echo ""; return 1; }

    _peer_ip="$(uci -q get "network.@${_pt}[$_idx].allowed_ips" || echo "?")"
    _keepalive="$(uci -q get "network.@${_pt}[$_idx].persistent_keepalive" || echo "25")"

    _server_priv="$(uci -q get "network.${_iface}.private_key" || true)"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey 2>/dev/null || true)"

    _port="$(uci -q get "network.${_iface}.listen_port" || echo "51820")"
    _dns="$(uci -q get "network.${_iface}.dns" || true)"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "1.1.1.1")"

    _endpoint_host="$(detect_wan_ip || true)"
    [ -z "$_endpoint_host" ] && _endpoint_host="YOUR_SERVER_IP"

    printf "[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s:%s\nPersistentKeepAlive = %s\n" \
        "$_client_priv" "$_peer_ip" "$_dns" "$_server_pub" "$_endpoint_host" "$_port" "$_keepalive"
}

build_vpn_key() {
    _iface="$1"; _idx="$2"
    _pt="amneziawg_${_iface}"

    _client_priv="$(uci -q get "network.@${_pt}[$_idx].private_key" || true)"
    _client_v4="$(uci -q get "network.@${_pt}[$_idx].allowed_ips" || true)"

    _server_priv="$(uci -q get "network.${_iface}.private_key" || true)"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey 2>/dev/null || true)"

    _port="$(uci -q get "network.${_iface}.listen_port" || echo "51820")"
    _dns="$(uci -q get "network.${_iface}.dns" || true)"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "1.1.1.1")"
    _endpoint_host="$(detect_wan_ip || true)"
    [ -z "$_endpoint_host" ] && _endpoint_host="YOUR_SERVER_IP"

    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"

    _H1="$(awg_iface_show_val "$_iface" "h1")"; [ -n "$_H1" ] || _H1="1"
    _H2="$(awg_iface_show_val "$_iface" "h2")"; [ -n "$_H2" ] || _H2="2"
    _H3="$(awg_iface_show_val "$_iface" "h3")"; [ -n "$_H3" ] || _H3="3"
    _H4="$(awg_iface_show_val "$_iface" "h4")"; [ -n "$_H4" ] || _H4="4"
    _I1="$(awg_iface_show_val "$_iface" "i1")"; [ -n "$_I1" ] || _I1="0"
    _MTU="$(uci -q get "network.${_iface}.mtu" || echo "1280")"

    _conf_crlf="$(printf "%s" "$_conf" | sed 's/$/\r/')"

    _AWG_JSON="$(jq -n \
      --arg pr "$_client_priv" --arg i1 "$_I1" \
      --arg v4 "$_client_v4" --arg v6 "" \
      --arg pp "$_server_pub" --arg cf "$_conf_crlf" \
      --arg h1 "$_H1" --arg h2 "$_H2" --arg h3 "$_H3" --arg h4 "$_H4" \
      --arg host "$_endpoint_host" --arg port "$_port" --arg mtu "$_MTU" \
      '{
          H1: $h1, H2: $h2, H3: $h3, H4: $h4,
          I1: $i1, Jc: "120", Jmax: "911", Jmin: "23", S1: "0", S2: "0",
          allowed_ips: ["0.0.0.0/0", "::/0"],
          client_ip: $v4, client_priv_key: $pr, config: $cf,
          hostName: $host, mtu: ($mtu|tonumber), port: ($port|tonumber),
          server_pub_key: $pp
      }'
    )"

    _AMNEZIA_JSON="$(jq -n \
      --arg last "$_AWG_JSON" --arg name "AWG $_iface" \
      --arg host "$_endpoint_host" --arg port "$_port" \
      '{
          containers: [{ container: "amnezia-awg", awg: {
              isThirdPartyConfig: true, last_config: $last,
              port: $port, transport_proto: "udp"
          }}],
          defaultContainer: "amnezia-awg", description: $name, hostName: $host
      }'
    )"

    printf "vpn://%s" "$(printf "%s" "$_AMNEZIA_JSON" \
        | base64 -w 0 2>/dev/null \
        || printf "%s" "$_AMNEZIA_JSON" | base64)"
}

# ─── Individual peer display functions ────────────────────────────

show_peer_conf() {
    _conf="$(reconstruct_peer_config "$1" "$2")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; PAUSE; return; }
    echo ""
    echo -e "${V}── Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    PAUSE
}

show_peer_qr() {
    have_cmd qrencode || { warn "qrencode is required"; PAUSE; return; }
    _conf="$(reconstruct_peer_config "$1" "$2")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; PAUSE; return; }
    echo ""
    echo -e "${V}── QR Code ──${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$_conf" 2>/dev/null || warn "QR generation failed"
    PAUSE
}

show_peer_download() {
    have_cmd base64 || { warn "base64 is required"; PAUSE; return; }
    _conf="$(reconstruct_peer_config "$1" "$2")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; PAUSE; return; }
    _b64="$(printf "%s" "$_conf" | base64 -w 0 2>/dev/null || printf "%s" "$_conf" | base64)"
    echo ""
    echo -e "${A}Download link:${NC}"
    echo "https://immalware.vercel.app/download?filename=awg_$1.conf&content=${_b64}"
    PAUSE
}

show_peer_vpn_key() {
    have_cmd jq     || { warn "jq is required"; PAUSE; return; }
    have_cmd base64 || { warn "base64 is required"; PAUSE; return; }
    _key="$(build_vpn_key "$1" "$2")"
    echo ""
    echo -e "${A}AmneziaVPN key:${NC}"
    echo "$_key"
    PAUSE
}

show_peer_all() {
    _iface="$1"; _idx="$2"
    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; PAUSE; return; }

    echo ""
    echo -e "${V}── Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    echo ""

    if have_cmd jq && have_cmd base64; then
        _key="$(build_vpn_key "$_iface" "$_idx")"
        echo -e "${A}AmneziaVPN key:${NC}"
        echo "$_key"
        echo ""
    fi

    if have_cmd base64; then
        _b64="$(printf "%s" "$_conf" | base64 -w 0 2>/dev/null || printf "%s" "$_conf" | base64)"
        echo -e "${A}Download:${NC}"
        echo "https://immalware.vercel.app/download?filename=awg_${_iface}.conf&content=${_b64}"
        echo ""
    fi

    if have_cmd qrencode; then
        echo -e "${A}QR Code:${NC}"
        qrencode -t ANSIUTF8 "$_conf" 2>/dev/null || true
        echo ""
    fi
    PAUSE
}

do_rename_peer() {
    _iface="$1"; _idx="$2"; _old_desc="$3"
    _pt="amneziawg_${_iface}"

    trap_cancel
    echo ""
    prompt _new_name "New name (Ctrl+C = cancel)" "" || { trap_restore; return 1; }
    trap_restore
    is_cancelled && return 1
    [ -z "${_new_name:-}" ] && { echo -e "${DIM}Cancelled${NC}"; PAUSE; return 1; }
    [ "$_new_name" = "$_old_desc" ] && { echo -e "${DIM}Name unchanged${NC}"; PAUSE; return 1; }

    uci set "network.@${_pt}[$_idx].description=$_new_name"
    uci commit network
    echo -e "${OK}Renamed:${NC} ${_old_desc} -> ${W}${_new_name}${NC}"
    PAUSE
    # Return new name via global
    PEER_NEW_NAME="$_new_name"
    return 0
}

do_regen_peer() {
    _iface="$1"; _idx="$2"; _desc="$3"
    _pt="amneziawg_${_iface}"

    echo ""
    echo -e "${A}This will generate new keys for '${W}${_desc}${A}'.${NC}"
    echo -e "${A}The old config/QR/vpn:// will stop working.${NC}"
    echo ""
    confirm "Regenerate keys?" "n" || return

    _client_priv="$(awg genkey)" || { warn "Key generation failed"; PAUSE; return; }
    _client_pub="$(printf '%s' "$_client_priv" | awg pubkey)" \
        || { warn "Public key derivation failed"; PAUSE; return; }

    uci set "network.@${_pt}[$_idx].private_key=$_client_priv"
    uci set "network.@${_pt}[$_idx].public_key=$_client_pub"
    uci commit network

    echo -e "${B}Restarting${NC} AWG..."
    ifdown "$_iface" >/dev/null 2>&1 || true
    ifup "$_iface" >/dev/null 2>&1 || true

    echo -e "\n${OK}Keys regenerated for '${_desc}'${NC}"
    echo ""

    # Show new config
    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"
    if [ -n "$_conf" ]; then
        echo -e "${V}── New Config ──${NC}"
        echo ""
        echo -e "${W}${_conf}${NC}"
        echo ""

        if have_cmd jq && have_cmd base64; then
            _key="$(build_vpn_key "$_iface" "$_idx")"
            echo -e "${A}AmneziaVPN key:${NC}"
            echo "$_key"
            echo ""
        fi

        if have_cmd qrencode; then
            echo -e "${A}QR Code:${NC}"
            qrencode -t ANSIUTF8 "$_conf" 2>/dev/null || true
            echo ""
        fi
    fi
    PAUSE
}

# ─── Peer sub-menu ────────────────────────────────────────────────

do_peer_menu() {
    _iface="$1"; _idx="$2"; _desc="$3"
    _pt="amneziawg_${_iface}"

    while true; do
        clear
        _aip="$(uci -q get "network.@${_pt}[$_idx].allowed_ips" || echo "?")"
        _pub="$(uci -q get "network.@${_pt}[$_idx].public_key" || true)"
        _peer_disabled="$(uci -q get "network.@${_pt}[$_idx].disabled" || echo "0")"
        [ "$_peer_disabled" != "1" ] && _peer_disabled=0
        _shortpub=""
        [ -n "$_pub" ] && _shortpub="$(printf '%s' "$_pub" | cut -c1-10)..."

        # Live stats from awg show
        _hs=""; _rx=""; _tx=""; _ep=""
        _ka="$(uci -q get "network.@${_pt}[$_idx].persistent_keepalive" || echo "0")"
        _is_online=0

        if [ "$_peer_disabled" -eq 0 ]; then
            _hs="$(get_peer_handshake "$_iface" "$_pub")"
            _rx="$(get_peer_rx "$_iface" "$_pub")"
            _tx="$(get_peer_tx "$_iface" "$_pub")"
            _ep="$(get_peer_endpoint_live "$_iface" "$_pub")"
        fi

        # Status
        if [ "$_peer_disabled" -eq 1 ]; then
            _online="${DIM}Disabled${NC}"
            _hs_display="${DIM}-${NC}"
        else
            _online="${ERR}Offline${NC}"
            _hs_display="${DIM}never${NC}"
            if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                _hs_display="${W}${_hs} ago${NC}"
                _hs_sec="$(awg show "$_iface" 2>/dev/null | awk -v pk="$_pub" '
                    /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                        sub(/.*latest handshake: /,"");
                        t=0;for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                            if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                            else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                        print t;exit}')"
                if [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null; then
                    _online="${OK}Online${NC}"
                    _is_online=1
                fi
            fi
        fi

        echo -e "${A}Interface${NC} ${DIM}·${NC} ${W}${_iface}${NC}"
        echo -e "${A}Selected Peer${NC} ${DIM}·${NC} ${W}${_desc}${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "${A}Status${NC}       ${_online}"
        echo -e "${A}Address${NC}      ${W}${_aip}${NC}"
        if [ "$_is_online" -eq 1 ] && [ -n "$_ep" ]; then
            echo -e "${A}Endpoint${NC}     ${W}${_ep}${NC}"
        fi
        echo ""
        echo -e "${A}Handshake${NC}    ${_hs_display}"
        if [ -n "$_rx" ] || [ -n "$_tx" ]; then
            [ -n "$_rx" ] && echo -e "${A}Rx${NC}           ${W}${_rx}${NC}"
            [ -n "$_tx" ] && echo -e "${A}Tx${NC}           ${W}${_tx}${NC}"
        fi
        echo ""
        if [ -n "$_ka" ] && [ "$_ka" != "0" ]; then
            echo -e "${A}Keepalive${NC}    ${DIM}every ${_ka}s${NC}"
        else
            echo -e "${A}Keepalive${NC}    ${DIM}off${NC}"
        fi
        echo -e "${A}Public Key${NC}   ${DIM}${_shortpub}${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        if [ "$_peer_disabled" -eq 1 ]; then
            _peer_toggle="${OK}Enable${NC} Peer"
        else
            _peer_toggle="${ERR}Disable${NC} Peer"
        fi
        echo -e "${B}1)${NC} ${W}Show${NC} Setup Config"
        echo -e "${B}2)${NC} ${W}Show${NC} Download Link"
        echo -e "${B}3)${NC} ${W}Show${NC} vpn:// Key"
        echo -e "${B}4)${NC} ${W}Show${NC} QR Code"
        echo -e "${B}5)${NC} ${W}Show${NC} All"
        echo ""
        echo -e "${B}6)${NC} ${W}Rename${NC} Peer"
        echo -e "${B}7)${NC} ${ERR}Regenerate${NC} Keys"
        echo -e "${B}8)${NC} ${_peer_toggle}"
        echo -e "${B}9)${NC} ${ERR}Delete${NC} Peer"
        echo ""
        echo -e "${DIM}Enter) Back${NC}"
        echo ""

        echo -ne "${A}Select:${NC} " && read _peer_choice

        case "${_peer_choice:-}" in
            1) show_peer_conf "$_iface" "$_idx" ;;
            2) show_peer_download "$_iface" "$_idx" ;;
            3) show_peer_vpn_key "$_iface" "$_idx" ;;
            4) show_peer_qr "$_iface" "$_idx" ;;
            5) show_peer_all "$_iface" "$_idx" ;;
            6)  PEER_NEW_NAME=""
                if do_rename_peer "$_iface" "$_idx" "$_desc"; then
                    _desc="$PEER_NEW_NAME"
                fi ;;
            7) do_regen_peer "$_iface" "$_idx" "$_desc" ;;
            8)  if [ "$_peer_disabled" -eq 1 ]; then
                    uci delete "network.@${_pt}[$_idx].disabled" 2>/dev/null || true
                    uci commit network
                    echo -e "${B}Restarting${NC} AWG..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    ifup "$_iface" >/dev/null 2>&1 || true
                    echo -e "${OK}Peer '${_desc}' enabled${NC}"
                else
                    uci set "network.@${_pt}[$_idx].disabled=1"
                    uci commit network
                    echo -e "${B}Restarting${NC} AWG..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    ifup "$_iface" >/dev/null 2>&1 || true
                    echo -e "${OK}Peer '${_desc}' disabled${NC}"
                fi
                PAUSE ;;
            9)  confirm "Delete peer '${_desc}'?" "n" || continue
                uci delete "network.@${_pt}[$_idx]"
                uci commit network
                echo -e "${B}Restarting${NC} AWG..."
                ifdown "$_iface" >/dev/null 2>&1 || true
                ifup "$_iface" >/dev/null 2>&1 || true
                echo -e "\n${OK}Peer '${_desc}' deleted${NC}"
                PAUSE
                return ;;
            "") return ;;
            *) ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════
#  PEER MANAGEMENT
# ═════════════════════════════════════════════════════════════════════

do_list_peers() {
    _iface="$1"
    _pt="amneziawg_${_iface}"

    echo ""
    echo -e "${V}Peers  ${DIM}─  ${W}${_iface}${NC}"
    echo ""

    _pi=0; _found=0
    while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
        _found=1; _n=$((_pi + 1))
        _desc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "(unnamed)")"
        _aip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "?")"
        _pub="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"

        _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"
        if [ "$_pdis" = "1" ]; then
            echo -e "${B}${_n})${NC} ${DIM}${_desc}${NC} ${DIM}· Disabled (${_aip})${NC}"
        else
            _hs="$(get_peer_handshake "$_iface" "$_pub")"
            if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                _hs_sec="$(awg show "$_iface" 2>/dev/null | awk -v pk="$_pub" '
                    /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                        sub(/.*latest handshake: /,"");t=0;
                        for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                            if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                            else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                        print t;exit}' 2>/dev/null)"
                if [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null; then
                    echo -e "${B}${_n})${NC} ${W}${_desc}${NC} ${DIM}·${NC} ${OK}Online${NC} ${DIM}(${_aip})${NC}"
                else
                    echo -e "${B}${_n})${NC} ${W}${_desc}${NC} ${DIM}·${NC} ${ERR}Offline${NC} ${DIM}(Last seen ${_hs} ago) / (${_aip})${NC}"
                fi
            else
                echo -e "${B}${_n})${NC} ${W}${_desc}${NC} ${DIM}·${NC} ${ERR}Offline${NC} ${DIM}(${_aip})${NC}"
            fi
        fi
        _pi=$((_pi + 1))
    done

    if [ "$_found" -eq 0 ]; then
        echo -e "${DIM}No peers yet. Use 'Add Peer' to create one.${NC}"
        PAUSE
        return
    fi

    echo -e "${B}0)${NC} ${DIM}Back${NC}"
    echo ""
    echo -ne "${A}Select peer:${NC} " && read _peer_sel
    [ "${_peer_sel:-0}" = "0" ] && return

    _sel_idx=$((_peer_sel - 1))
    _sel_desc="$(uci -q get "network.@${_pt}[$_sel_idx].description" 2>/dev/null || true)"
    if [ -z "$_sel_desc" ]; then
        warn "Invalid selection"
        PAUSE
        return
    fi

    do_peer_menu "$_iface" "$_sel_idx" "$_sel_desc"
}

do_add_peer() {
    _iface="$1"
    _pt="amneziawg_${_iface}"

    have_cmd jq     || { warn "jq is required for Amnezia config"; PAUSE; return; }
    have_cmd base64 || { warn "base64 is required for VPN key"; PAUSE; return; }

    trap_cancel
    echo ""
    echo -e "${DIM}(Ctrl+C = cancel)${NC}"
    echo ""
    while true; do
        prompt PEER_NAME "Peer name" "" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        [ -z "${PEER_NAME:-}" ] && continue
        _dup="$(uci -q show network 2>/dev/null \
            | grep "\.description='${PEER_NAME}'" | head -n1 || true)"
        [ -n "$_dup" ] && { warn "Peer '${PEER_NAME}' already exists"; continue; }
        break
    done
    trap_restore

    # Get interface params
    _addr="$(uci -q get "network.${_iface}.addresses" || true)"
    [ -z "$_addr" ] && { die "Cannot read interface address for $_iface"; }
    _prefix="$(get_ip_prefix "$_addr")"

    _peer_ip="$(pick_free_ip "$_iface" "$_prefix")"
    echo -e "${OK}Assigned IP:${NC} $_peer_ip"

    # Endpoint (WAN IP auto-detect)
    _endpoint_host="$(detect_wan_ip || true)"
    if [ -z "$_endpoint_host" ]; then
        prompt _endpoint_host "Could not detect WAN IP — enter manually" ""
    else
        echo -e "${OK}WAN IP (endpoint):${NC} $_endpoint_host"
        if ! confirm "Use this address?" "y"; then
            prompt _endpoint_host "Enter endpoint address" "$_endpoint_host"
        fi
    fi

    _port="$(uci -q get "network.${_iface}.listen_port" || echo "51820")"

    # DNS from interface
    _dns="$(uci -q get "network.${_iface}.dns" || true)"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "1.1.1.1")"
    echo -e "${OK}DNS:${NC} $_dns"

    _keepalive="25"

    # Generate keys
    _client_priv="$(awg genkey)" || die "Key generation failed"
    _client_pub="$(printf '%s' "$_client_priv" | awg pubkey)" \
        || die "Public key derivation failed"

    _server_priv="$(uci -q get "network.${_iface}.private_key" || true)"
    [ -z "$_server_priv" ] && die "Missing interface private key"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey)"

    echo ""
    echo -e "${V}New peer:${NC}"
    echo -e "${A}Name${NC}         ${W}$PEER_NAME${NC}"
    echo -e "${A}IP${NC}           ${W}$_peer_ip${NC}"
    echo -e "${A}Endpoint${NC}     ${W}${_endpoint_host}:${_port}${NC}"
    echo -e "${A}DNS${NC}          ${W}$_dns${NC}"
    echo ""

    confirm "Create peer?" "y" || return

    echo -e "${B}Adding${NC} peer ${W}$PEER_NAME${NC}..."
    _sec="$(uci add network "$_pt")"
    uci set "network.${_sec}.public_key=$_client_pub"
    uci set "network.${_sec}.private_key=$_client_priv"
    uci set "network.${_sec}.route_allowed_ips=1"
    uci set "network.${_sec}.allowed_ips=$_peer_ip"
    uci set "network.${_sec}.persistent_keepalive=$_keepalive"
    uci set "network.${_sec}.description=$PEER_NAME"

    uci commit network

    # Build client config
    _conf="[Interface]
PrivateKey = $_client_priv
Address = $_peer_ip
DNS = $_dns

[Peer]
PublicKey = $_server_pub
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${_endpoint_host}:${_port}
PersistentKeepAlive = $_keepalive"

    emit_peer_config "$_iface" "$_client_priv" "$_peer_ip" "" \
        "$_server_pub" "$_conf" "$_endpoint_host" "$_port"

    PAUSE

    echo -e "${B}Restarting${NC} AWG..."
    ifdown "$_iface" >/dev/null 2>&1 || true
    ifup "$_iface" >/dev/null 2>&1 || true
    echo -e "${OK}Done${NC}"
}

do_manage_interface() {
    _iface="$1"
    while true; do
        clear
        # Check if interface still exists (could have been deleted)
        uci_network_exists "$_iface" || return

        _addr="$(uci -q get "network.${_iface}.addresses" || echo "n/a")"
        _port="$(uci -q get "network.${_iface}.listen_port" || echo "n/a")"
        _dns="$(uci  -q get "network.${_iface}.dns" || echo "n/a")"
        _zone="$(find_zone_for_interface "$_iface" 2>/dev/null || echo "none")"
        _peer_count="$(count_peers "$_iface")"

        _disabled="$(uci -q get "network.${_iface}.disabled" || echo "0")"

        echo -e "${A}Interface${NC} ${DIM}·${NC} ${W}${_iface}${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        _fwd_lan="${DIM}No${NC}"; forwarding_exists "$_zone" "lan" && _fwd_lan="${OK}Yes${NC}"
        _fwd_wan="${DIM}No${NC}"; forwarding_exists "$_zone" "wan" && _fwd_wan="${OK}Yes${NC}"

        echo -e "${A}Address${NC}      ${W}${_addr}${NC}"
        echo -e "${A}Port${NC}         ${W}${_port}${NC}"
        echo -e "${A}DNS${NC}          ${W}${_dns}${NC}"
        echo ""
        echo -e "${A}FW Zone${NC}      ${W}${_zone}${NC}"
        echo -e "${A}-> LAN${NC}       ${_fwd_lan}"
        echo -e "${A}-> WAN${NC}       ${_fwd_wan}"
        echo ""
        echo -e "${A}Peers${NC}        ${W}${_peer_count}${NC}"
        if [ "$_disabled" = "1" ]; then
            echo -e "${A}Status${NC}       ${ERR}Disabled${NC}"
        elif ! interface_device_exists "$_iface"; then
            echo -e "${A}Status${NC}       ${ERR}Down${NC}"
        else
            if [ "$_peer_count" -gt 0 ] 2>/dev/null; then
                _active_names="$(active_peer_names "$_iface")"
                if [ -n "$_active_names" ]; then
                    echo -e "${A}Active${NC}       ${OK}${_active_names}${NC}"
                fi
            fi
        fi
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        if [ "$_disabled" = "1" ]; then
            _toggle_label="${OK}Enable${NC} Interface"
        else
            _toggle_label="${ERR}Disable${NC} Interface"
        fi
        _is_l="$(uci -q get "network.${_iface}._is_liminal" || echo "0")"

        echo -e "${B}1)${NC} ${W}Add${NC} Peer"
        echo -e "${B}2)${NC} ${W}List${NC} Peers"
        echo -e "${B}3)${NC} ${W}Restart${NC} Interface"
        echo ""
        echo -e "${B}4)${NC} ${_toggle_label}"
        if [ "$_is_l" = "1" ]; then
            echo -e "${B}5)${NC} ${ERR}Delete${NC} Interface"
        fi
        echo ""
        echo -e "${DIM}Enter) Back${NC}"
        echo ""

        echo -ne "${A}Select:${NC} " && read _mgmt_choice

        case "${_mgmt_choice:-}" in
            1) do_add_peer "$_iface" ;;
            2) do_list_peers "$_iface" ;;
            3)  echo -e "${B}Restarting${NC} ${W}${_iface}${NC}..."
                ifdown "$_iface" >/dev/null 2>&1 || true
                ifup "$_iface" >/dev/null 2>&1 || true
                echo -e "${OK}Done${NC}"
                PAUSE ;;
            4)  if [ "$_disabled" = "1" ]; then
                    uci delete "network.${_iface}.disabled" 2>/dev/null || true
                    uci commit network
                    echo -e "${B}Enabling${NC} ${W}${_iface}${NC}..."
                    ifup "$_iface" >/dev/null 2>&1 || true
                    echo -e "${OK}Interface enabled${NC}"
                else
                    uci set "network.${_iface}.disabled=1"
                    uci commit network
                    echo -e "${B}Disabling${NC} ${W}${_iface}${NC}..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    echo -e "${OK}Interface disabled${NC}"
                fi
                PAUSE ;;
            5)  if [ "$_is_l" = "1" ]; then do_delete_interface "$_iface" && return; fi ;;
            "") return ;;
            *) ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════
#  1) LIST / MANAGE INTERFACES
# ═════════════════════════════════════════════════════════════════════

do_list() {
    _liminal="$(get_awg_interfaces)"
    _all="$(get_all_awg_interfaces)"

    # Find non-liminal interfaces
    _other=""
    for iface in $_all; do
        _is_l="$(uci -q get "network.${iface}._is_liminal" || echo "0")"
        [ "$_is_l" = "1" ] || _other="${_other} ${iface}"
    done
    _other="${_other# }"

    if [ -z "$_liminal" ] && [ -z "$_other" ]; then
        echo -e "${DIM}No interfaces found${NC}"
        PAUSE
        return
    fi

    # Auto-jump if only one liminal interface and no others
    if [ -z "$_other" ]; then
        _iface_count=0; _single=""
        for iface in $_liminal; do
            _iface_count=$((_iface_count + 1))
            _single="$iface"
        done
        if [ "$_iface_count" -eq 1 ]; then
            do_manage_interface "$_single"
            return
        fi
    fi

    clear
    echo -e "${W}Interfaces${NC}"
    echo ""
    echo -e "${DIM}──────────────────────────────────────${NC}"
    echo ""

    # Combined list for selection: liminal first, then other
    _all_list=""
    _n=0

    if [ -n "$_liminal" ]; then
        for iface in $_liminal; do
            _n=$((_n + 1))
            _all_list="${_all_list} ${iface}"
            _peer_count="$(count_peers "$iface")"
            if interface_device_exists "$iface"; then
                _active_count="$(count_active_peers "$iface")"
                echo -e "${B}${_n})${NC} ${W}${iface}${NC}  ${DIM}·${NC}  Active: ${OK}${_active_count}${NC} of ${_peer_count}"
            else
                echo -e "${B}${_n})${NC} ${W}${iface}${NC}  ${DIM}·${NC}  Peers: ${_peer_count}  ${DIM}·${NC}  ${ERR}Down${NC}"
            fi
        done
    fi

    if [ -n "$_other" ]; then
        echo ""
        echo -e "${DIM}Non-Liminal Interfaces${NC}"
        echo ""
        for iface in $_other; do
            _n=$((_n + 1))
            _all_list="${_all_list} ${iface}"
            _peer_count="$(count_peers "$iface")"
            if interface_device_exists "$iface"; then
                _active_count="$(count_active_peers "$iface")"
                echo -e "${B}${_n})${NC} ${DIM}${iface}${NC}  ${DIM}·${NC}  Active: ${OK}${_active_count}${NC} of ${_peer_count}"
            else
                echo -e "${B}${_n})${NC} ${DIM}${iface}${NC}  ${DIM}·${NC}  Peers: ${_peer_count}  ${DIM}·${NC}  ${ERR}Down${NC}"
            fi
        done
    fi

    echo ""
    echo -e "${B}0)${NC} ${DIM}Back${NC}"
    echo ""
    echo -ne "${A}Select interface:${NC} " && read LIST_CHOICE

    [ "${LIST_CHOICE:-0}" = "0" ] && return

    _n=0; _sel_iface=""
    for iface in $_all_list; do
        _n=$((_n + 1))
        [ "$_n" = "$LIST_CHOICE" ] && { _sel_iface="$iface"; break; }
    done

    if [ -z "$_sel_iface" ]; then
        warn "Invalid selection"
        PAUSE
        return
    fi

    do_manage_interface "$_sel_iface"
}

# ═════════════════════════════════════════════════════════════════════
#  DELETE INTERFACE (called from inside interface management)
# ═════════════════════════════════════════════════════════════════════

do_delete_interface() {
    DEL_IFACE="$1"

    DEL_PORT="$(uci -q get "network.${DEL_IFACE}.listen_port" || true)"
    DEL_ZONE="$(find_zone_for_interface "$DEL_IFACE" 2>/dev/null || true)"

    echo ""
    echo -e "${A}Will be removed:${NC}"
    echo -e "${ERR}-${NC} Interface        ${W}$DEL_IFACE${NC}"
    echo -e "${ERR}-${NC} All peers        ${W}$DEL_IFACE${NC}"
    [ -n "$DEL_ZONE" ] && \
    echo -e "${ERR}-${NC} FW Zone          ${W}$DEL_ZONE${NC}  (+ forwarding)"
    [ -n "$DEL_PORT" ] && \
    echo -e "${ERR}-${NC} FW Rules         port ${W}$DEL_PORT${NC}/udp"
    if podkop_present && podkop_has_interface "$DEL_IFACE" 2>/dev/null; then
        echo -e "${ERR}-${NC} Podkop           ${W}$DEL_IFACE${NC}"
    fi
    echo ""

    confirm "Proceed with deletion?" "n" || return 1

    init_backup "Pre-Interface Delete"

    # ── Delete peers ──
    while uci -q get "network.@amneziawg_${DEL_IFACE}[0]" >/dev/null 2>&1; do
        uci delete "network.@amneziawg_${DEL_IFACE}[0]"
    done

    # ── Delete network interface ──
    echo -e "${B}Removing${NC} interface ${W}$DEL_IFACE${NC}"
    uci delete "network.${DEL_IFACE}"

    # ── Delete forwardings (reverse order, only _is_liminal) ──
    if [ -n "$DEL_ZONE" ]; then
        _cnt=0
        while uci -q get "firewall.@forwarding[$_cnt]" >/dev/null 2>&1; do
            _cnt=$((_cnt + 1))
        done
        _fi=$((_cnt - 1))
        while [ "$_fi" -ge 0 ]; do
            _fl="$(uci -q get "firewall.@forwarding[$_fi]._is_liminal" || echo "0")"
            _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src"  || true)"
            _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" || true)"
            if [ "$_fl" = "1" ] && { [ "$_fsrc" = "$DEL_ZONE" ] || [ "$_fdst" = "$DEL_ZONE" ]; }; then
                echo -e "${B}Removing${NC} forwarding: ${_fsrc} -> ${_fdst}"
                uci delete "firewall.@forwarding[$_fi]"
            fi
            _fi=$((_fi - 1))
        done

        # Delete zone only if _is_liminal
        _zi="$(find_zone_index "$DEL_ZONE" || true)"
        if [ -n "$_zi" ]; then
            _zl="$(uci -q get "firewall.@zone[$_zi]._is_liminal" || echo "0")"
            if [ "$_zl" = "1" ]; then
                echo -e "${B}Removing${NC} FW zone ${W}$DEL_ZONE${NC}"
                uci delete "firewall.@zone[$_zi]"
            fi
        fi
    fi

    # ── Delete firewall rules (reverse order, only _is_liminal) ──
    if [ -n "$DEL_PORT" ]; then
        _cnt=0
        while uci -q get "firewall.@rule[$_cnt]" >/dev/null 2>&1; do
            _cnt=$((_cnt + 1))
        done
        _ri=$((_cnt - 1))
        while [ "$_ri" -ge 0 ]; do
            _rl="$(uci -q get "firewall.@rule[$_ri]._is_liminal" || echo "0")"
            _rport="$(uci -q get "firewall.@rule[$_ri].dest_port" || true)"
            if [ "$_rl" = "1" ] && [ "$_rport" = "$DEL_PORT" ]; then
                _rname="$(uci -q get "firewall.@rule[$_ri].name" || echo "unnamed")"
                echo -e "${B}Removing${NC} FW rule ${W}${_rname}${NC} (port ${DEL_PORT})"
                uci delete "firewall.@rule[$_ri]"
            fi
            _ri=$((_ri - 1))
        done
    fi

    # ── Remove from Podkop ──
    if podkop_present && podkop_has_interface "$DEL_IFACE" 2>/dev/null; then
        echo -e "${B}Removing${NC} ${W}$DEL_IFACE${NC} from Podkop"
        remove_podkop_interface "$DEL_IFACE"
    fi

    # ── Commit & reload ──
    echo -e "${B}Committing${NC} config..."
    uci commit network
    uci commit firewall

    echo -e "${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload
    /etc/init.d/firewall restart 2>/dev/null
    if podkop_present && [ -x /etc/init.d/podkop ]; then
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
    fi

    echo -e "\n${OK}Interface '${DEL_IFACE}' deleted${NC}"
    echo -e "${A}Backups:${NC} $BACKUP_DIR"
    PAUSE
    return 0
}

# ═════════════════════════════════════════════════════════════════════
#  3) CREATE INTERFACE
# ═════════════════════════════════════════════════════════════════════

do_create() {
    trap_cancel
    clear
    echo -e "${W}Create Interface${NC}"
    echo ""
    echo -e "${DIM}──────────────────────────────────────${NC}"
    echo ""

    echo -e "\033[38;5;214mNOTE: A static public IP address (or a DDNS hostname) and${NC}"
    echo -e "\033[38;5;214mNAT port forwarding (UDP) on your upstream router are${NC}"
    echo -e "\033[38;5;214mrequired for external clients to connect to this tunnel.${NC}"
    echo ""
    echo -e "${DIM}(Ctrl+C = cancel)${NC}"
    echo ""

    # ── Interface name ──
    while true; do
        prompt IFNAME "Interface name" "awg0" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        validate_ifname "$IFNAME" || continue
        uci_network_exists "$IFNAME"      && { warn "Interface '$IFNAME' already exists"; continue; }
        interface_device_exists "$IFNAME"  && { warn "Device '$IFNAME' already exists"; continue; }
        break
    done

    # ── Address ──
    while true; do
        prompt IFADDR "Interface address with CIDR (e.g. 10.10.10.1/24)" "" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        [ -z "$IFADDR" ] && { warn "Required field"; continue; }
        validate_cidr_ipv4 "$IFADDR" && break
    done
    IF_IP="${IFADDR%/*}"
    IF_SUBNET="$(network_base_from_cidr "$IFADDR")"

    # ── Port ──
    while true; do
        prompt PORT "Listen port" "51820" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        validate_port "$PORT" || continue
        port_in_use "$PORT" && { warn "Port $PORT is already in use"; continue; }
        FW_MATCH="$(firewall_port_in_use "$PORT" || true)"
        [ -n "$FW_MATCH" ] && { warn "Port $PORT is used by FW rule '$FW_MATCH'"; continue; }
        break
    done

    # ── Router LAN IP (auto-detect) ──
    ROUTER_LAN_IP="$(detect_router_lan_ip || true)"
    if [ -z "$ROUTER_LAN_IP" ]; then
        while true; do
            prompt ROUTER_LAN_IP "Could not detect router LAN IP — enter manually" "" || { trap_restore; return; }
            is_cancelled && { trap_restore; return; }
            [ -z "$ROUTER_LAN_IP" ] && { warn "Required field"; continue; }
            validate_ipv4 "$ROUTER_LAN_IP" && break
        done
    else
        echo -e "${OK}Detected LAN IP:${NC} $ROUTER_LAN_IP"
        if ! confirm "Use this address?" "y"; then
            while true; do
                prompt ROUTER_LAN_IP "Enter router LAN IP" "$ROUTER_LAN_IP" || { trap_restore; return; }
                is_cancelled && { trap_restore; return; }
                validate_ipv4 "$ROUTER_LAN_IP" && break
            done
        fi
    fi

    if cidr_contains_ip "$IF_SUBNET" "$ROUTER_LAN_IP"; then
        warn "AWG subnet '$IF_SUBNET' overlaps with router LAN IP '$ROUTER_LAN_IP'"
        PAUSE; return
    fi

    # ── Firewall zone (auto-name) ──
    ZONE_NAME="$(generate_zone_name "$IFNAME")"
    echo -e "${OK}Auto FW zone:${NC} $ZONE_NAME"
    if ! confirm "Use this name?" "y"; then
        while true; do
            prompt ZONE_NAME "Enter FW zone name" "$ZONE_NAME" || { trap_restore; return; }
            is_cancelled && { trap_restore; return; }
            validate_zone_name "$ZONE_NAME" || continue
            zone_exists "$ZONE_NAME" && { warn "FW zone '$ZONE_NAME' already exists"; continue; }
            break
        done
    fi

    # ── LAN / WAN zones ──
    _zones="$(list_zones)"
    echo ""
    echo -e "${A}Available firewall zones:${NC}"
    _zi=0
    for _z in $_zones; do
        _zi=$((_zi + 1))
        echo -e "  ${B}${_zi})${NC} ${W}${_z}${NC}"
    done
    echo ""

    while true; do
        prompt _lan_pick "Select LAN zone number" "" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        [ -z "$_lan_pick" ] && { warn "Required field"; continue; }
        _zn=0; LAN_ZONE=""
        for _z in $_zones; do
            _zn=$((_zn + 1))
            [ "$_zn" = "$_lan_pick" ] && { LAN_ZONE="$_z"; break; }
        done
        [ -z "$LAN_ZONE" ] && { warn "Invalid selection"; continue; }
        break
    done
    echo -e "${OK}LAN zone:${NC} $LAN_ZONE"

    while true; do
        prompt _wan_pick "Select WAN zone number" "" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        [ -z "$_wan_pick" ] && { warn "Required field"; continue; }
        _zn=0; WAN_ZONE=""
        for _z in $_zones; do
            _zn=$((_zn + 1))
            [ "$_zn" = "$_wan_pick" ] && { WAN_ZONE="$_z"; break; }
        done
        [ -z "$WAN_ZONE" ] && { warn "Invalid selection"; continue; }
        [ "$WAN_ZONE" = "$LAN_ZONE" ] && { warn "WAN zone cannot be same as LAN zone"; continue; }
        break
    done
    echo -e "${OK}WAN zone:${NC} $WAN_ZONE"

    # ── Forwarding ──
    ALLOW_LAN_FORWARD="0"; ALLOW_WAN_FORWARD="0"
    confirm "Allow routing to LAN?" "y" && ALLOW_LAN_FORWARD="1"
    confirm "Allow routing to WAN?" "y" && ALLOW_WAN_FORWARD="1"
    if [ "$ALLOW_LAN_FORWARD" = "0" ] && [ "$ALLOW_WAN_FORWARD" = "0" ]; then
        warn "At least one routing direction (LAN or WAN) required"
        PAUSE; return
    fi

    # ── Firewall rule name (auto-name) ──
    INCOMING_RULE_NAME="$(generate_rule_name "$IFNAME")"
    echo -e "${OK}Auto FW rule:${NC} $INCOMING_RULE_NAME"

    # ── MTU ──
    while true; do
        prompt MTU_VALUE "MTU" "1380" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        case "$MTU_VALUE" in *[!0-9]*) warn "MTU must be numeric"; continue ;; esac
        [ "$MTU_VALUE" -ge 1200 ] 2>/dev/null || warn "MTU below 1200 is unusual"
        [ "$MTU_VALUE" -le 1500 ] 2>/dev/null || { warn "MTU above 1500 is invalid"; continue; }
        break
    done

    # ── Podkop / DNS ──
    USE_PODKOP="0"; DNS_IP=""
    if podkop_present; then
        echo -e "${OK}Podkop found${NC}"
        if confirm "Configure Podkop-aware routing?" "y"; then
            USE_PODKOP="1"
            DNS_IP="$ROUTER_LAN_IP"
            echo -e "Client DNS set to LAN IP: ${OK}$DNS_IP${NC}"
        fi
    fi
    if [ "$USE_PODKOP" != "1" ]; then
        while true; do
            prompt DNS_IP "Client DNS server (IPv4)" "" || { trap_restore; return; }
            is_cancelled && { trap_restore; return; }
            [ -z "$DNS_IP" ] && { warn "Required field"; continue; }
            validate_ipv4 "$DNS_IP" && break
        done
    fi

    check_dangerous_forwarding "$ZONE_NAME"

    # ── Key generation ──
    echo ""
    echo -e "${B}Generating${NC} keys..."
    KEYS="$(generate_awg_keys)"
    SERVER_PRIVKEY="$(printf '%s\n' "$KEYS" | sed -n '1p')"
    SERVER_PUBKEY="$(printf  '%s\n' "$KEYS" | sed -n '2p')"

    # ── Confirmation ──
    echo ""
    echo -e "${V}Planned config:${NC}"
    echo -e "${A}Interface${NC}    ${W}$IFNAME${NC}"
    echo -e "${A}Address${NC}      ${W}$IFADDR${NC}"
    echo -e "${A}Subnet${NC}       ${W}$IF_SUBNET${NC}"
    echo -e "${A}Port${NC}         ${W}$PORT${NC}"
    echo -e "${A}MTU${NC}          ${W}$MTU_VALUE${NC}"
    echo -e "${A}LAN IP${NC}       ${W}$ROUTER_LAN_IP${NC}"
    echo -e "${A}DNS${NC}          ${W}$DNS_IP${NC}"
    echo -e "${A}FW Zone${NC}      ${W}$ZONE_NAME${NC}"
    echo -e "${A}FW Rule${NC}      ${W}$INCOMING_RULE_NAME${NC}"
    echo -e "${A}-> LAN${NC}       $( [ "$ALLOW_LAN_FORWARD" = "1" ] && echo -e "${OK}yes${NC}" || echo -e "${DIM}no${NC}" )"
    echo -e "${A}-> WAN${NC}       $( [ "$ALLOW_WAN_FORWARD" = "1" ] && echo -e "${OK}yes${NC}" || echo -e "${DIM}no${NC}" )"
    echo -e "${A}Podkop${NC}       $( [ "$USE_PODKOP" = "1" ] && echo -e "${OK}yes${NC}" || echo -e "${DIM}no${NC}" )"
    echo ""

    trap_restore
    confirm "Apply configuration?" "y" || { log "Cancelled."; return; }

    autobackup_enabled && init_backup "Pre-Interface Create"

    # ── Apply: network ──
    echo -e "${B}Creating${NC} interface..."
    uci set "network.${IFNAME}=interface"
    uci set "network.${IFNAME}.proto=amneziawg"
    uci set "network.${IFNAME}._is_liminal=1"
    uci set "network.${IFNAME}.private_key=${SERVER_PRIVKEY}"
    uci set "network.${IFNAME}.listen_port=${PORT}"
    uci add_list "network.${IFNAME}.addresses=${IFADDR}"
    uci set "network.${IFNAME}.mtu=${MTU_VALUE}"
    uci set "network.${IFNAME}.dns=${DNS_IP}"

    # ── Apply: firewall zone ──
    echo -e "${B}Creating${NC} FW zone ${W}$ZONE_NAME${NC}"
    uci add firewall zone >/dev/null
    ZONE_IDX="$(uci show firewall \
        | sed -n 's/^firewall\.@zone\[\([0-9]\+\)\]=zone$/\1/p' | tail -n1)"
    uci set "firewall.@zone[$ZONE_IDX].name=${ZONE_NAME}"
    uci set "firewall.@zone[$ZONE_IDX].input=ACCEPT"
    uci set "firewall.@zone[$ZONE_IDX].output=ACCEPT"
    uci set "firewall.@zone[$ZONE_IDX].forward=ACCEPT"
    uci add_list "firewall.@zone[$ZONE_IDX].network=${IFNAME}"
    uci set "firewall.@zone[$ZONE_IDX]._is_liminal=1"

    # ── Apply: forwardings ──
    if [ "$ALLOW_LAN_FORWARD" = "1" ] && ! forwarding_exists "$ZONE_NAME" "$LAN_ZONE"; then
        echo -e "${B}Creating${NC} forwarding: ${W}${ZONE_NAME}${NC} -> ${W}${LAN_ZONE}${NC}"
        uci add firewall forwarding >/dev/null
        FWD_IDX="$(uci show firewall \
            | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1)"
        uci set "firewall.@forwarding[$FWD_IDX].src=${ZONE_NAME}"
        uci set "firewall.@forwarding[$FWD_IDX].dest=${LAN_ZONE}"
        uci set "firewall.@forwarding[$FWD_IDX]._is_liminal=1"
    fi

    if [ "$ALLOW_WAN_FORWARD" = "1" ]; then
        if ! forwarding_exists "$ZONE_NAME" "$WAN_ZONE"; then
            echo -e "${B}Creating${NC} forwarding: ${W}${ZONE_NAME}${NC} -> ${W}${WAN_ZONE}${NC}"
            uci add firewall forwarding >/dev/null
            FWD_IDX="$(uci show firewall \
                | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1)"
            uci set "firewall.@forwarding[$FWD_IDX].src=${ZONE_NAME}"
            uci set "firewall.@forwarding[$FWD_IDX].dest=${WAN_ZONE}"
            uci set "firewall.@forwarding[$FWD_IDX]._is_liminal=1"
        fi
        ensure_wan_masq
    fi

    # ── Apply: incoming WAN rule ──
    if ! rule_exists_by_name "$INCOMING_RULE_NAME"; then
        echo -e "${B}Creating${NC} FW rule ${W}$INCOMING_RULE_NAME${NC}"
        uci add firewall rule >/dev/null
        RULE_IDX="$(uci show firewall \
            | sed -n 's/^firewall\.@rule\[\([0-9]\+\)\]=rule$/\1/p' | tail -n1)"
        uci set "firewall.@rule[$RULE_IDX].name=${INCOMING_RULE_NAME}"
        uci set "firewall.@rule[$RULE_IDX].src=${WAN_ZONE}"
        uci set "firewall.@rule[$RULE_IDX].proto=udp"
        uci set "firewall.@rule[$RULE_IDX].dest_port=${PORT}"
        uci set "firewall.@rule[$RULE_IDX].target=ACCEPT"
        uci set "firewall.@rule[$RULE_IDX]._is_liminal=1"
    else
        warn "Rule '$INCOMING_RULE_NAME' already exists — skipping"
    fi

    # ── Commit & reload ──
    echo -e "${B}Committing${NC} config..."
    uci commit network
    uci commit firewall

    echo -e "${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload
    /etc/init.d/firewall restart 2>/dev/null

    # ── Podkop integration ──
    if [ "$USE_PODKOP" = "1" ]; then
        if confirm "Add '$IFNAME' to Podkop source interfaces?" "y"; then
            add_podkop_interface "$IFNAME"
            if [ -x /etc/init.d/podkop ]; then
                echo -e "${B}Restarting${NC} Podkop..."
                /etc/init.d/podkop restart >/dev/null 2>&1 || warn "Podkop restart failed"
            fi
        fi
    fi

    # ── Summary ──
    echo ""
    echo -e "${OK}Interface created successfully${NC}"
    echo ""
    echo -e "${A}Interface${NC}    ${W}$IFNAME${NC}"
    echo -e "${A}Address${NC}      ${W}$IFADDR${NC}"
    echo -e "${A}Port${NC}         ${W}$PORT${NC}"
    echo -e "${A}DNS${NC}          ${W}$DNS_IP${NC}"
    echo -e "${A}FW Zone${NC}      ${W}$ZONE_NAME${NC}"
    echo -e "${A}FW Rule${NC}      ${W}$INCOMING_RULE_NAME${NC}"
    echo -e "${A}Public Key${NC}   ${DIM}$SERVER_PUBKEY${NC}"
    echo -e "${A}Backups${NC}      ${DIM}$BACKUP_DIR${NC}"
    echo ""
    echo -e "${DIM}Verify:  awg show  |  ifstatus $IFNAME${NC}"
    PAUSE
}

# ═════════════════════════════════════════════════════════════════════
#  BACKUP MANAGEMENT
# ═════════════════════════════════════════════════════════════════════

do_backup_menu() {
    _bdir="$1"
    _bname="$(basename "$_bdir")"
    _reason="$(cat "$_bdir/.reason" 2>/dev/null || echo "Unknown")"
    _date="$(cat "$_bdir/.date" 2>/dev/null || echo "$_bname")"

    while true; do
        clear
        echo -e "${W}Backup${NC} ${DIM}·${NC} ${W}${_bname}${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "${A}Date${NC}         ${W}${_date}${NC}"
        echo -e "${A}Reason${NC}       ${W}${_reason}${NC}"
        echo -e "${A}Path${NC}         ${DIM}${_bdir}${NC}"
        echo ""

        _has_net=""; _has_fw=""; _has_pk=""
        [ -f "$_bdir/network.bak" ] && _has_net="${OK}yes${NC}" || _has_net="${DIM}no${NC}"
        [ -f "$_bdir/firewall.bak" ] && _has_fw="${OK}yes${NC}" || _has_fw="${DIM}no${NC}"
        [ -f "$_bdir/podkop.bak" ] && _has_pk="${OK}yes${NC}" || _has_pk="${DIM}no${NC}"
        echo -e "${A}Network${NC}      ${_has_net}"
        echo -e "${A}Firewall${NC}     ${_has_fw}"
        echo -e "${A}Podkop${NC}       ${_has_pk}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "${B}1)${NC} ${W}Restore${NC} From This Backup"
        echo -e "${B}2)${NC} ${ERR}Delete${NC} Backup"
        echo ""
        echo -e "${DIM}Enter) Back${NC}"
        echo ""

        echo -ne "${A}Select:${NC} " && read _bchoice

        case "${_bchoice:-}" in
            1)  confirm "Restore from backup '${_reason}' (${_date})?" "n" || continue
                BACKUP_DIR="$_bdir"
                restore_backups
                echo -e "\n${OK}Restored from backup${NC}"
                PAUSE
                return ;;
            2)  confirm "Delete this backup?" "n" || continue
                rm -rf "$_bdir"
                echo -e "${OK}Backup deleted${NC}"
                PAUSE
                return ;;
            "") return ;;
            *) ;;
        esac
    done
}

do_manage_backups() {
    while true; do
        clear
        if autobackup_enabled; then
            _ab_status="${OK}Enabled${NC}"
        else
            _ab_status="${DIM}Disabled${NC}"
        fi
        echo -e "${W}Manage Backups${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "${A}Auto-Backup${NC}  ${_ab_status}"
        echo ""

        mkdir -p "$BACKUP_BASE"
        _sorted="$(ls -1dr "$BACKUP_BASE"/*/ 2>/dev/null | sed 's:/$::' || true)"
        _dirs=""
        _n=0
        for d in $_sorted; do
            [ -d "$d" ] || continue
            _n=$((_n + 1))
            _dirs="${_dirs} ${d}"
            _reason="$(cat "${d}/.reason" 2>/dev/null || echo "Unknown")"
            _date="$(cat "${d}/.date" 2>/dev/null || echo "$(basename "$d")")"
            echo -e "${B}${_n})${NC} ${W}${_date}${NC} ${DIM}·${NC} ${A}${_reason}${NC}"
        done

        [ "$_n" -eq 0 ] && echo -e "${DIM}No backups found${NC}"

        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        if autobackup_enabled; then
            _ab_toggle="${ERR}Disable${NC} Auto-Backup"
        else
            _ab_toggle="${OK}Enable${NC} Auto-Backup"
        fi
        echo -e "${B}c)${NC} ${W}Create${NC} Backup"
        echo -e "${B}t)${NC} ${_ab_toggle}"
        [ "$_n" -gt 0 ] && \
        echo -e "${B}d)${NC} ${ERR}Delete All${NC}"
        echo ""
        echo -e "${B}0)${NC} ${DIM}Back${NC}"
        echo ""
        echo -ne "${A}Select:${NC} " && read _bsel

        case "${_bsel:-0}" in
            0|"") return ;;
            c|C)
                init_backup "Manual"
                echo -e "${OK}Backup created${NC}"
                PAUSE
                continue ;;
            d|D)
                if [ "$_n" -gt 0 ]; then
                    confirm "Delete all ${_n} backups?" "n" || continue
                    rm -rf "$BACKUP_BASE"/*/
                    echo -e "${OK}All backups deleted${NC}"
                    PAUSE
                fi
                continue ;;
            t|T)
                mkdir -p "$BACKUP_BASE"
                if autobackup_enabled; then
                    touch "$AUTOBACKUP_OFF"
                    echo -e "${OK}Auto-backup disabled${NC}"
                else
                    rm -f "$AUTOBACKUP_OFF"
                    echo -e "${OK}Auto-backup enabled${NC}"
                fi
                PAUSE
                continue ;;
        esac

        _sel_dir=""
        _i=0
        for d in $_dirs; do
            _i=$((_i + 1))
            [ "$_i" = "$_bsel" ] && { _sel_dir="$d"; break; }
        done

        if [ -z "$_sel_dir" ]; then
            warn "Invalid selection"
            PAUSE
            continue
        fi

        do_backup_menu "$_sel_dir"
    done
}

# ═════════════════════════════════════════════════════════════════════
#  FULL RESET
# ═════════════════════════════════════════════════════════════════════

do_full_reset() {
    clear
    echo -e "${ERR}Full Reset${NC}"
    echo ""
    echo -e "${DIM}──────────────────────────────────────${NC}"
    echo ""
    echo -e "${A}This will:${NC}"
    echo -e "${ERR}-${NC} Delete all AmneziaWG interfaces"
    echo -e "${ERR}-${NC} Delete all related firewall zones, rules, forwardings"
    echo -e "${ERR}-${NC} Remove all interfaces from Podkop"
    echo -e "${ERR}-${NC} Delete all Liminal backups"
    echo ""

    interfaces="$(get_awg_interfaces)"
    if [ -n "$interfaces" ]; then
        echo -e "${A}Interfaces to delete:${NC}"
        for iface in $interfaces; do
            _pc="$(count_peers "$iface")"
            echo -e "  ${W}${iface}${NC} ${DIM}(${_pc} peers)${NC}"
        done
        echo ""
    fi

    echo -e "${DIM}──────────────────────────────────────${NC}"
    echo ""
    echo -e "${ERR}This action cannot be undone.${NC}"
    echo ""
    confirm "Confirm full reset?" "n" || return

    # Delete each interface with full cleanup
    for iface in $interfaces; do
        _port="$(uci -q get "network.${iface}.listen_port" || true)"
        _zone="$(find_zone_for_interface "$iface" 2>/dev/null || true)"

        # Delete peers
        while uci -q get "network.@amneziawg_${iface}[0]" >/dev/null 2>&1; do
            uci delete "network.@amneziawg_${iface}[0]"
        done

        # Delete interface
        echo -e "${B}Removing${NC} ${W}${iface}${NC}..."
        uci delete "network.${iface}" 2>/dev/null || true

        # Delete forwardings (reverse order, only _is_liminal)
        if [ -n "$_zone" ]; then
            _cnt=0
            while uci -q get "firewall.@forwarding[$_cnt]" >/dev/null 2>&1; do
                _cnt=$((_cnt + 1))
            done
            _fi=$((_cnt - 1))
            while [ "$_fi" -ge 0 ]; do
                _fl="$(uci -q get "firewall.@forwarding[$_fi]._is_liminal" || echo "0")"
                _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src"  || true)"
                _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" || true)"
                if [ "$_fl" = "1" ] && { [ "$_fsrc" = "$_zone" ] || [ "$_fdst" = "$_zone" ]; }; then
                    uci delete "firewall.@forwarding[$_fi]"
                fi
                _fi=$((_fi - 1))
            done

            # Delete zone only if _is_liminal
            _zi="$(find_zone_index "$_zone" || true)"
            if [ -n "$_zi" ]; then
                _zl="$(uci -q get "firewall.@zone[$_zi]._is_liminal" || echo "0")"
                [ "$_zl" = "1" ] && uci delete "firewall.@zone[$_zi]"
            fi
        fi

        # Delete firewall rules (reverse order, only _is_liminal)
        if [ -n "$_port" ]; then
            _cnt=0
            while uci -q get "firewall.@rule[$_cnt]" >/dev/null 2>&1; do
                _cnt=$((_cnt + 1))
            done
            _ri=$((_cnt - 1))
            while [ "$_ri" -ge 0 ]; do
                _rl="$(uci -q get "firewall.@rule[$_ri]._is_liminal" || echo "0")"
                _rport="$(uci -q get "firewall.@rule[$_ri].dest_port" || true)"
                [ "$_rl" = "1" ] && [ "$_rport" = "$_port" ] && uci delete "firewall.@rule[$_ri]"
                _ri=$((_ri - 1))
            done
        fi

        # Remove from Podkop
        if podkop_present && podkop_has_interface "$iface" 2>/dev/null; then
            remove_podkop_interface "$iface"
        fi
    done

    # Commit
    uci commit network 2>/dev/null || true
    uci commit firewall 2>/dev/null || true

    echo -e "${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
    if podkop_present && [ -x /etc/init.d/podkop ]; then
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
    fi

    # Delete backups
    echo -e "${B}Removing${NC} backups..."
    rm -rf "$BACKUP_BASE"

    echo -e "\n${OK}Full reset complete${NC}"
    PAUSE
}

# ═════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ═════════════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        clear
        AWG_COUNT="$(get_awg_interfaces | wc -w)"
        if have_cmd awg; then
            _awg_ver="$(awg version 2>/dev/null | sed -n 's/.*tools \(v[^ ]*\).*/\1/p')"
            _awg_status="${OK}${_awg_ver:-Installed}${NC}"
        else
            _awg_status="${ERR}Not Installed${NC}"
        fi
        if podkop_present && have_cmd podkop; then
            _pk_ver="$(podkop get_system_info 2>/dev/null | sed -n 's/.*"podkop_version"[^"]*"\([^"]*\)".*/\1/p')"
            _podkop_status="${OK}${_pk_ver:-Installed}${NC}"
        else
            _podkop_status="${ERR}Not Installed${NC}"
        fi

        # \033[<col>G = absolute cursor column
        _C="\\033[48G"
        echo -e "${V}⠀⠀⠀⠀⠀⠀⠀⢀⡄⠀⠀⠀⠀⠀⠀⠀⠀⢸⠳⣄${NC}"
        echo -e "${V}⠀⠀⠀⠀⠀⠀⠀⡏⣧⠀⠀⠀⣀⣀⣀⣀⣀⣈⡀⠣⢧${NC}"
        echo -ne "${V}⠀⠀⠀⠀⠀⠀⣰⠀⡯⣺⠋⢿⣅⠀⠀⠈⠀⠙⢌⠀⢈⣯⡒⠛⣄${NC}" && echo -e "${_C}${W}Liminal${NC} ${DIM}v${LIMINAL_VERSION}${NC}"
        echo -ne "${B}⠀⠀⠀⢀⠤⣼⢢⠋⠀⠀⠐⡇⠈⡄⠀⠀⠀⠀⢙⠝⠈⠀⣷⠀⠈⣧${NC}" && echo -e "${_C}${DIM}Powered by AmneziaWG${NC}"
        echo -e "${B}⠀⠀⢰⠁⢠⢾⠃⠀⠀⠀⡆⢿⠀⠙⠀⠀⠀⠀⢋⠓⣾⢿⢿⣶⠀⠈⡆${NC}"
        echo -ne "${B}⠀⠀⢿⠁⣖⣸⠀⠀⢰⣠⣧⠀⠙⠀⢟⢄⢄⠀⣤⠋⠿⣷⢿⢿⠁⢠⢿${NC}" && echo -e "${_C}${DIM}·${NC} ${A}Developer${NC}  ${W}Salvatore${NC}"
        echo -ne "${A}⠀⠀⣇⠀⢻⢿⠀⠀⡼⠇⠘⣆⠀⠠⣸⢀⣙⣢⣀⢢⣶⣥⢿⣯⠀⢸⢿${NC}" && echo -e "${_C}${DIM}·${NC} ${A}GitHub${NC}     ${W}@tickcount${NC}"
        echo -ne "${A}⠀⠀⢿⠀⠰⣾⣾⠼⣷⣭⢿⡆⠳⢿⡚⢲⢿⢿⠓⠉⠉⢻⢿⢿⣀⢿⢿${NC}" && echo -e "${_C}${DIM}·${NC} ${A}Website${NC}    ${W}aemeath.eu${NC}"
        echo -e "${A}⠀⠀⠸⡀⢠⢿⢿⡀⢧⠈⠒⠀⠀⣀⠀⠀⠁⠉⢛⠀⣠⡟⢿⢿⢿⢿⢿${NC}"
        echo -e "${DIM}⠀⠀⠀⣇⢿⢿⢿⢿⣶⣕⣤⢿⢿⣇⣀⣀⣤⠒⠓⠋⠋⠀⢿⢿⢿⢿⡟${NC}"
        echo -e "${DIM}⠀⠀⢠⣏⢿⢿⢿⠀⠀⠀⣼⢿⢿⡟⣾⢿⠟⠉⣦⠀⠀⠘⠋⠈⢿⢿⠃${NC}"
        echo -e "${DIM}⠀⢀⢿⢿⠋⠉⠀⠀⡞⠉⠉⢻⣛⢋⣶⠏⠀⣰⠁⠀⠀⠀⠀⠀⢻⢿⣧${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────────────────────${NC}"
        echo ""
        _has_awg=0; have_cmd awg && _has_awg=1
        _has_podkop=0; podkop_present && have_cmd podkop && _has_podkop=1

        echo -e "${A}AmneziaWG${NC}    ${_awg_status}"
        echo -e "${A}Podkop${NC}       ${_podkop_status}"
        echo -e "${A}Interfaces${NC}   ${W}${AWG_COUNT}${NC}"
        echo ""
        _qr_s="${ERR}✗${NC}"; have_cmd qrencode && _qr_s="${OK}✓${NC}"
        _jq_s="${ERR}✗${NC}"; have_cmd jq && _jq_s="${OK}✓${NC}"
        _b64_s="${ERR}✗${NC}"; have_cmd base64 && _b64_s="${OK}✓${NC}"
        echo -e "${DIM}Dependencies:${NC} qrencode ${_qr_s}  jq ${_jq_s}  base64 ${_b64_s}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────────────────────${NC}"
        echo ""
        if [ "$_has_awg" -eq 1 ]; then
            echo -e "${B}1)${NC} ${W}Create${NC} Interface"
            echo -e "${B}2)${NC} ${W}Manage${NC} Interfaces"
        else
            echo -e "${DIM}1) Create Interface  (requires AmneziaWG)${NC}"
            echo -e "${DIM}2) Manage Interfaces (requires AmneziaWG)${NC}"
        fi
        echo -e "${B}3)${NC} ${W}Manage${NC} Backups"
        echo -e "${B}4)${NC} ${ERR}Full Reset${NC}"
        echo ""
        _has_qr=0; have_cmd qrencode && _has_qr=1
        _has_jq=0; have_cmd jq && _has_jq=1
        _has_b64=0; have_cmd base64 && _has_b64=1

        _install_opts=""
        [ "$_has_awg" -eq 0 ] && \
        echo -e "${B}a)${NC} ${OK}Install${NC} AmneziaWG" && _install_opts=1
        [ "$_has_podkop" -eq 0 ] && \
        echo -e "${B}p)${NC} ${OK}Install${NC} Podkop" && _install_opts=1
        [ "$_has_qr" -eq 0 ] && \
        echo -e "${B}q)${NC} ${OK}Install${NC} qrencode" && _install_opts=1
        [ "$_has_jq" -eq 0 ] && \
        echo -e "${B}j)${NC} ${OK}Install${NC} jq" && _install_opts=1
        [ "$_has_b64" -eq 0 ] && \
        echo -e "${B}b)${NC} ${OK}Install${NC} coreutils-base64" && _install_opts=1
        [ -n "$_install_opts" ] && echo ""
        echo -e "${DIM}Enter) Exit${NC}"
        echo ""

        echo -ne "${A}Select:${NC} " && read MENU_CHOICE

        case "${MENU_CHOICE:-}" in
            1) [ "$_has_awg" -eq 1 ] && do_create || warn "Install AmneziaWG first" ;;
            2) [ "$_has_awg" -eq 1 ] && do_list || warn "Install AmneziaWG first" ;;
            3) do_manage_backups ;;
            4) do_full_reset ;;
            a|A)
                if [ "$_has_awg" -eq 0 ]; then
                    confirm "Install AmneziaWG?" "y" || continue
                    echo -e "${B}Installing${NC} AmneziaWG..."
                    sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh)
                    PAUSE
                fi ;;
            p|P)
                if [ "$_has_podkop" -eq 0 ]; then
                    confirm "Install Podkop?" "y" || continue
                    echo -e "${B}Installing${NC} Podkop..."
                    sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
                    PAUSE
                fi ;;
            q|Q)
                if [ "$_has_qr" -eq 0 ]; then
                    echo -e "${B}Installing${NC} qrencode..."
                    opkg update >/dev/null 2>&1; opkg install qrencode 2>/dev/null || apk add qrencode 2>/dev/null
                    echo -e "${OK}Done${NC}"; PAUSE
                fi ;;
            j|J)
                if [ "$_has_jq" -eq 0 ]; then
                    echo -e "${B}Installing${NC} jq..."
                    opkg update >/dev/null 2>&1; opkg install jq 2>/dev/null || apk add jq 2>/dev/null
                    echo -e "${OK}Done${NC}"; PAUSE
                fi ;;
            b|B)
                if [ "$_has_b64" -eq 0 ]; then
                    echo -e "${B}Installing${NC} coreutils-base64..."
                    opkg update >/dev/null 2>&1; opkg install coreutils-base64 2>/dev/null || apk add coreutils 2>/dev/null
                    echo -e "${OK}Done${NC}"; PAUSE
                fi ;;
            "") echo; exit 0 ;;
            *) ;;
        esac
    done
}

# ═══ Entry point ═════════════════════════════════════════════════════

ensure_required_tools
ensure_base_firewall
show_menu
