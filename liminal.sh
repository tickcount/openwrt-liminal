#!/bin/sh
# liminal.sh
# OpenWRT 24.10 / BusyBox ash
# Developer: Salvatore (GitHub: @tickcount)
# Credits: @immalware — config download service (https://t.me/immalware)

set -eu

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BACKUP_DIR=""
LIMINAL_VERSION="1.1"
LIMINAL_REPO="tickcount/openwrt-liminal"
LIMINAL_RAW_URL="https://raw.githubusercontent.com/${LIMINAL_REPO}/refs/heads/main/liminal.sh"

# ─── Colors (soft white-blue-violet palette) ─────────────────────────

W="\033[38;5;255m"            # clean bright white
B="\033[38;5;111m"            # soft blue
V="\033[38;5;141m"            # soft violet
A="\033[38;5;146m"            # soft steel blue (labels)
DIM="\033[2m\033[38;5;240m"   # dim gray (faded)
DIM2="\033[38;5;245m"         # slightly brighter dim
OK="\033[38;5;114m"           # soft green
WARN_C="\033[38;5;180m"       # soft wheat/amber
ERR="\033[38;5;174m"          # soft rose/red
NC="\033[0m"

# ─── Icons & box-drawing ────────────────────────────────────────────

ICO_ON="${OK}●${NC}"
ICO_OFF="${ERR}●${NC}"
ICO_DIS="${DIM}○${NC}"
ICO_OK="${OK}✓${NC}"
ICO_ERR="${ERR}✗${NC}"
ICO_WARN="${WARN_C}!${NC}"

BOX_TL="╭" BOX_TR="╮" BOX_BL="╰" BOX_BR="╯"
BOX_H="─" BOX_V="│"

# ─── Box-drawing helpers ─────────────────────────────────────────────

# box_top [width] — top border ╭───╮
box_top() {
    _w="${1:-54}"
    _line=""; _i=0; while [ "$_i" -lt "$_w" ]; do _line="${_line}${BOX_H}"; _i=$((_i+1)); done
    echo -e "${DIM}${BOX_TL}${_line}${BOX_TR}${NC}"
}

# box_bot [width] — bottom border ╰───╯
box_bot() {
    _w="${1:-54}"
    _line=""; _i=0; while [ "$_i" -lt "$_w" ]; do _line="${_line}${BOX_H}"; _i=$((_i+1)); done
    echo -e "${DIM}${BOX_BL}${_line}${BOX_BR}${NC}"
}

# box_sep [width] — separator ├───┤
box_sep() {
    _w="${1:-54}"
    _line=""; _i=0; while [ "$_i" -lt "$_w" ]; do _line="${_line}${BOX_H}"; _i=$((_i+1)); done
    echo -e "${DIM}├${_line}┤${NC}"
}

# box_line <text> [width] — content line │ text │
box_line() {
    echo -e "${DIM}${BOX_V}${NC} $1"
}

# ─── Breadcrumbs ─────────────────────────────────────────────────────

_CRUMBS=""
crumb_set()  { _CRUMBS="$*"; }
crumb_push() { [ -n "$_CRUMBS" ] && _CRUMBS="${_CRUMBS} > $1" || _CRUMBS="$1"; }
crumb_pop()  { _CRUMBS="$(echo "$_CRUMBS" | sed 's/ > [^>]*$//')"; }
crumb_show() {
    [ -z "$_CRUMBS" ] && return
    echo -e "${DIM}${_CRUMBS}${NC}"
    echo ""
}

# ─── Spinner ─────────────────────────────────────────────────────────

_SPIN_PID=""
_spin_frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

spinner_start() {
    _msg="${1:-Working...}"
    (
        _idx=0
        while true; do
            _ch="$(printf '%s' "$_spin_frames" | cut -c$((_idx % 10 + 1)))"
            printf '\r  %b %b' "${V}${_ch}${NC}" "${A}${_msg}${NC}" >&2
            _idx=$((_idx + 1))
            sleep 0.1 2>/dev/null || sleep 1
        done
    ) &
    _SPIN_PID=$!
}

spinner_stop() {
    [ -n "$_SPIN_PID" ] && kill "$_SPIN_PID" 2>/dev/null; wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K' >&2
}

# ─── Duration formatting ─────────────────────────────────────────────

fmt_duration() {
    _s="${1:-0}"
    [ "$_s" -le 0 ] 2>/dev/null && { printf '-'; return; }
    _d=$((_s / 86400)); _h=$(((_s % 86400) / 3600)); _m=$(((_s % 3600) / 60))
    if [ "$_d" -gt 0 ]; then
        printf '%dd %dh' "$_d" "$_h"
    elif [ "$_h" -gt 0 ]; then
        printf '%dh %dm' "$_h" "$_m"
    elif [ "$_m" -gt 0 ]; then
        printf '%dm' "$_m"
    else
        printf '%ds' "$_s"
    fi
}

# ─── Handshake color (green <30s, yellow <120s, red >120s) ───────────

hs_colored() {
    _val="$1"; _sec="${2:-9999}"
    if [ "$_val" = "-" ] || [ "$_val" = "never" ] || [ -z "$_val" ]; then
        printf '%b' "${DIM2}never${NC}"
    elif [ "$_sec" -le 30 ] 2>/dev/null; then
        printf '%b' "${OK}${_val}${NC}"
    elif [ "$_sec" -le 120 ] 2>/dev/null; then
        printf '%b' "${WARN_C}${_val}${NC}"
    else
        printf '%b' "${ERR}${_val}${NC}"
    fi
}

log()  { printf '%s\n' "$*"; }
warn() { echo -e "  ${ERR}${ICO_WARN} warning:${NC} $*" >&2; }
die()  { echo -e "  ${ERR}${ICO_ERR} error:${NC} $*" >&2; exit 1; }
PAUSE() { echo -ne "\n  ${DIM2}Press Enter...${NC}"; read dummy || true; }

# read_choice VAR — read a single menu choice, strip invisible/control chars
read_choice() {
    read -r _rc_raw || true
    _rc_clean="$(printf '%s' "${_rc_raw:-}" | tr -d '\001-\037\177\200-\237' | sed 's/[^A-Za-z0-9+]//g')"
    eval "$1=\$_rc_clean"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ─── Backup / Restore ────────────────────────────────────────────────

init_backup() {
    _reason="${1:-Manual}"
    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/root/liminal-backups/${TS}"
    mkdir -p "$BACKUP_DIR"
    cp /etc/config/network  "$BACKUP_DIR/network.bak"
    cp /etc/config/firewall "$BACKUP_DIR/firewall.bak"
    [ -f /etc/config/dhcp ]   && cp /etc/config/dhcp   "$BACKUP_DIR/dhcp.bak" || true
    [ -f /etc/config/podkop ] && cp /etc/config/podkop "$BACKUP_DIR/podkop.bak" || true
    echo "$_reason" > "$BACKUP_DIR/.reason"
    date '+%Y-%m-%d %H:%M:%S' > "$BACKUP_DIR/.date"
}

BACKUP_BASE="/root/liminal-backups"
AUTOBACKUP_OFF="/root/liminal-backups/.noautobackup"

autobackup_enabled() { ! [ -f "$AUTOBACKUP_OFF" ]; }

restore_backups() {
    echo -e "  ${B}Restoring${NC} backups from $BACKUP_DIR ..."
    [ -f "$BACKUP_DIR/network.bak" ]  && cp "$BACKUP_DIR/network.bak"  /etc/config/network
    [ -f "$BACKUP_DIR/firewall.bak" ] && cp "$BACKUP_DIR/firewall.bak" /etc/config/firewall
    [ -f "$BACKUP_DIR/dhcp.bak" ]     && cp "$BACKUP_DIR/dhcp.bak"     /etc/config/dhcp || true
    [ -f "$BACKUP_DIR/podkop.bak" ]   && cp "$BACKUP_DIR/podkop.bak"   /etc/config/podkop || true
    echo -e "  ${B}Reloading${NC} network..."
    /etc/init.d/network reload   >/dev/null 2>&1 || true
    echo -e "  ${B}Restarting${NC} firewall..."
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    echo -e "  ${B}Restarting${NC} dnsmasq..."
    /etc/init.d/dnsmasq restart  >/dev/null 2>&1 || true
    if [ -x /etc/init.d/podkop ]; then
        echo -e "  ${B}Restarting${NC} Podkop..."
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
    fi
    podkop_refresh
}

_SIGINT=0

on_error() {
    _SIGINT=1
    echo ""
}

trap on_error INT

# Flag for cancellable sections (create, rename, etc.)
_CANCELLED=0

trap_cancel() {
    _CANCELLED=0
    trap '_CANCELLED=1; trap on_error INT' INT
}

trap_restore() {
    trap on_error INT
}

is_cancelled() { [ "$_CANCELLED" -eq 1 ]; }

# Check & reset SIGINT flag — use after read in menu loops
sigint_caught() {
    [ "$_SIGINT" -eq 1 ] || return 1
    _SIGINT=0
    return 0
}

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
        echo -ne "${_q} [${OK}Y${NC}/${DIM2}n${NC}] "
    else
        echo -ne "${_q} [${DIM2}y${NC}/${ERR}N${NC}] "
    fi
    read -r _ans || true
    _ans="$(printf '%s' "${_ans:-}" | tr -d '\001-\037\177')"
    case "${_ans:-}" in
        1|y|Y|yes) return 0 ;;
        2|n|N|no) return 1 ;;
        "")
            if [ "$_def" = "y" ]; then return 0; else return 1; fi ;;
        *)
            if [ "$_def" = "y" ]; then return 0; else return 1; fi ;;
    esac
}

# ─── DNS selector ─────────────────────────────────────────────────────

# select_dns VAR [current_dns]
# Shows a numbered list of popular DNS servers. Sets VAR to the chosen IP.
# Returns 1 if cancelled.
select_dns() {
    _sd_var="$1"; _sd_cur="${2:-}"
    _sd_lan="$(detect_router_lan_ip 2>/dev/null || true)"

    # Read cached state (set by podkop_refresh at startup)
    _sd_sb_active=0
    if [ "${SB_RUNNING:-0}" -eq 1 ] && [ "${SB_DNS:-0}" -eq 1 ]; then
        _sd_sb_active=1
    fi

    echo ""
    echo -e "  ${A}Select DNS server:${NC}"
    if [ "$_sd_sb_active" -eq 1 ] && [ "${PK_INSTALLED:-0}" -eq 1 ]; then
        echo -e "  ${DIM2}Podkop: dnsmasq → Sing-Box (127.0.0.42:53)${NC}"
    elif [ "$_sd_sb_active" -eq 1 ]; then
        echo -e "  ${DIM2}Sing-Box DNS active (127.0.0.42:53)${NC}"
    elif [ "${SB_RUNNING:-0}" -eq 1 ]; then
        echo -e "  ${WARN_C}Sing-Box running but DNS not listening${NC}"
    fi
    echo ""

    # Build ordered list: current first (if set), then presets, then Router LAN
    _sd_n=0
    _sd_list=""
    _sd_cur_shown=0

    # Show current DNS first if it's set and not in the preset list
    if [ -n "$_sd_cur" ]; then
        _sd_cur_in_presets=0
        for _sd_entry in \
            "Cloudflare|1.1.1.1" \
            "Google|8.8.8.8" \
            "Quad9|9.9.9.9" \
            "OpenDNS|208.67.222.222" \
            "AdGuard|94.140.14.14" \
            "Comss.one|92.223.109.31"; do
            _sd_ip="${_sd_entry##*|}"
            if [ "$_sd_cur" = "$_sd_ip" ]; then _sd_cur_in_presets=1; fi
        done
        if [ -n "$_sd_lan" ] && [ "$_sd_cur" = "$_sd_lan" ]; then _sd_cur_in_presets=1; fi
    fi

    # Column positions (ANSI escape)
    _C1="\033[17G"  # name column
    _C2="\033[30G"  # ip column
    _C3="\033[48G"  # note column

    # Helper: print one DNS row
    # _sd_print NAME IP NOTE MARK
    _sd_print() {
        echo -e "  ${B}${_sd_n}${NC} ${DIM2}›${NC}${_C1}${W}${1}${NC}${_C2}${DIM2}${2}${NC}${_C3}${3}${4}"
    }

    # If current is custom (not in any preset), show it as #1
    if [ "$_sd_cur_shown" -eq 0 ] && [ -n "$_sd_cur" ] && [ "$_sd_cur_in_presets" -eq 0 ]; then
        _sd_n=$((_sd_n + 1))
        _sd_print "$_sd_cur" "" "" "${OK}current${NC}"
        _sd_list="${_sd_list} ${_sd_cur}"
        _sd_cur_shown=1
    fi

    # Preset list: name|ip
    for _sd_entry in \
        "Cloudflare|1.1.1.1" \
        "Google|8.8.8.8" \
        "Quad9|9.9.9.9" \
        "OpenDNS|208.67.222.222" \
        "AdGuard|94.140.14.14" \
        "Comss.one|92.223.109.31"; do
        _sd_name="${_sd_entry%%|*}"
        _sd_ip="${_sd_entry##*|}"
        _sd_n=$((_sd_n + 1))
        _sd_note=""
        _sd_mark=""
        if [ "$_sd_sb_active" -eq 1 ]; then _sd_note="${WARN_C}bypasses Sing-Box${NC}"; fi
        if [ -n "$_sd_cur" ] && [ "$_sd_cur" = "$_sd_ip" ]; then _sd_mark="${OK}current${NC}"; _sd_note=""; fi
        _sd_print "$_sd_name" "$_sd_ip" "$_sd_note" "$_sd_mark"
        _sd_list="${_sd_list} ${_sd_ip}"
    done

    # Router LAN IP
    if [ -n "$_sd_lan" ]; then
        _sd_n=$((_sd_n + 1))
        _sd_note=""
        _sd_mark=""
        if [ "$_sd_sb_active" -eq 1 ]; then _sd_note="${OK}→ Sing-Box + local DNS${NC}"; fi
        if [ -n "$_sd_cur" ] && [ "$_sd_cur" = "$_sd_lan" ]; then _sd_mark="${OK}current${NC}"; fi
        _sd_print "Router LAN" "$_sd_lan" "$_sd_note" "$_sd_mark"
        _sd_list="${_sd_list} ${_sd_lan}"
    fi

    echo -e "  ${B}0${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(enter manually)${NC}"
    echo ""

    _sd_max="$_sd_n"
    echo -ne "  ${A}>${NC} "; read -r _sd_choice || true
    sigint_caught && return 1
    _sd_choice="$(printf '%s' "${_sd_choice:-}" | tr -d '\001-\037\177')"

    # Empty = cancel
    [ -z "$_sd_choice" ] && return 1

    # Custom
    if [ "$_sd_choice" = "0" ]; then
        while true; do
            prompt _sd_custom "DNS server (IPv4)" "" || return 1
            sigint_caught && return 1
            [ -z "$_sd_custom" ] && return 1
            validate_ipv4 "$_sd_custom" && break
        done
        eval "$_sd_var=\$_sd_custom"
        return 0
    fi

    # Validate choice
    case "$_sd_choice" in *[!0-9]*) warn "Invalid selection"; return 1 ;; esac
    if [ "$_sd_choice" -lt 1 ] 2>/dev/null; then warn "Invalid selection"; return 1; fi
    if [ "$_sd_choice" -gt "$_sd_max" ] 2>/dev/null; then warn "Invalid selection"; return 1; fi

    # Map choice to IP from ordered list
    _sd_i=0; _sd_result=""
    for _sd_ip in $_sd_list; do
        _sd_i=$((_sd_i + 1))
        if [ "$_sd_i" = "$_sd_choice" ]; then _sd_result="$_sd_ip"; fi
    done

    if [ -z "$_sd_result" ]; then
        warn "Invalid selection"; return 1
    fi

    eval "$_sd_var=\$_sd_result"
    return 0
}

# ─── DNS hostrecord helpers ────────────────────────────────────────────

# Sanitize a string into a valid DNS label (lowercase, dashes, no special chars)
sanitize_hostname() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ' _' '--' \
        | sed 's/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//'
}

# Get router's local domain (default: lan)
get_lan_domain() {
    uci -q get "dhcp.@dnsmasq[0].domain" 2>/dev/null || echo "lan"
}

# Build FQDN for a peer: {sanitized_peer}.{sanitized_iface}.{domain}
build_peer_fqdn() {
    _bp_iface="$1"; _bp_desc="$2"
    _bp_h="$(sanitize_hostname "$_bp_desc")"
    _bp_i="$(sanitize_hostname "$_bp_iface")"
    _bp_d="$(get_lan_domain)"
    [ -z "$_bp_h" ] && return 1
    printf '%s.%s.%s\n' "$_bp_h" "$_bp_i" "$_bp_d"
}

# Find hostrecord index by _liminal_iface + _liminal_peer
find_hostrecord() {
    _fh_iface="$1"; _fh_peer="$2"; _fh_i=0
    while uci -q get "dhcp.@hostrecord[$_fh_i]" >/dev/null 2>&1; do
        _fh_li="$(uci -q get "dhcp.@hostrecord[$_fh_i]._liminal_iface" || true)"
        _fh_lp="$(uci -q get "dhcp.@hostrecord[$_fh_i]._liminal_peer" || true)"
        if [ "$_fh_li" = "$_fh_iface" ] && [ "$_fh_lp" = "$_fh_peer" ]; then
            echo "$_fh_i"; return 0
        fi
        _fh_i=$((_fh_i + 1))
    done
    return 1
}

# Get peer FQDN from existing hostrecord (or empty)
get_peer_hostrecord_fqdn() {
    _gph_idx="$(find_hostrecord "$1" "$2" 2>/dev/null)" || return 1
    uci -q get "dhcp.@hostrecord[$_gph_idx].name" || true
}

# Check if FQDN already exists in any hostrecord
hostrecord_fqdn_exists() {
    _he_fqdn="$1"; _he_i=0
    while uci -q get "dhcp.@hostrecord[$_he_i]" >/dev/null 2>&1; do
        _he_n="$(uci -q get "dhcp.@hostrecord[$_he_i].name" || true)"
        [ "$_he_n" = "$_he_fqdn" ] && return 0
        _he_i=$((_he_i + 1))
    done
    return 1
}

# Add a hostrecord for a peer (takes explicit FQDN)
add_peer_hostrecord() {
    _ah_iface="$1"; _ah_desc="$2"; _ah_ip="${3%%/*}"; _ah_fqdn="$4"
    hostrecord_fqdn_exists "$_ah_fqdn" && { warn "Hostname '$_ah_fqdn' already exists"; return 1; }
    uci add dhcp hostrecord >/dev/null
    _ah_idx="$(uci show dhcp 2>/dev/null \
        | sed -n 's/^dhcp\.@hostrecord\[\([0-9]\+\)\]=hostrecord$/\1/p' | tail -n1)"
    uci set "dhcp.@hostrecord[$_ah_idx].name=${_ah_fqdn}"
    uci set "dhcp.@hostrecord[$_ah_idx].ip=${_ah_ip}"
    uci set "dhcp.@hostrecord[$_ah_idx]._liminal_iface=${_ah_iface}"
    uci set "dhcp.@hostrecord[$_ah_idx]._liminal_peer=${_ah_desc}"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    echo -e "  ${ICO_OK} ${OK}DNS:${NC} ${_ah_fqdn} → ${_ah_ip}"
}

# Remove hostrecord for a specific peer
remove_peer_hostrecord() {
    _rh_idx="$(find_hostrecord "$1" "$2" 2>/dev/null)" || return 0
    _rh_fqdn="$(uci -q get "dhcp.@hostrecord[$_rh_idx].name" || true)"
    uci delete "dhcp.@hostrecord[$_rh_idx]"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    [ -n "$_rh_fqdn" ] && echo -e "  ${B}Removed${NC} DNS: ${_rh_fqdn}"
}

# Remove all hostrecords for an interface
remove_iface_hostrecords() {
    _ri_iface="$1"; _ri_changed=0
    _ri_cnt=0
    while uci -q get "dhcp.@hostrecord[$_ri_cnt]" >/dev/null 2>&1; do
        _ri_cnt=$((_ri_cnt + 1))
    done
    _ri_i=$((_ri_cnt - 1))
    while [ "$_ri_i" -ge 0 ]; do
        _ri_li="$(uci -q get "dhcp.@hostrecord[$_ri_i]._liminal_iface" || true)"
        if [ "$_ri_li" = "$_ri_iface" ]; then
            uci delete "dhcp.@hostrecord[$_ri_i]"
            _ri_changed=1
        fi
        _ri_i=$((_ri_i - 1))
    done
    if [ "$_ri_changed" -eq 1 ]; then
        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
        echo -e "  ${B}Removed${NC} DNS records for ${W}${_ri_iface}${NC}"
    fi
}

# Update all hostrecords when interface is renamed
rename_iface_hostrecords() {
    _uih_old="$1"; _uih_new="$2"
    _uih_domain="$(get_lan_domain)"
    _uih_changed=0; _uih_i=0
    while uci -q get "dhcp.@hostrecord[$_uih_i]" >/dev/null 2>&1; do
        _uih_li="$(uci -q get "dhcp.@hostrecord[$_uih_i]._liminal_iface" || true)"
        if [ "$_uih_li" = "$_uih_old" ]; then
            _uih_peer="$(uci -q get "dhcp.@hostrecord[$_uih_i]._liminal_peer" || true)"
            _uih_fqdn="$(build_peer_fqdn "$_uih_new" "$_uih_peer")"
            uci set "dhcp.@hostrecord[$_uih_i].name=${_uih_fqdn}"
            uci set "dhcp.@hostrecord[$_uih_i]._liminal_iface=${_uih_new}"
            _uih_changed=1
        fi
        _uih_i=$((_uih_i + 1))
    done
    if [ "$_uih_changed" -eq 1 ]; then
        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
        echo -e "  ${B}Updated${NC} DNS records: *.${_uih_old}.${_uih_domain} → *.$(sanitize_hostname "$_uih_new").${_uih_domain}"
    fi
}

# Run all DNS hostrecord safety checks and print warnings.
# Returns 0 if all checks pass, 1 if any warning was issued.
check_hostrecord_warnings() {
    _chw_iface="$1"
    _chw_ok=0

    # 1. dnsmasq running
    if ! /etc/init.d/dnsmasq enabled 2>/dev/null; then
        warn "dnsmasq is not enabled — hostnames will not resolve"
        _chw_ok=1
    elif ! pgrep -x dnsmasq >/dev/null 2>&1; then
        warn "dnsmasq is not running — hostnames will not resolve"
        _chw_ok=1
    fi

    # 2. Peer DNS points to router
    _chw_dns="$(uci -q get "network.${_chw_iface}.dns" || true)"
    _chw_lan="$(detect_router_lan_ip 2>/dev/null || true)"
    if [ -n "$_chw_dns" ] && [ -n "$_chw_lan" ] && [ "$_chw_dns" != "$_chw_lan" ]; then
        warn "Interface DNS is ${_chw_dns}, not router (${_chw_lan})"
        warn "Peers using external DNS will not resolve local hostnames"
        _chw_ok=1
    fi

    # 3. Zone input allows DNS
    _chw_zone="$(find_zone_for_interface "$_chw_iface" 2>/dev/null || true)"
    if [ -n "$_chw_zone" ]; then
        _chw_zi="$(find_zone_index "$_chw_zone" || true)"
        if [ -n "$_chw_zi" ]; then
            _chw_input="$(uci -q get "firewall.@zone[$_chw_zi].input" || echo "DROP")"
            if [ "$_chw_input" != "ACCEPT" ]; then
                _chw_has_dns_rule=0; _chw_ri=0
                while uci -q get "firewall.@rule[$_chw_ri]" >/dev/null 2>&1; do
                    _chw_src="$(uci -q get "firewall.@rule[$_chw_ri].src" || true)"
                    _chw_dp="$(uci -q get "firewall.@rule[$_chw_ri].dest_port" || true)"
                    _chw_tgt="$(uci -q get "firewall.@rule[$_chw_ri].target" || true)"
                    [ "$_chw_src" = "$_chw_zone" ] && [ "$_chw_dp" = "53" ] && [ "$_chw_tgt" = "ACCEPT" ] && { _chw_has_dns_rule=1; break; }
                    _chw_ri=$((_chw_ri + 1))
                done
                [ "$_chw_has_dns_rule" -eq 0 ] && {
                    warn "Zone '${_chw_zone}' input=${_chw_input} and no DNS rule"
                    warn "Peers cannot reach router DNS — add a rule for port 53"
                    _chw_ok=1
                }
            fi
        fi
    fi

    # 4-5. dnsmasq localservice & rebind_protection
    # Skip when Sing-Box DNS chain is active — Sing-Box handles resolution,
    # dnsmasq only forwards, so these settings don't affect hostrecord delivery.
    if [ "${SB_DNS:-0}" -eq 0 ] || [ "${DM_FWD:-0}" -eq 0 ]; then
        # 4. dnsmasq localservice
        _chw_ls="$(uci -q get "dhcp.@dnsmasq[0].localservice" || true)"
        if [ "$_chw_ls" = "1" ]; then
            warn "dnsmasq localservice=1 — may reject queries from VPN subnet"
            warn "Set 'localservice 0' or add VPN subnet to dnsmasq listen"
            _chw_ok=1
        fi

        # 5. rebind_protection
        _chw_rb="$(uci -q get "dhcp.@dnsmasq[0].rebind_protection" || true)"
        if [ "$_chw_rb" = "1" ]; then
            _chw_rb_ok=0
            _chw_domain="$(get_lan_domain)"
            for _chw_rd in $(uci -q get "dhcp.@dnsmasq[0].rebind_domain" 2>/dev/null || true); do
                if [ "$_chw_rd" = "/${_chw_domain}/" ] || [ "$_chw_rd" = "$_chw_domain" ]; then _chw_rb_ok=1; fi
            done
            if [ "$_chw_rb_ok" -eq 0 ]; then
                warn "dnsmasq rebind_protection=1 — may block private IP responses"
                warn "Add '${_chw_domain}' to rebind_domain whitelist if resolution fails"
                _chw_ok=1
            fi
        fi
    fi

    # 6. Sing-Box / Podkop DNS chain
    detect_podkop_state "$_chw_iface"
    _chw_label="Sing-Box"
    if [ "${PK_INSTALLED:-0}" -eq 1 ] && [ "${PK_LINKED:-0}" -eq 1 ]; then _chw_label="Podkop"; fi
    # Check if Sing-Box is relevant (podkop linked, or standalone with dnsmasq fwd)
    if { [ "${PK_LINKED:-0}" -eq 1 ]; } || { [ "${SB_DNS:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 1 ]; }; then
        if [ "${SB_RUNNING:-0}" -eq 0 ]; then
            warn "${_chw_label}: Sing-Box is not running"
            _chw_ok=1
        elif [ "${SB_DNS:-0}" -eq 0 ]; then
            warn "${_chw_label}: Sing-Box not listening on 127.0.0.42:53"
            _chw_ok=1
        elif [ "${DM_FWD:-0}" -eq 0 ]; then
            warn "${_chw_label}: dnsmasq missing server 127.0.0.42"
            _chw_ok=1
        elif [ "${PK_DNS_VIA_ROUTER:-0}" -eq 1 ]; then
            echo -e "  ${ICO_OK} ${DIM2}${_chw_label}: peer → dnsmasq → Sing-Box (hostrecords OK)${NC}"
        fi
        if [ "${DM_NORESOLV:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 0 ]; then
            warn "${_chw_label}: noresolv=1 but no server 127.0.0.42 — DNS broken"
            _chw_ok=1
        fi
        if [ "${PK_DTD:-0}" -eq 1 ]; then
            warn "Podkop: dont_touch_dhcp=1 — verify dnsmasq config manually"
            if [ "${DM_FWD:-0}" -eq 0 ]; then
                warn "Add 'list server 127.0.0.42' to dhcp config"
                _chw_ok=1
            fi
        fi
    fi

    return "$_chw_ok"
}

# ─── Validators ───────────────────────────────────────────────────────

validate_ifname() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$' || { warn "Invalid interface name: $1"; return 1; }
}

validate_zone_name() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$' || { warn "Invalid firewall zone name: $1"; return 1; }
}

validate_name() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9 _.-]+$' || { warn "Only English letters, digits, spaces, dots, hyphens and underscores allowed"; return 1; }
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

# ─── Sing-box / Podkop DNS state detection ───────────────────────────
#
# Two-level cache:
#   podkop_refresh  — heavy checks (process, ports, nft, dnsmasq).
#                     Call once at startup and after service restarts.
#   detect_podkop_state IFACE — lightweight per-interface UCI lookup.
#
# SB_RUNNING    — Sing-Box process alive
# SB_DNS        — Sing-Box listening on 127.0.0.42:53
# SB_TPROXY     — Sing-Box listening on 127.0.0.1:1602
# PK_INSTALLED  — podkop UCI config exists
# PK_ENABLED    — podkop service enabled (/etc/rc.d/S99podkop)
# PK_NFT_ACTIVE — nftables PodkopTable exists
# PK_DTD        — podkop dont_touch_dhcp=1
# DM_FWD        — dnsmasq server=127.0.0.42
# DM_NORESOLV   — dnsmasq noresolv=1
# DM_OK         — dnsmasq fully configured (server + noresolv + cachesize=0)
# PK_LINKED     — (per-iface) interface in podkop source_network_interfaces
# PK_DNS_VIA_ROUTER — (per-iface) DNS equals router LAN IP
#

# Heavy checks — call once at startup and after service restarts
podkop_refresh() {
    SB_RUNNING=0; SB_DNS=0; SB_TPROXY=0
    PK_INSTALLED=0; PK_ENABLED=0; PK_NFT_ACTIVE=0; PK_DTD=0
    DM_FWD=0; DM_NORESOLV=0; DM_OK=0
    PK_LINKED=0; PK_DNS_VIA_ROUTER=0

    # Sing-Box (standalone or via podkop)
    if pgrep -f "sing-box" >/dev/null 2>&1; then SB_RUNNING=1; fi

    if [ "$SB_RUNNING" -eq 1 ]; then
        _dpk_ports="$(netstat -ln 2>/dev/null || true)"
        if echo "$_dpk_ports" | grep -q '127\.0\.0\.42:53'; then SB_DNS=1; fi
        if echo "$_dpk_ports" | grep -q '127\.0\.0\.1:1602'; then SB_TPROXY=1; fi
    fi

    # dnsmasq configuration (independent of podkop)
    _dpk_cachesize="$(uci -q get "dhcp.@dnsmasq[0].cachesize" 2>/dev/null || true)"
    if [ "$(uci -q get "dhcp.@dnsmasq[0].noresolv" 2>/dev/null || true)" = "1" ]; then DM_NORESOLV=1; fi
    for _dpk_srv in $(uci -q get "dhcp.@dnsmasq[0].server" 2>/dev/null || true); do
        case "$_dpk_srv" in 127.0.0.42|127.0.0.42\#*) DM_FWD=1 ;; esac
    done
    if [ "$DM_FWD" -eq 1 ] && [ "$DM_NORESOLV" -eq 1 ] && [ "$_dpk_cachesize" = "0" ]; then DM_OK=1; fi

    # podkop-specific
    if podkop_present; then
        PK_INSTALLED=1
        if [ -x /etc/rc.d/S99podkop ] 2>/dev/null; then PK_ENABLED=1; fi
        if nft list table inet PodkopTable >/dev/null 2>&1; then PK_NFT_ACTIVE=1; fi
        if [ "$(uci -q get "podkop.settings.dont_touch_dhcp" 2>/dev/null || true)" = "1" ]; then PK_DTD=1; fi
    fi
}

# Lightweight per-interface update — reads cached globals,
# only updates PK_LINKED and PK_DNS_VIA_ROUTER.
detect_podkop_state() {
    _dpk_iface="${1:-}"
    PK_LINKED=0; PK_DNS_VIA_ROUTER=0

    # PK_LINKED only makes sense if podkop is installed
    if [ "${PK_INSTALLED:-0}" -eq 1 ] && [ -n "$_dpk_iface" ]; then
        if podkop_has_interface "$_dpk_iface" 2>/dev/null; then
            PK_LINKED=1
        fi
    fi

    if [ -n "$_dpk_iface" ]; then
        _dpk_dns="$(uci -q get "network.${_dpk_iface}.dns" || true)"
        _dpk_lan="$(detect_router_lan_ip 2>/dev/null || true)"
        if [ -n "$_dpk_dns" ] && [ -n "$_dpk_lan" ] && [ "$_dpk_dns" = "$_dpk_lan" ]; then
            PK_DNS_VIA_ROUTER=1
        fi
    fi
}

# Short description of the DNS chain for display.
# Shows Sing-Box status if: podkop linked to this iface, OR standalone Sing-Box with dnsmasq forwarding.
# REQUIRES: podkop_refresh done + detect_podkop_state called.
dns_chain_label() {
    # Show label if: podkop linked, OR Sing-Box DNS active with dnsmasq forwarding
    if [ "${PK_LINKED:-0}" -eq 0 ] && [ "${SB_DNS:-0}" -eq 0 ]; then return; fi
    if [ "${PK_LINKED:-0}" -eq 0 ] && [ "${DM_FWD:-0}" -eq 0 ]; then return; fi
    if [ "${SB_RUNNING:-0}" -eq 0 ]; then
        printf '%b' "${ERR}Sing-Box not running${NC}"
    elif [ "${SB_DNS:-0}" -eq 0 ]; then
        printf '%b' "${ERR}Sing-Box DNS not listening${NC}"
    elif [ "${PK_DNS_VIA_ROUTER:-0}" -eq 1 ] && [ "$DM_FWD" -eq 1 ]; then
        printf '%b' "${DIM2}→ Sing-Box${NC}"
    elif [ "${PK_DNS_VIA_ROUTER:-0}" -eq 0 ]; then
        printf '%b' "${WARN_C}bypasses Sing-Box${NC}"
    elif [ "$DM_FWD" -eq 0 ]; then
        printf '%b' "${WARN_C}dnsmasq not forwarding${NC}"
    fi
}

# ─── Enumerate AWG interfaces ────────────────────────────────────────

get_awg_interfaces() {
    # Only return interfaces created by Liminal
    uci show network 2>/dev/null \
        | grep "\._liminal_iface=" \
        | sed "s/\._liminal_iface=.*//" \
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
      --argjson allowed_ips "$(printf '%s' "$_conf" | sed -n 's/^AllowedIPs = //p' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)" \
      '{
          H1: $h1, H2: $h2, H3: $h3, H4: $h4,
          I1: $i1, Jc: "120", Jmax: "911", Jmin: "23", S1: "0", S2: "0",
          allowed_ips: $allowed_ips,
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
    echo -e "  ${V}── Peer Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    echo ""
    echo -e "  ${A}AmneziaVPN key:${NC}"
    echo "$_VPN_KEY"
    echo ""

    _conf_b64="$(printf "%s" "$_conf" \
        | base64 -w 0 2>/dev/null \
        || printf "%s" "$_conf" | base64)"
    echo -e "  ${A}Download:${NC} https://immalware.vercel.app/download?filename=awg_${_iface}.conf&content=${_conf_b64}"
    echo ""

    if have_cmd qrencode; then
        echo -e "  ${A}QR Code:${NC}"
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
    _psk="$(uci -q get "network.@${_pt}[$_idx].preshared_key" || true)"
    _client_allowed_ips="$(uci -q get "network.@${_pt}[$_idx].client_allowed_ips" || echo "0.0.0.0/0, ::/0")"

    _server_priv="$(uci -q get "network.${_iface}.private_key" || true)"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey 2>/dev/null || true)"

    _port="$(uci -q get "network.${_iface}.listen_port" || echo "51820")"
    _dns="$(uci -q get "network.${_iface}.dns" || true)"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "1.1.1.1")"
    _mtu="$(uci -q get "network.${_iface}.mtu" || echo "1280")"

    _endpoint_host="$(uci -q get "network.${_iface}.endpoint_host" || true)"
    if [ -z "$_endpoint_host" ]; then
        _endpoint_host="$(detect_wan_ip || true)"
    fi
    [ -z "$_endpoint_host" ] && _endpoint_host="YOUR_SERVER_IP"

    _out="$(printf "[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = %s\nMTU = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s\nEndpoint = %s:%s\nPersistentKeepAlive = %s\n" \
        "$_client_priv" "$_peer_ip" "$_dns" "$_mtu" "$_server_pub" "$_client_allowed_ips" "$_endpoint_host" "$_port" "$_keepalive")"
    [ -n "$_psk" ] && _out="${_out}$(printf "PresharedKey = %s\n" "$_psk")"
    printf "%s" "$_out"
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
    _endpoint_host="$(uci -q get "network.${_iface}.endpoint_host" || true)"
    if [ -z "$_endpoint_host" ]; then
        _endpoint_host="$(detect_wan_ip || true)"
    fi
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
      --argjson allowed_ips "$(printf '%s' "$_conf" | sed -n 's/^AllowedIPs = //p' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)" \
      '{
          H1: $h1, H2: $h2, H3: $h3, H4: $h4,
          I1: $i1, Jc: "120", Jmax: "911", Jmin: "23", S1: "0", S2: "0",
          allowed_ips: $allowed_ips,
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
    echo -e "  ${V}── Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    PAUSE
}

show_peer_qr() {
    have_cmd qrencode || { warn "qrencode is required"; PAUSE; return; }
    _conf="$(reconstruct_peer_config "$1" "$2")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; PAUSE; return; }
    echo ""
    echo -e "  ${V}── QR Code ──${NC}"
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
    echo -e "  ${A}Download link:${NC}"
    echo "https://immalware.vercel.app/download?filename=awg_$1.conf&content=${_b64}"
    PAUSE
}

show_peer_vpn_key() {
    have_cmd jq     || { warn "jq is required"; PAUSE; return; }
    have_cmd base64 || { warn "base64 is required"; PAUSE; return; }
    _key="$(build_vpn_key "$1" "$2")"
    echo ""
    echo -e "  ${A}AmneziaVPN key:${NC}"
    echo "$_key"
    PAUSE
}

show_peer_all() {
    _iface="$1"; _idx="$2"
    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; PAUSE; return; }

    echo ""
    echo -e "  ${V}── Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    echo ""

    if have_cmd jq && have_cmd base64; then
        _key="$(build_vpn_key "$_iface" "$_idx")"
        echo -e "  ${A}AmneziaVPN key:${NC}"
        echo "$_key"
        echo ""
    fi

    if have_cmd base64; then
        _b64="$(printf "%s" "$_conf" | base64 -w 0 2>/dev/null || printf "%s" "$_conf" | base64)"
        echo -e "  ${A}Download:${NC}"
        echo "https://immalware.vercel.app/download?filename=awg_${_iface}.conf&content=${_b64}"
        echo ""
    fi

    if have_cmd qrencode; then
        echo -e "  ${A}QR Code:${NC}"
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
    [ -z "${_new_name:-}" ] && { echo -e "${DIM2}Cancelled${NC}"; PAUSE; return 1; }
    validate_name "$_new_name" || { PAUSE; return 1; }
    [ "$_new_name" = "$_old_desc" ] && { echo -e "${DIM2}Name unchanged${NC}"; PAUSE; return 1; }
    _dup="$(uci -q show network 2>/dev/null \
        | grep "\.description='${_new_name}'" | head -n1 || true)"
    [ -n "$_dup" ] && { warn "Peer '${_new_name}' already exists"; PAUSE; return 1; }

    uci set "network.@${_pt}[$_idx].description=$_new_name"
    uci commit network

    # Update hostrecord if exists
    _rp_hr_idx="$(find_hostrecord "$_iface" "$_old_desc" 2>/dev/null)" && {
        _rp_ip="$(uci -q get "dhcp.@hostrecord[$_rp_hr_idx].ip" || true)"
        _rp_fqdn="$(build_peer_fqdn "$_iface" "$_new_name")"
        uci set "dhcp.@hostrecord[$_rp_hr_idx].name=${_rp_fqdn}"
        uci set "dhcp.@hostrecord[$_rp_hr_idx]._liminal_peer=${_new_name}"
        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
        echo -e "  ${B}Updated${NC} DNS: ${W}${_rp_fqdn}${NC}"
    }

    echo -e "  ${OK}Renamed:${NC} ${_old_desc} -> ${W}${_new_name}${NC}"
    PAUSE
    # Return new name via global
    PEER_NEW_NAME="$_new_name"
    return 0
}

do_regen_peer() {
    _iface="$1"; _idx="$2"; _desc="$3"
    _pt="amneziawg_${_iface}"

    echo ""
    echo -e "  ${A}This will generate new keys for '${W}${_desc}${A}'.${NC}"
    echo -e "  ${A}The old config/QR/vpn:// will stop working.${NC}"
    echo ""
    confirm "Regenerate keys?" "n" || return

    _client_priv="$(awg genkey)" || { warn "Key generation failed"; PAUSE; return; }
    _client_pub="$(printf '%s' "$_client_priv" | awg pubkey)" \
        || { warn "Public key derivation failed"; PAUSE; return; }

    uci set "network.@${_pt}[$_idx].private_key=$_client_priv"
    uci set "network.@${_pt}[$_idx].public_key=$_client_pub"
    uci commit network

    echo -e "  ${B}Restarting${NC} AWG..."
    ifdown "$_iface" >/dev/null 2>&1 || true
    ifup "$_iface" >/dev/null 2>&1 || true

    echo -e "\n  ${OK}Keys regenerated for '${_desc}'${NC}"
    echo ""

    # Show new config
    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"
    if [ -n "$_conf" ]; then
        echo -e "  ${V}── New Config ──${NC}"
        echo ""
        echo -e "${W}${_conf}${NC}"
        echo ""

        if have_cmd jq && have_cmd base64; then
            _key="$(build_vpn_key "$_iface" "$_idx")"
            echo -e "  ${A}AmneziaVPN key:${NC}"
            echo "$_key"
            echo ""
        fi

        if have_cmd qrencode; then
            echo -e "  ${A}QR Code:${NC}"
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
    crumb_push "$_desc"

    while true; do
        clear
        crumb_show
        _aip="$(uci -q get "network.@${_pt}[$_idx].allowed_ips" || echo "?")"
        _pub="$(uci -q get "network.@${_pt}[$_idx].public_key" || true)"
        _peer_disabled="$(uci -q get "network.@${_pt}[$_idx].disabled" || echo "0")"
        [ "$_peer_disabled" != "1" ] && _peer_disabled=0
        _shortpub=""
        [ -n "$_pub" ] && _shortpub="$(printf '%s' "$_pub" | cut -c1-10)..."

        _hs=""; _rx=""; _tx=""; _ep=""
        _ka="$(uci -q get "network.@${_pt}[$_idx].persistent_keepalive" || echo "0")"
        _is_online=0; _hs_sec=9999

        if [ "$_peer_disabled" -eq 0 ]; then
            _hs="$(get_peer_handshake "$_iface" "$_pub")"
            _rx="$(get_peer_rx "$_iface" "$_pub")"
            _tx="$(get_peer_tx "$_iface" "$_pub")"
            _ep="$(get_peer_endpoint_live "$_iface" "$_pub")"
        fi

        if [ "$_peer_disabled" -eq 1 ]; then
            _st_ico="${ICO_DIS}"; _online="${DIM2}Disabled${NC}"
        else
            _st_ico="${ICO_OFF}"; _online="${ERR}Offline${NC}"
            if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                _hs_sec="$(awg show "$_iface" 2>/dev/null | awk -v pk="$_pub" '
                    /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                        sub(/.*latest handshake: /,"");
                        t=0;for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                            if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                            else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                        print t;exit}')"
                if [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null; then
                    _st_ico="${ICO_ON}"; _online="${OK}Online${NC}"
                    _is_online=1
                fi
            fi
        fi

        _hs_col="$(hs_colored "${_hs:--}" "${_hs_sec}")"

        detect_podkop_state "$_iface"

        box_top 44
        box_line "  ${_st_ico} ${W}${_desc}${NC}  ${_online}"
        box_sep 44
        box_line "  ${A}Address${NC}      ${W}${_aip}${NC}"
        if [ "$_is_online" -eq 1 ] && [ -n "$_ep" ]; then
            box_line "  ${A}Endpoint${NC}     ${W}${_ep}${NC}"
        fi
        box_line "  ${A}Handshake${NC}    ${_hs_col}"
        if [ -n "$_rx" ] || [ -n "$_tx" ]; then
            if [ -n "$_rx" ]; then box_line "  ${A}Rx${NC}           ${W}${_rx}${NC}"; fi
            if [ -n "$_tx" ]; then box_line "  ${A}Tx${NC}           ${W}${_tx}${NC}"; fi
        fi
        box_sep 44
        _peer_dns="$(uci -q get "network.${_iface}.dns" || echo "n/a")"
        _pdns_chain="$(dns_chain_label "$_iface")"
        [ -n "$_pdns_chain" ] && _pdns_chain="  ${_pdns_chain}"
        box_line "  ${A}DNS${NC}          ${W}${_peer_dns}${NC}${_pdns_chain}"
        if [ -n "$_ka" ] && [ "$_ka" != "0" ]; then
            box_line "  ${A}Keepalive${NC}    ${DIM2}every ${_ka}s${NC}"
        else
            box_line "  ${A}Keepalive${NC}    ${DIM2}off${NC}"
        fi
        box_line "  ${A}Public Key${NC}   ${DIM2}${_shortpub}${NC}"
        _hr_fqdn="$(get_peer_hostrecord_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
        if [ -n "$_hr_fqdn" ]; then
            box_line "  ${A}Hostname${NC}     ${W}${_hr_fqdn}${NC}"
        else
            box_line "  ${A}Hostname${NC}     ${DIM2}none${NC}"
        fi
        box_bot 44

        # ── Inline DNS diagnostics (PK_* already set above) ──
        if [ -n "$_hr_fqdn" ]; then
            _dns_warns=0
            _router_ip="$(detect_router_lan_ip 2>/dev/null || true)"

            # dnsmasq not running
            if ! pgrep -x dnsmasq >/dev/null 2>&1; then
                echo -e "  ${ICO_WARN} ${WARN_C}dnsmasq is not running${NC}"
                _dns_warns=1
            fi

            # DNS mismatch (skip if podkop handles DNS via Sing-Box)
            if [ -n "$_peer_dns" ] && [ -n "$_router_ip" ] && [ "$_peer_dns" != "$_router_ip" ]; then
                echo -e "  ${ICO_WARN} ${WARN_C}DNS is ${_peer_dns}, not router — hostname won't resolve${NC}"
                _dns_warns=1
            fi

            # Zone input blocks DNS
            _peer_zone="$(find_zone_for_interface "$_iface" 2>/dev/null || true)"
            if [ -n "$_peer_zone" ]; then
                _pz_zi="$(find_zone_index "$_peer_zone" || true)"
                if [ -n "$_pz_zi" ]; then
                    _pz_input="$(uci -q get "firewall.@zone[$_pz_zi].input" || echo "DROP")"
                    if [ "$_pz_input" != "ACCEPT" ]; then
                        _pz_dns_ok=0; _pz_ri=0
                        while uci -q get "firewall.@rule[$_pz_ri]" >/dev/null 2>&1; do
                            _pz_src="$(uci -q get "firewall.@rule[$_pz_ri].src" || true)"
                            _pz_dp="$(uci -q get "firewall.@rule[$_pz_ri].dest_port" || true)"
                            _pz_tgt="$(uci -q get "firewall.@rule[$_pz_ri].target" || true)"
                            [ "$_pz_src" = "$_peer_zone" ] && [ "$_pz_dp" = "53" ] && [ "$_pz_tgt" = "ACCEPT" ] && { _pz_dns_ok=1; break; }
                            _pz_ri=$((_pz_ri + 1))
                        done
                        [ "$_pz_dns_ok" -eq 0 ] && {
                            echo -e "  ${ICO_WARN} ${WARN_C}Zone '${_peer_zone}' blocks DNS (port 53)${NC}"
                            _dns_warns=1
                        }
                    fi
                fi
            fi

            # Sing-Box / Podkop diagnostics
            _sb_label="Sing-Box"
            if [ "${PK_INSTALLED:-0}" -eq 1 ] && [ "${PK_LINKED:-0}" -eq 1 ]; then
                _sb_label="Podkop"
            fi
            # Show if: podkop linked, or standalone Sing-Box with dnsmasq forwarding
            if { [ "${PK_LINKED:-0}" -eq 1 ]; } || { [ "${SB_DNS:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 1 ]; }; then
                if [ "${SB_RUNNING:-0}" -eq 0 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: Sing-Box is not running${NC}"
                    _dns_warns=1
                elif [ "${SB_DNS:-0}" -eq 0 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: Sing-Box not listening on 127.0.0.42:53${NC}"
                    _dns_warns=1
                elif [ "${DM_FWD:-0}" -eq 0 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: dnsmasq missing server 127.0.0.42${NC}"
                    _dns_warns=1
                elif [ "${PK_DNS_VIA_ROUTER:-0}" -eq 1 ]; then
                    echo -e "  ${ICO_OK} ${DIM2}${_sb_label}: peer → dnsmasq → Sing-Box (hostrecords OK)${NC}"
                fi
                if [ "${DM_NORESOLV:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 0 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: noresolv=1 but no server 127.0.0.42${NC}"
                    _dns_warns=1
                fi
                if [ "${PK_DTD:-0}" -eq 1 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}Podkop: dont_touch_dhcp=1 — verify dnsmasq manually${NC}"
                fi
            fi

            [ "$_dns_warns" -eq 1 ] && echo ""
        fi
        echo ""

        if [ "$_peer_disabled" -eq 1 ]; then
            _peer_toggle="${OK}Enable${NC} Peer"
        else
            _peer_toggle="${ERR}Disable${NC} Peer"
        fi

        echo -e "  ${DIM2}Config${NC}"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Show${NC} Setup Config"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Show${NC} Download Link"
        echo -e "  ${B}3${NC} ${DIM2}›${NC} ${W}Show${NC} vpn:// Key"
        echo -e "  ${B}4${NC} ${DIM2}›${NC} ${W}Show${NC} QR Code"
        echo -e "  ${B}5${NC} ${DIM2}›${NC} ${W}Show${NC} All"
        echo ""
        echo -e "  ${DIM2}Settings${NC}"
        _cur_caip="$(uci -q get "network.@${_pt}[$_idx].client_allowed_ips" || echo "0.0.0.0/0, ::/0")"
        echo -e "  ${B}a${NC} ${DIM2}›${NC} ${W}AllowedIPs${NC}  ${DIM2}${_cur_caip}${NC}"
        echo -e "  ${B}k${NC} ${DIM2}›${NC} ${W}Keepalive${NC}   ${DIM2}${_ka}s${NC}"
        if [ -n "$_hr_fqdn" ]; then
            echo -e "  ${B}h${NC} ${DIM2}›${NC} ${W}Hostname${NC}    ${DIM2}${_hr_fqdn}${NC}"
        else
            echo -e "  ${B}h${NC} ${DIM2}›${NC} ${W}Hostname${NC}    ${DIM2}none${NC}"
        fi
        echo ""
        echo -e "  ${DIM2}Actions${NC}"
        echo -e "  ${B}6${NC} ${DIM2}›${NC} ${W}Rename${NC} Peer"
        echo -e "  ${B}7${NC} ${DIM2}›${NC} ${ERR}Regenerate${NC} Keys"
        echo -e "  ${B}8${NC} ${DIM2}›${NC} ${_peer_toggle}"
        echo -e "  ${B}9${NC} ${DIM2}›${NC} ${ERR}Delete${NC} Peer"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice _peer_choice
        sigint_caught && { crumb_pop; return; }

        case "${_peer_choice:-}" in
            1) show_peer_conf "$_iface" "$_idx" ;;
            2) show_peer_download "$_iface" "$_idx" ;;
            3) show_peer_vpn_key "$_iface" "$_idx" ;;
            4) show_peer_qr "$_iface" "$_idx" ;;
            5) show_peer_all "$_iface" "$_idx" ;;
            6)  PEER_NEW_NAME=""
                if do_rename_peer "$_iface" "$_idx" "$_desc"; then
                    _desc="$PEER_NEW_NAME"
                    crumb_pop; crumb_push "$_desc"
                fi ;;
            7) do_regen_peer "$_iface" "$_idx" "$_desc" ;;
            8)  if [ "$_peer_disabled" -eq 1 ]; then
                    uci delete "network.@${_pt}[$_idx].disabled" 2>/dev/null || true
                    uci commit network
                    spinner_start "Enabling peer..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    ifup "$_iface" >/dev/null 2>&1 || true
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Peer '${_desc}' enabled${NC}"
                else
                    uci set "network.@${_pt}[$_idx].disabled=1"
                    uci commit network
                    spinner_start "Disabling peer..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    ifup "$_iface" >/dev/null 2>&1 || true
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Peer '${_desc}' disabled${NC}"
                fi
                PAUSE ;;
            9)  confirm "Delete peer '${_desc}'?" "n" || continue
                sigint_caught && continue
                remove_peer_hostrecord "$_iface" "$_desc"
                uci delete "network.@${_pt}[$_idx]"
                uci commit network
                spinner_start "Restarting AWG..."
                ifdown "$_iface" >/dev/null 2>&1 || true
                ifup "$_iface" >/dev/null 2>&1 || true
                spinner_stop
                echo -e "  ${ICO_OK} ${OK}Peer '${_desc}' deleted${NC}"
                PAUSE
                crumb_pop; return ;;
            a) # Edit AllowedIPs
                echo ""
                _cur_caip="$(uci -q get "network.@${_pt}[$_idx].client_allowed_ips" || echo "0.0.0.0/0, ::/0")"
                echo -e "  ${A}Current:${NC} ${W}${_cur_caip}${NC}"
                echo ""
                echo -e "  ${DIM2}Presets:${NC}"
                echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Full tunnel${NC}   ${DIM2}0.0.0.0/0, ::/0${NC}"
                echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Custom${NC}       ${DIM2}enter manually${NC}"
                echo -e "  ${DIM2}Enter › Cancel${NC}"
                echo ""
                prompt _aip_choice "Select" "" || continue
                sigint_caught && continue
                [ -z "$_aip_choice" ] && { echo -e "  ${DIM2}Cancelled${NC}"; PAUSE; continue; }
                case "$_aip_choice" in
                    1) _new_caip="0.0.0.0/0, ::/0" ;;
                    2) prompt _new_caip "AllowedIPs" "$_cur_caip" || continue
                       sigint_caught && continue
                       [ -z "$_new_caip" ] && { echo -e "  ${DIM2}Cancelled${NC}"; PAUSE; continue; } ;;
                    *) continue ;;
                esac
                if [ "$_new_caip" != "$_cur_caip" ]; then
                    confirm "Apply?" "y" || continue
                    uci set "network.@${_pt}[$_idx].client_allowed_ips=$_new_caip"
                    uci commit network
                    echo -e "  ${ICO_OK} ${OK}AllowedIPs updated${NC}"
                    echo -e "  ${WARN_C}Re-download client config to apply${NC}"
                else
                    echo -e "  ${DIM2}No change${NC}"
                fi
                PAUSE ;;

            h) # Manage Hostname
                echo ""
                _cur_hr="$(get_peer_hostrecord_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
                _peer_ip_bare="${_aip%%/*}"
                if [ -n "$_cur_hr" ]; then
                    echo -e "  ${A}Current:${NC} ${W}${_cur_hr}${NC} → ${W}${_peer_ip_bare}${NC}"
                    echo ""
                    echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Change${NC} hostname"
                    echo -e "  ${B}2${NC} ${DIM2}›${NC} ${ERR}Remove${NC} hostname"
                    echo -e "  ${DIM2}Enter › Cancel${NC}"
                    echo ""
                    echo -ne "  ${A}>${NC} "; read -r _h_choice || true
                    sigint_caught && { PAUSE; continue; }
                    case "${_h_choice:-}" in
                        1)  _h_domain="$(sanitize_hostname "$_iface").$(get_lan_domain)"
                            while true; do
                                prompt _h_new "Hostname (without .${_h_domain})" "" || break
                                sigint_caught && break
                                [ -z "$_h_new" ] && break
                                _h_san="$(sanitize_hostname "$_h_new")"
                                [ -z "$_h_san" ] && { warn "Invalid hostname"; continue; }
                                _h_fqdn="${_h_san}.${_h_domain}"
                                [ "$_h_fqdn" = "$_cur_hr" ] && { echo -e "  ${DIM2}No change${NC}"; break; }
                                if hostrecord_fqdn_exists "$_h_fqdn"; then
                                    warn "Hostname '${_h_fqdn}' already exists"
                                    continue
                                fi
                                _h_idx="$(find_hostrecord "$_iface" "$_desc")"
                                uci set "dhcp.@hostrecord[$_h_idx].name=${_h_fqdn}"
                                uci commit dhcp
                                /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
                                echo -e "  ${ICO_OK} ${OK}Hostname changed:${NC} ${_h_fqdn}"
                                break
                            done ;;
                        2)  remove_peer_hostrecord "$_iface" "$_desc" ;;
                    esac
                else
                    echo -e "  ${A}No DNS record for this peer${NC}"
                    echo ""
                    _h_auto="$(build_peer_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
                    _h_domain="$(sanitize_hostname "$_iface").$(get_lan_domain)"
                    echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}${_h_auto}${NC}"
                    echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(enter hostname.${_h_domain})${NC}"
                    echo -e "  ${DIM2}Enter › Cancel${NC}"
                    echo ""
                    echo -ne "  ${A}>${NC} "; read -r _h_choice || true
                    sigint_caught && { PAUSE; continue; }
                    _h_fqdn=""
                    case "${_h_choice:-}" in
                        1)  _h_fqdn="$_h_auto" ;;
                        2)  while true; do
                                prompt _h_custom "Hostname (without .${_h_domain})" "" || break
                                sigint_caught && break
                                [ -z "$_h_custom" ] && break
                                _h_san="$(sanitize_hostname "$_h_custom")"
                                [ -z "$_h_san" ] && { warn "Invalid hostname"; continue; }
                                _h_fqdn="${_h_san}.${_h_domain}"
                                if hostrecord_fqdn_exists "$_h_fqdn"; then
                                    warn "Hostname '${_h_fqdn}' already exists"
                                    _h_fqdn=""
                                    continue
                                fi
                                break
                            done ;;
                    esac
                    if [ -n "$_h_fqdn" ]; then
                        if hostrecord_fqdn_exists "$_h_fqdn"; then
                            warn "Hostname '${_h_fqdn}' already exists"
                        else
                            check_hostrecord_warnings "$_iface" || true
                            add_peer_hostrecord "$_iface" "$_desc" "$_aip" "$_h_fqdn"
                        fi
                    fi
                fi
                PAUSE ;;

            k) # Edit Keepalive
                echo ""
                _cur_ka="$(uci -q get "network.@${_pt}[$_idx].persistent_keepalive" || echo "25")"
                echo -e "  ${A}Current:${NC} ${W}${_cur_ka}s${NC}"
                echo -e "  ${DIM2}0 = off, 25 = recommended for NAT${NC}"
                prompt _new_ka "Keepalive" "$_cur_ka" || continue
                sigint_caught && continue
                case "$_new_ka" in *[!0-9]*) warn "Must be numeric"; PAUSE; continue ;; esac
                if [ "$_new_ka" != "$_cur_ka" ]; then
                    confirm "Change keepalive ${_cur_ka}s → ${_new_ka}s?" "y" || continue
                    uci set "network.@${_pt}[$_idx].persistent_keepalive=$_new_ka"
                    uci commit network
                    echo -e "  ${B}Restarting${NC} ${_iface}..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    ifup "$_iface" >/dev/null 2>&1 || true
                    echo -e "  ${ICO_OK} ${OK}Keepalive updated to ${_new_ka}s${NC}"
                    echo -e "  ${WARN_C}Re-download client config to apply${NC}"
                else
                    echo -e "  ${DIM2}No change${NC}"
                fi
                PAUSE ;;

            "") crumb_pop; return ;;
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
    echo -e "  ${V}Peers${NC}  ${DIM2}${_iface}${NC}"
    echo ""

    _pi=0; _found=0
    while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
        _found=1; _n=$((_pi + 1))
        _desc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "(unnamed)")"
        _aip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "?")"
        _pub="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"

        _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"
        if [ "$_pdis" = "1" ]; then
            echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${ICO_DIS} ${DIM}${_desc}${NC}  ${DIM}${_aip}${NC}"
        else
            _hs="$(get_peer_handshake "$_iface" "$_pub")"
            _hs_sec=9999
            if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                _hs_sec="$(awg show "$_iface" 2>/dev/null | awk -v pk="$_pub" '
                    /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                        sub(/.*latest handshake: /,"");t=0;
                        for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                            if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                            else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                        print t;exit}' 2>/dev/null)"
                if [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null; then
                    echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${ICO_ON} ${W}${_desc}${NC}  ${DIM2}${_aip}${NC}"
                else
                    echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${ICO_OFF} ${W}${_desc}${NC}  ${DIM2}last: ${WARN_C}${_hs}${NC}  ${DIM2}${_aip}${NC}"
                fi
            else
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${ICO_OFF} ${W}${_desc}${NC}  ${DIM2}${_aip}${NC}"
            fi
        fi
        _pi=$((_pi + 1))
    done

    if [ "$_found" -eq 0 ]; then
        echo -e "  ${DIM2}No peers yet. Use 'Add Peer' to create one.${NC}"
        PAUSE
        return
    fi

    echo ""
    echo -e "  ${DIM2}Enter › Back${NC}"
    echo ""
    echo -ne "  ${A}>${NC} " && read_choice _peer_sel
    sigint_caught && return
    [ -z "${_peer_sel:-}" ] && return

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
    echo -e "  ${DIM2}(Ctrl+C = cancel)${NC}"
    echo ""
    while true; do
        prompt PEER_NAME "Peer name" "" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        [ -z "${PEER_NAME:-}" ] && continue
        validate_name "$PEER_NAME" || continue
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
    _iface_subnet="$(network_base_from_cidr "$_addr")"

    _peer_ip="$(pick_free_ip "$_iface" "$_prefix")"

    # Validate peer IP belongs to interface subnet
    _peer_ip_bare="${_peer_ip%/*}"
    if ! cidr_contains_ip "$_iface_subnet" "$_peer_ip_bare"; then
        die "Generated peer IP $_peer_ip is outside interface subnet $_iface_subnet"
    fi
    echo -e "  ${ICO_OK} ${OK}Assigned IP:${NC} $_peer_ip ${DIM2}(subnet: ${_iface_subnet})${NC}"

    # Endpoint (WAN IP auto-detect)
    _endpoint_host="$(detect_wan_ip || true)"
    if [ -z "$_endpoint_host" ]; then
        prompt _endpoint_host "Could not detect WAN IP — enter manually" ""
    else
        echo -e "  ${OK}WAN IP (endpoint):${NC} $_endpoint_host"
        if ! confirm "Use this address?" "y"; then
            prompt _endpoint_host "Enter endpoint address" "$_endpoint_host"
        fi
    fi

    _port="$(uci -q get "network.${_iface}.listen_port" || echo "51820")"

    # DNS from interface
    _dns="$(uci -q get "network.${_iface}.dns" || true)"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "1.1.1.1")"
    echo -e "  ${OK}DNS:${NC} $_dns"

    _keepalive="25"

    # MTU
    _mtu="$(uci -q get "network.${_iface}.mtu" || echo "1280")"

    # Detect forwarding capabilities and interface existence
    _vpn_zone="$(find_zone_for_interface "$_iface" 2>/dev/null || true)"
    _has_wan_fwd=0; _has_lan_fwd=0
    if [ -n "$_vpn_zone" ]; then
        forwarding_exists "$_vpn_zone" "wan" && _has_wan_fwd=1
        forwarding_exists "$_vpn_zone" "lan" && _has_lan_fwd=1
    fi

    # Verify actual network interfaces exist
    _wan_proto="$(uci -q get "network.wan.proto" || true)"
    _lan_proto="$(uci -q get "network.lan.proto" || true)"
    [ -z "$_wan_proto" ] && _has_wan_fwd=0
    [ -z "$_lan_proto" ] && _has_lan_fwd=0

    # Warn about missing capabilities
    if [ "$_has_wan_fwd" = "0" ] && [ "$_has_lan_fwd" = "0" ]; then
        warn "No LAN or WAN access from this interface"
        warn "Client will only have access to the VPN subnet"
    else
        [ "$_has_wan_fwd" = "0" ] && warn "No WAN access — client will NOT have internet via VPN"
        [ "$_has_lan_fwd" = "0" ] && warn "No LAN access — client will NOT access server LAN via VPN"
    fi

    # Build LAN CIDR if LAN is available
    _lan_cidr=""
    if [ "$_has_lan_fwd" = "1" ]; then
        _lan_subnet="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
        _lan_mask="$(uci -q get network.lan.netmask 2>/dev/null || true)"
        if [ -n "$_lan_subnet" ] && [ -n "$_lan_mask" ]; then
            _bits=0; OLDIFS="$IFS"; IFS='.'
            for _oct in $_lan_mask; do
                case "$_oct" in
                    255) _bits=$((_bits+8)) ;; 254) _bits=$((_bits+7)) ;;
                    252) _bits=$((_bits+6)) ;; 248) _bits=$((_bits+5)) ;;
                    240) _bits=$((_bits+4)) ;; 224) _bits=$((_bits+3)) ;;
                    192) _bits=$((_bits+2)) ;; 128) _bits=$((_bits+1)) ;;
                esac
            done; IFS="$OLDIFS"
            _lan_cidr="$(network_base_from_cidr "${_lan_subnet}/${_bits}")"
        fi
    fi

    # Default AllowedIPs based on capabilities
    if [ "$_has_wan_fwd" = "1" ]; then
        _default_allowed="0.0.0.0/0, ::/0"
    elif [ -n "$_lan_cidr" ]; then
        _default_allowed="$_lan_cidr"
    else
        _default_allowed="$_peer_ip"
    fi

    # Routing mode — show only options matching available forwardings
    echo ""
    echo -e "  ${A}Routing mode:${NC}"
    _opt=1; _opt_lan=0; _opt_wan=0; _opt_full=0; _opt_custom=0
    if [ "$_has_lan_fwd" = "1" ] && [ "$_has_wan_fwd" = "1" ]; then
        echo -e "  ${B}${_opt}${NC} ${DIM2}›${NC} ${W}Full tunnel${NC}   ${DIM2}— all traffic via VPN (0.0.0.0/0, ::/0)${NC}"
        _opt_full=$_opt; _opt=$((_opt+1))
    fi
    if [ "$_has_lan_fwd" = "1" ] && [ -n "$_lan_cidr" ]; then
        echo -e "  ${B}${_opt}${NC} ${DIM2}›${NC} ${W}LAN only${NC}     ${DIM2}— server LAN only (${_lan_cidr})${NC}"
        _opt_lan=$_opt; _opt=$((_opt+1))
    fi
    if [ "$_has_wan_fwd" = "1" ]; then
        echo -e "  ${B}${_opt}${NC} ${DIM2}›${NC} ${W}WAN only${NC}     ${DIM2}— internet only (0.0.0.0/0, ::/0)${NC}"
        _opt_wan=$_opt; _opt=$((_opt+1))
    fi
    echo -e "  ${B}${_opt}${NC} ${DIM2}›${NC} ${W}Custom${NC}       ${DIM2}— specify AllowedIPs manually${NC}"
    _opt_custom=$_opt
    echo ""

    _routing_mode=""
    while true; do
        prompt _routing_mode "Select" "1" || return
        if [ "$_routing_mode" = "$_opt_full" ] && [ "$_opt_full" != "0" ]; then
            _client_allowed_ips="0.0.0.0/0, ::/0"; break
        elif [ "$_routing_mode" = "$_opt_lan" ] && [ "$_opt_lan" != "0" ]; then
            _client_allowed_ips="$_lan_cidr"; break
        elif [ "$_routing_mode" = "$_opt_wan" ] && [ "$_opt_wan" != "0" ]; then
            _client_allowed_ips="0.0.0.0/0, ::/0"; break
        elif [ "$_routing_mode" = "$_opt_custom" ]; then
            prompt _client_allowed_ips "AllowedIPs (comma-separated CIDRs)" "$_default_allowed" || return
            break
        else
            warn "Invalid choice"
        fi
    done
    echo -e "  ${ICO_OK} ${OK}AllowedIPs:${NC} $_client_allowed_ips"

    # PreSharedKey
    _psk=""
    if confirm "Generate PreSharedKey (extra security)?" "y"; then
        _psk="$(awg genpsk)" || die "PSK generation failed"
        echo -e "  ${ICO_OK} ${OK}PreSharedKey:${NC} generated"
    fi

    # Generate keys
    _client_priv="$(awg genkey)" || die "Key generation failed"
    _client_pub="$(printf '%s' "$_client_priv" | awg pubkey)" \
        || die "Public key derivation failed"

    _server_priv="$(uci -q get "network.${_iface}.private_key" || true)"
    [ -z "$_server_priv" ] && die "Missing interface private key"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey)"

    echo ""
    echo -e "  ${V}New peer:${NC}"
    echo -e "  ${A}Name${NC}         ${W}$PEER_NAME${NC}"
    echo -e "  ${A}IP${NC}           ${W}$_peer_ip${NC}"
    echo -e "  ${A}Endpoint${NC}     ${W}${_endpoint_host}:${_port}${NC}"
    echo -e "  ${A}DNS${NC}          ${W}$_dns${NC}"
    echo -e "  ${A}MTU${NC}          ${W}$_mtu${NC}"
    echo -e "  ${A}AllowedIPs${NC}   ${W}$_client_allowed_ips${NC}"
    [ -n "$_psk" ] && echo -e "  ${A}PSK${NC}          ${W}yes${NC}"
    echo ""

    confirm "Create peer?" "y" || return

    echo -e "  ${B}Adding${NC} peer ${W}$PEER_NAME${NC}..."
    _sec="$(uci add network "$_pt")"
    uci set "network.${_sec}.public_key=$_client_pub"
    uci set "network.${_sec}.private_key=$_client_priv"
    uci set "network.${_sec}.route_allowed_ips=1"
    uci set "network.${_sec}.allowed_ips=$_peer_ip"
    uci set "network.${_sec}.persistent_keepalive=$_keepalive"
    uci set "network.${_sec}.description=$PEER_NAME"
    [ -n "$_psk" ] && uci set "network.${_sec}.preshared_key=$_psk"
    uci set "network.${_sec}.client_allowed_ips=$_client_allowed_ips"

    uci commit network

    # Build client config
    _conf="[Interface]
PrivateKey = $_client_priv
Address = $_peer_ip
DNS = $_dns
MTU = $_mtu

[Peer]
PublicKey = $_server_pub
AllowedIPs = $_client_allowed_ips
Endpoint = ${_endpoint_host}:${_port}
PersistentKeepAlive = $_keepalive"
    [ -n "$_psk" ] && _conf="${_conf}
PresharedKey = $_psk"

    echo ""
    echo -e "  ${ICO_OK} ${OK}Peer '${PEER_NAME}' created${NC}"
    echo -e "  ${B}Restarting${NC} ${_iface}..."
    ifdown "$_iface" >/dev/null 2>&1 || true
    ifup "$_iface" >/dev/null 2>&1 || true
    echo -e "  ${ICO_OK} ${OK}Done${NC}"

    # Offer DNS hostrecord
    _hr_auto="$(build_peer_fqdn "$_iface" "$PEER_NAME" 2>/dev/null || true)"
    if [ -n "$_hr_auto" ]; then
        _hr_domain="$(sanitize_hostname "$_iface").$(get_lan_domain)"
        echo ""
        echo -e "  ${A}Local DNS record:${NC}"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}${_hr_auto}${NC}"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(enter hostname.${_hr_domain})${NC}"
        echo -e "  ${DIM2}Enter › Skip${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "; read -r _hr_choice || true
        sigint_caught && _hr_choice=""
        case "${_hr_choice:-}" in
            1)  _hr_fqdn="$_hr_auto" ;;
            2)  while true; do
                    prompt _hr_custom "Hostname (without .${_hr_domain})" "" || { _hr_fqdn=""; break; }
                    sigint_caught && { _hr_fqdn=""; break; }
                    [ -z "$_hr_custom" ] && { _hr_fqdn=""; break; }
                    _hr_san="$(sanitize_hostname "$_hr_custom")"
                    [ -z "$_hr_san" ] && { warn "Invalid hostname"; continue; }
                    _hr_fqdn="${_hr_san}.${_hr_domain}"
                    if hostrecord_fqdn_exists "$_hr_fqdn"; then
                        warn "Hostname '${_hr_fqdn}' already exists"
                        continue
                    fi
                    break
                done ;;
            *)  _hr_fqdn="" ;;
        esac
        if [ -n "$_hr_fqdn" ]; then
            if hostrecord_fqdn_exists "$_hr_fqdn"; then
                warn "Hostname '${_hr_fqdn}' already exists — skipping"
            else
                check_hostrecord_warnings "$_iface" || true
                add_peer_hostrecord "$_iface" "$PEER_NAME" "$_peer_ip" "$_hr_fqdn"
            fi
        fi
    fi

    PAUSE

    # Find index of newly created peer for navigation
    _new_idx=0
    while uci -q get "network.@${_pt}[$_new_idx]" >/dev/null 2>&1; do
        _nd="$(uci -q get "network.@${_pt}[$_new_idx].description" || true)"
        if [ "$_nd" = "$PEER_NAME" ]; then
            CREATED_PEER_IDX="$_new_idx"
            CREATED_PEER_NAME="$PEER_NAME"
            return 0
        fi
        _new_idx=$((_new_idx + 1))
    done
}

do_manage_interface() {
    _iface="$1"
    crumb_push "Interfaces"; crumb_push "$_iface"
    while true; do
        clear
        crumb_show
        uci_network_exists "$_iface" || { crumb_pop; crumb_pop; return; }

        _addr="$(uci -q get "network.${_iface}.addresses" || echo "n/a")"
        _port="$(uci -q get "network.${_iface}.listen_port" || echo "n/a")"
        _dns="$(uci  -q get "network.${_iface}.dns" || echo "n/a")"
        _mtu="$(uci -q get "network.${_iface}.mtu" || echo "n/a")"
        _zone="$(find_zone_for_interface "$_iface" 2>/dev/null || echo "none")"
        _peer_count="$(count_peers "$_iface")"
        _disabled="$(uci -q get "network.${_iface}.disabled" || echo "0")"

        _fwd_lan_on=0; _fwd_wan_on=0
        _fwd_lan="${ICO_ERR}"; forwarding_exists "$_zone" "lan" && { _fwd_lan="${ICO_OK}"; _fwd_lan_on=1; }
        _fwd_wan="${ICO_ERR}"; forwarding_exists "$_zone" "wan" && { _fwd_wan="${ICO_OK}"; _fwd_wan_on=1; }

        # Public key (truncated)
        _srv_priv="$(uci -q get "network.${_iface}.private_key" || true)"
        _srv_pub=""
        if [ -n "$_srv_priv" ] && have_cmd awg; then
            _srv_pub="$(printf '%s' "$_srv_priv" | awg pubkey 2>/dev/null || true)"
        fi
        _srv_pub_short=""
        if [ -n "$_srv_pub" ]; then
            _srv_pub_short="$(printf '%s' "$_srv_pub" | cut -c1-12)…"
        fi

        if [ "$_disabled" = "1" ]; then
            _st_ico="${ICO_DIS}"; _st_txt="${DIM2}Disabled${NC}"
        elif ! interface_device_exists "$_iface"; then
            _st_ico="${ICO_OFF}"; _st_txt="${ERR}Down${NC}"
        else
            _st_ico="${ICO_ON}"; _st_txt="${OK}Up${NC}"
        fi

        # Uptime via ifstatus
        _uptime_str=""
        if [ "$_disabled" != "1" ] && interface_device_exists "$_iface" && have_cmd ifstatus; then
            _up_val="$(ifstatus "$_iface" 2>/dev/null | sed -n 's/.*"uptime"[^0-9]*\([0-9]*\).*/\1/p' | head -n1)"
            if [ -n "$_up_val" ] && [ "$_up_val" -gt 0 ] 2>/dev/null; then
                _uptime_str="$(fmt_duration "$_up_val")"
            fi
        fi

        # Total Rx/Tx across all peers
        _total_rx=""; _total_tx=""
        if [ "$_disabled" != "1" ] && interface_device_exists "$_iface" && have_cmd awg; then
            _awg_dump="$(awg show "$_iface" 2>/dev/null || true)"
            if [ -n "$_awg_dump" ]; then
                _total_rx="$(echo "$_awg_dump" | awk '/transfer:/{
                    sub(/.*transfer: /,""); sub(/ received.*/,""); print; exit}')"
                _total_tx="$(echo "$_awg_dump" | awk '/transfer:/{
                    sub(/.*, /,""); sub(/ sent.*/,""); print; exit}')"
                # Sum all peers if multiple
                _rx_sum="$(echo "$_awg_dump" | awk 'BEGIN{t=0} /transfer:/{
                    sub(/.*transfer: /,""); split($0,a,",");
                    v=$1+0; u=$2;
                    if(u~/GiB/)t+=v*1073741824; else if(u~/MiB/)t+=v*1048576;
                    else if(u~/KiB/)t+=v*1024; else t+=v
                } END{
                    if(t>=1073741824) printf "%.1f GiB",t/1073741824;
                    else if(t>=1048576) printf "%.1f MiB",t/1048576;
                    else if(t>=1024) printf "%.1f KiB",t/1024;
                    else printf "%d B",t}')"
                _tx_sum="$(echo "$_awg_dump" | awk 'BEGIN{t=0} /transfer:/{
                    sub(/.*transfer: /,""); sub(/.*,[ ]*/,""); sub(/ sent/,"");
                    v=$1+0; u=$2;
                    if(u~/GiB/)t+=v*1073741824; else if(u~/MiB/)t+=v*1048576;
                    else if(u~/KiB/)t+=v*1024; else t+=v
                } END{
                    if(t>=1073741824) printf "%.1f GiB",t/1073741824;
                    else if(t>=1048576) printf "%.1f MiB",t/1048576;
                    else if(t>=1024) printf "%.1f KiB",t/1024;
                    else printf "%d B",t}')"
            fi
        fi

        # Podkop status
        # Detect podkop state (sets PK_* globals)
        detect_podkop_state "$_iface"

        _ep_override="$(uci -q get "network.${_iface}.endpoint_host" || true)"
        _ep_display="${_ep_override:-auto}"
        _dns_chain="$(dns_chain_label "$_iface")"
        if [ -n "$_dns_chain" ]; then _dns_chain="  ${_dns_chain}"; fi

        box_top 44
        box_line "  ${_st_ico} ${W}${_iface}${NC}  ${_st_txt}"
        box_sep 44
        box_line "  ${A}Address${NC}      ${W}${_addr}${NC}"
        box_line "  ${A}Endpoint${NC}     ${W}${_ep_display}:${_port}${NC}"
        box_line "  ${A}MTU${NC}          ${W}${_mtu}${NC}"
        box_line "  ${A}DNS${NC}          ${W}${_dns}${NC}${_dns_chain}"
        if [ -n "$_srv_pub_short" ]; then
            box_line "  ${A}Public Key${NC}   ${DIM2}${_srv_pub_short}${NC}"
        fi
        box_sep 44
        box_line "  ${A}FW Zone${NC}      ${W}${_zone}${NC}"
        box_line "  ${A}Routing${NC}      ${_fwd_lan} LAN  ${_fwd_wan} WAN"
        if [ "${PK_INSTALLED:-0}" -eq 1 ]; then
            if [ "$PK_LINKED" -eq 0 ]; then
                box_line "  ${A}Podkop${NC}       ${DIM2}Not linked${NC}"
            elif [ "$SB_RUNNING" -eq 1 ] && [ "$SB_DNS" -eq 1 ] && [ "$DM_OK" -eq 1 ]; then
                box_line "  ${A}Podkop${NC}       ${OK}Active${NC}  ${DIM2}Sing-Box ✓  dns ✓${NC}"
            elif [ "$SB_RUNNING" -eq 1 ] && [ "$SB_DNS" -eq 1 ]; then
                box_line "  ${A}Podkop${NC}       ${OK}Active${NC}  ${WARN_C}dnsmasq misconfigured${NC}"
            elif [ "$SB_RUNNING" -eq 1 ]; then
                box_line "  ${A}Podkop${NC}       ${WARN_C}Sing-Box running, DNS not listening${NC}"
            else
                box_line "  ${A}Podkop${NC}       ${ERR}Linked but Sing-Box stopped${NC}"
            fi
        elif [ "${SB_DNS:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 1 ]; then
            box_line "  ${A}Sing-Box${NC}     ${OK}Active${NC}  ${DIM2}dnsmasq → 127.0.0.42${NC}"
        elif [ "${SB_RUNNING:-0}" -eq 1 ]; then
            box_line "  ${A}Sing-Box${NC}     ${WARN_C}Running${NC}  ${DIM2}DNS not configured${NC}"
        fi
        if [ -n "$_uptime_str" ] || [ -n "$_rx_sum" ]; then
            box_sep 44
            if [ -n "$_uptime_str" ]; then
                box_line "  ${A}Uptime${NC}       ${W}${_uptime_str}${NC}"
            fi
            if [ -n "$_rx_sum" ]; then
                box_line "  ${A}Traffic${NC}      ${DIM2}↓${NC} ${W}${_rx_sum}${NC}  ${DIM2}↑${NC} ${W}${_tx_sum}${NC}"
            fi
        fi
        box_bot 44

        # ── Inline diagnostics ──
        _warnings=0
        if [ "$_disabled" != "1" ]; then
            if ! interface_device_exists "$_iface"; then
                echo -e "  ${ICO_WARN} ${WARN_C}Interface device is down${NC}"
                _warnings=1
            fi
            if [ -n "$_port" ] && ! port_in_use "$_port"; then
                echo -e "  ${ICO_WARN} ${WARN_C}Port ${_port} is not listening${NC}"
                _warnings=1
            fi
            if [ "$_zone" = "none" ]; then
                echo -e "  ${ICO_WARN} ${WARN_C}No firewall zone assigned${NC}"
                _warnings=1
            elif [ "$_fwd_lan_on" -eq 0 ] && [ "$_fwd_wan_on" -eq 0 ]; then
                echo -e "  ${ICO_WARN} ${WARN_C}No forwarding rules — peers have no network access${NC}"
                _warnings=1
            fi
        fi
        if [ "$_warnings" -eq 1 ]; then echo ""; else echo ""; fi

        if [ "$_disabled" = "1" ]; then
            _toggle_label="${OK}Enable${NC} Interface"
        else
            _toggle_label="${ERR}Disable${NC} Interface"
        fi
        _is_l="$(uci -q get "network.${_iface}._liminal_iface" || true)"
        [ -n "$_is_l" ] && _is_l="1" || _is_l="0"

        # ── Inline peer list ──
        _pt="amneziawg_${_iface}"
        _PC="\\033[10G"  # Name column
        _PS="\\033[28G"  # Status/info column
        echo -e "  ${DIM2}Peers${NC}"
        _pi=0; _peer_found=0
        while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
            _peer_found=1; _pn=$((_pi + 1))
            _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "(unnamed)")"
            _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "?")"
            _ppub="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"
            _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"
            _phost="${_paip%%/*}"; _phost="${_phost##*.}"

            if [ "$_pdis" = "1" ]; then
                echo -e "  ${B}${_pn}${NC} ${DIM2}›${NC} ${ICO_DIS}${_PC}${DIM2}${_pdesc}${NC}${_PS}${DIM2}#${_phost}${NC}"
            elif [ "$_disabled" != "1" ] && interface_device_exists "$_iface"; then
                _hs="$(get_peer_handshake "$_iface" "$_ppub")"
                _hs_sec=9999
                if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                    _hs_sec="$(awg show "$_iface" 2>/dev/null | awk -v pk="$_ppub" '
                        /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                            sub(/.*latest handshake: /,"");t=0;
                            for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                                if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                                else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                            print t;exit}' 2>/dev/null)"
                    if [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null; then
                        echo -e "  ${B}${_pn}${NC} ${DIM2}›${NC} ${ICO_ON}${_PC}${W}${_pdesc}${NC}${_PS}${DIM2}#${_phost}${NC}"
                    else
                        echo -e "  ${B}${_pn}${NC} ${DIM2}›${NC} ${ICO_OFF}${_PC}${W}${_pdesc}${NC}${_PS}${DIM2}#${_phost}  ${WARN_C}${_hs}${NC}"
                    fi
                else
                    echo -e "  ${B}${_pn}${NC} ${DIM2}›${NC} ${ICO_OFF}${_PC}${W}${_pdesc}${NC}${_PS}${DIM2}#${_phost}${NC}"
                fi
            else
                echo -e "  ${B}${_pn}${NC} ${DIM2}›${NC} ${ICO_OFF}${_PC}${W}${_pdesc}${NC}${_PS}${DIM2}#${_phost}${NC}"
            fi
            _pi=$((_pi + 1))
        done
        [ "$_peer_found" -eq 0 ] && echo -e "  ${DIM2}No peers yet${NC}"
        echo -e "  ${OK}+${NC} ${DIM2}›${NC} ${W}Add${NC} Peer"
        echo ""

        # ── Settings ──
        echo -e "  ${DIM2}Settings${NC}"
        echo -e "  ${B}e${NC} ${DIM2}›${NC} ${W}Edit${NC} DNS / MTU"
        echo -e "  ${B}p${NC} ${DIM2}›${NC} ${W}Change${NC} Port"
        echo -e "  ${B}n${NC} ${DIM2}›${NC} ${W}Endpoint${NC}"

        # Forwarding toggles
        if [ "$_fwd_lan_on" -eq 1 ]; then
            echo -e "  ${B}l${NC} ${DIM2}›${NC} ${ERR}Disable${NC} LAN Forwarding"
        else
            echo -e "  ${B}l${NC} ${DIM2}›${NC} ${OK}Enable${NC} LAN Forwarding"
        fi
        if [ "$_fwd_wan_on" -eq 1 ]; then
            echo -e "  ${B}w${NC} ${DIM2}›${NC} ${ERR}Disable${NC} WAN Forwarding"
        else
            echo -e "  ${B}w${NC} ${DIM2}›${NC} ${OK}Enable${NC} WAN Forwarding"
        fi

        # Podkop toggle
        if podkop_present; then
            if podkop_has_interface "$_iface" 2>/dev/null; then
                echo -e "  ${B}k${NC} ${DIM2}›${NC} ${ERR}Unlink${NC} Podkop"
            else
                echo -e "  ${B}k${NC} ${DIM2}›${NC} ${OK}Link${NC} Podkop"
            fi
        fi
        echo ""

        # ── Info ──
        echo -e "  ${DIM2}Info${NC}"
        echo -e "  ${B}i${NC} ${DIM2}›${NC} ${W}Show${NC} Public Key"
        echo ""

        # ── Interface ──
        echo -e "  ${DIM2}Interface${NC}"
        if [ "$_is_l" = "1" ]; then
            echo -e "  ${B}m${NC} ${DIM2}›${NC} ${W}Rename${NC} Interface"
        fi
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${WARN_C}Restart${NC} Interface"
        echo -e "  ${B}t${NC} ${DIM2}›${NC} ${_toggle_label}"
        if [ "$_is_l" = "1" ]; then
            echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Delete${NC} Interface"
        fi
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice _mgmt_choice
        sigint_caught && { crumb_pop; crumb_pop; return; }

        case "${_mgmt_choice:-}" in
            +) CREATED_PEER_IDX=""; CREATED_PEER_NAME=""
                do_add_peer "$_iface"
                if [ -n "$CREATED_PEER_IDX" ]; then
                    do_peer_menu "$_iface" "$CREATED_PEER_IDX" "$CREATED_PEER_NAME"
                fi ;;

            e|E) # Edit DNS / MTU
                echo ""
                _cur_dns="$(uci -q get "network.${_iface}.dns" || echo "")"
                _cur_mtu="$(uci -q get "network.${_iface}.mtu" || echo "1280")"
                _changed=0; _mtu_changed=0; _dns_changed=0

                _new_dns=""
                if select_dns _new_dns "$_cur_dns"; then
                    if [ -n "$_new_dns" ] && [ "$_new_dns" != "$_cur_dns" ]; then
                        uci set "network.${_iface}.dns=$_new_dns"
                        _changed=1; _dns_changed=1
                    fi
                fi

                prompt _new_mtu "MTU" "$_cur_mtu" || continue
                sigint_caught && continue
                if [ -n "$_new_mtu" ] && [ "$_new_mtu" != "$_cur_mtu" ]; then
                    case "$_new_mtu" in *[!0-9]*) warn "MTU must be numeric"; PAUSE; continue ;; esac
                    uci set "network.${_iface}.mtu=$_new_mtu"
                    _changed=1; _mtu_changed=1
                fi

                if [ "$_changed" -eq 1 ]; then
                    confirm "Apply changes?" "y" || { uci revert network 2>/dev/null; echo -e "  ${DIM2}Cancelled${NC}"; PAUSE; continue; }
                    uci commit network
                    spinner_start "Restarting ${_iface}..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    ifup "$_iface" >/dev/null 2>&1 || true
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Settings updated${NC}"
                    if [ "$_mtu_changed" -eq 1 ] || [ "$_dns_changed" -eq 1 ]; then
                        echo ""
                        echo -e "  ${WARN_C}Existing peer configs contain the old values.${NC}"
                        echo -e "  ${WARN_C}Re-download configs or update clients manually.${NC}"
                    fi
                else
                    echo -e "  ${DIM2}No changes${NC}"
                fi
                PAUSE ;;

            p|P) # Change Port
                echo ""
                _cur_port="$(uci -q get "network.${_iface}.listen_port" || echo "")"
                echo -e "  ${WARN_C}All existing peer configs will need to be updated${NC}"
                echo -e "  ${WARN_C}with the new port after this change.${NC}"
                echo ""
                prompt _new_port "New port" "$_cur_port" || continue
                sigint_caught && continue
                [ "$_new_port" = "$_cur_port" ] && { echo -e "  ${DIM2}No change${NC}"; PAUSE; continue; }
                validate_port "$_new_port" || { PAUSE; continue; }
                port_in_use "$_new_port" && { warn "Port $_new_port is already in use"; PAUSE; continue; }
                confirm "Change port ${_cur_port} → ${_new_port}?" "n" || continue

                autobackup_enabled && init_backup "Port Change"
                uci set "network.${_iface}.listen_port=$_new_port"

                # Update firewall rule if exists
                _ri=0
                while uci -q get "firewall.@rule[$_ri]" >/dev/null 2>&1; do
                    _rl="$(uci -q get "firewall.@rule[$_ri]._liminal_iface" || true)"
                    if [ "$_rl" = "$_iface" ]; then
                        uci set "firewall.@rule[$_ri].dest_port=$_new_port"
                        echo -e "  ${B}Updated${NC} FW rule port"
                    fi
                    _ri=$((_ri + 1))
                done

                uci commit network
                uci commit firewall
                echo -e "  ${B}Restarting${NC} ${_iface}..."
                ifdown "$_iface" >/dev/null 2>&1 || true
                ifup "$_iface" >/dev/null 2>&1 || true
                echo -e "  ${B}Restarting${NC} firewall..."
                /etc/init.d/firewall restart >/dev/null 2>&1 || true
                echo -e "  ${ICO_OK} ${OK}Port changed to ${_new_port}${NC}"
                echo -e "  ${WARN_C}Update all peer configs with new port${NC}"
                PAUSE ;;

            n|N) # Edit Endpoint
                echo ""
                _cur_ep="$(uci -q get "network.${_iface}.endpoint_host" || true)"
                if [ -n "$_cur_ep" ]; then
                    echo -e "  ${A}Current endpoint:${NC} ${W}${_cur_ep}${NC}"
                else
                    _det_ep="$(detect_wan_ip 2>/dev/null || true)"
                    echo -e "  ${A}Auto-detected WAN IP:${NC} ${W}${_det_ep:-unknown}${NC}"
                fi
                echo ""
                echo -e "  ${DIM2}Enter a static IP or DDNS hostname.${NC}"
                echo -e "  ${DIM2}Leave empty to reset to auto-detect.${NC}"
                echo ""
                prompt _new_ep "Endpoint host (empty = cancel)" "" || continue
                sigint_caught && continue
                if [ -z "$_new_ep" ]; then
                    if [ -n "$_cur_ep" ]; then
                        confirm "Reset to auto-detect?" "n" || continue
                        uci delete "network.${_iface}.endpoint_host" 2>/dev/null || true
                        uci commit network
                        echo -e "  ${ICO_OK} ${OK}Endpoint reset to auto-detect${NC}"
                        echo -e "  ${WARN_C}Re-download client configs to apply${NC}"
                    else
                        echo -e "  ${DIM2}Cancelled${NC}"
                    fi
                elif [ "$_new_ep" != "$_cur_ep" ]; then
                    uci set "network.${_iface}.endpoint_host=$_new_ep"
                    uci commit network
                    echo -e "  ${ICO_OK} ${OK}Endpoint set to ${_new_ep}${NC}"
                    echo -e "  ${WARN_C}Re-download client configs to apply${NC}"
                else
                    echo -e "  ${DIM2}No change${NC}"
                fi
                PAUSE ;;

            l|L) # Toggle LAN forwarding
                if [ "$_fwd_lan_on" -eq 1 ]; then
                    # Remove LAN forwarding
                    _fi=0
                    while uci -q get "firewall.@forwarding[$_fi]" >/dev/null 2>&1; do
                        _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src" || true)"
                        _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" || true)"
                        _fl="$(uci -q get "firewall.@forwarding[$_fi]._liminal_iface" || true)"
                        if [ "$_fl" = "$_iface" ] && [ "$_fsrc" = "$_zone" ] && [ "$_fdst" = "lan" ]; then
                            uci delete "firewall.@forwarding[$_fi]"
                            break
                        fi
                        _fi=$((_fi + 1))
                    done
                    uci commit firewall
                    echo -e "  ${B}Restarting${NC} firewall..."
                    /etc/init.d/firewall restart >/dev/null 2>&1 || true
                    echo -e "  ${ICO_OK} ${OK}LAN forwarding disabled${NC}"
                else
                    # Add LAN forwarding
                    uci add firewall forwarding >/dev/null
                    _fwd_idx="$(uci show firewall \
                        | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1)"
                    uci set "firewall.@forwarding[$_fwd_idx].src=${_zone}"
                    uci set "firewall.@forwarding[$_fwd_idx].dest=lan"
                    uci set "firewall.@forwarding[$_fwd_idx]._liminal_iface=${_iface}"
                    uci commit firewall
                    echo -e "  ${B}Restarting${NC} firewall..."
                    /etc/init.d/firewall restart >/dev/null 2>&1 || true
                    echo -e "  ${ICO_OK} ${OK}LAN forwarding enabled${NC}"
                fi
                PAUSE ;;

            w|W) # Toggle WAN forwarding
                if [ "$_fwd_wan_on" -eq 1 ]; then
                    _fi=0
                    while uci -q get "firewall.@forwarding[$_fi]" >/dev/null 2>&1; do
                        _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src" || true)"
                        _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" || true)"
                        _fl="$(uci -q get "firewall.@forwarding[$_fi]._liminal_iface" || true)"
                        if [ "$_fl" = "$_iface" ] && [ "$_fsrc" = "$_zone" ] && [ "$_fdst" = "wan" ]; then
                            uci delete "firewall.@forwarding[$_fi]"
                            break
                        fi
                        _fi=$((_fi + 1))
                    done
                    uci commit firewall
                    echo -e "  ${B}Restarting${NC} firewall..."
                    /etc/init.d/firewall restart >/dev/null 2>&1 || true
                    echo -e "  ${ICO_OK} ${OK}WAN forwarding disabled${NC}"
                else
                    uci add firewall forwarding >/dev/null
                    _fwd_idx="$(uci show firewall \
                        | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1)"
                    uci set "firewall.@forwarding[$_fwd_idx].src=${_zone}"
                    uci set "firewall.@forwarding[$_fwd_idx].dest=wan"
                    uci set "firewall.@forwarding[$_fwd_idx]._liminal_iface=${_iface}"
                    uci commit firewall
                    ensure_wan_masq
                    echo -e "  ${B}Restarting${NC} firewall..."
                    /etc/init.d/firewall restart >/dev/null 2>&1 || true
                    echo -e "  ${ICO_OK} ${OK}WAN forwarding enabled${NC}"
                fi
                PAUSE ;;

            k|K) # Toggle Podkop
                if podkop_present; then
                    if podkop_has_interface "$_iface" 2>/dev/null; then
                        remove_podkop_interface "$_iface"
                        echo -e "  ${B}Restarting${NC} Podkop..."
                        [ -x /etc/init.d/podkop ] && /etc/init.d/podkop restart >/dev/null 2>&1 || true
                        echo -e "  ${ICO_OK} ${OK}Podkop unlinked${NC}"
                    else
                        add_podkop_interface "$_iface"
                        echo -e "  ${B}Restarting${NC} Podkop..."
                        [ -x /etc/init.d/podkop ] && /etc/init.d/podkop restart >/dev/null 2>&1 || true
                        echo -e "  ${ICO_OK} ${OK}Podkop linked${NC}"
                    fi
                    podkop_refresh
                    PAUSE
                fi ;;

            i|I) # Show Public Key
                echo ""
                if [ -n "$_srv_pub" ]; then
                    echo -e "  ${A}Public Key:${NC}"
                    echo "  $_srv_pub"
                else
                    echo -e "  ${DIM2}Could not derive public key${NC}"
                fi
                PAUSE ;;

            n|N) # Show WAN IP
                echo ""
                spinner_start "Detecting WAN IP..."
                _wan="$(detect_wan_ip 2>/dev/null || true)"
                spinner_stop
                if [ -n "$_wan" ]; then
                    echo -e "  ${A}WAN IP:${NC} ${W}${_wan}${NC}"
                    echo -e "  ${A}Endpoint:${NC} ${W}${_wan}:${_port}${NC}"
                else
                    echo -e "  ${WARN_C}Could not detect WAN IP${NC}"
                fi
                PAUSE ;;

            r|R) spinner_start "Restarting ${_iface}..."
                ifdown "$_iface" >/dev/null 2>&1 || true
                ifup "$_iface" >/dev/null 2>&1 || true
                spinner_stop
                echo -e "  ${ICO_OK} ${OK}Done${NC}"
                PAUSE ;;
            t|T) if [ "$_disabled" = "1" ]; then
                    uci delete "network.${_iface}.disabled" 2>/dev/null || true
                    uci commit network
                    spinner_start "Enabling ${_iface}..."
                    ifup "$_iface" >/dev/null 2>&1 || true
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Interface enabled${NC}"
                else
                    uci set "network.${_iface}.disabled=1"
                    uci commit network
                    spinner_start "Disabling ${_iface}..."
                    ifdown "$_iface" >/dev/null 2>&1 || true
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Interface disabled${NC}"
                fi
                PAUSE ;;
            m|M) if [ "$_is_l" = "1" ]; then
                    RENAMED_IFACE=""
                    do_rename_interface "$_iface" && [ -n "$RENAMED_IFACE" ] && {
                        _iface="$RENAMED_IFACE"
                        crumb_pop; crumb_pop
                        crumb_push "Interfaces"; crumb_push "$_iface"
                    }
                fi ;;
            d|D) if [ "$_is_l" = "1" ]; then do_delete_interface "$_iface" && { crumb_pop; crumb_pop; return; }; fi ;;
            "") crumb_pop; crumb_pop; return ;;
            *)  # Numeric = peer selection
                _sel_idx=$((_mgmt_choice - 1)) 2>/dev/null || continue
                _sel_desc="$(uci -q get "network.@${_pt}[$_sel_idx].description" 2>/dev/null || true)"
                [ -n "$_sel_desc" ] && do_peer_menu "$_iface" "$_sel_idx" "$_sel_desc" ;;
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
        _is_l="$(uci -q get "network.${iface}._liminal_iface" || true)"
        [ -n "$_is_l" ] || _other="${_other} ${iface}"
    done
    _other="${_other# }"

    if [ -z "$_liminal" ] && [ -z "$_other" ]; then
        echo -e "  ${DIM2}No interfaces found${NC}"
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
        echo -e "  ${DIM2}Liminal Interfaces${NC}"
        for iface in $_liminal; do
            _n=$((_n + 1))
            _all_list="${_all_list} ${iface}"
            _peer_count="$(count_peers "$iface")"
            if interface_device_exists "$iface"; then
                _active_count="$(count_active_peers "$iface")"
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${W}${iface}${NC}  ${DIM}·${NC}  Active: ${OK}${_active_count}${NC} of ${_peer_count}"
            else
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${W}${iface}${NC}  ${DIM}·${NC}  Peers: ${_peer_count}  ${DIM}·${NC}  ${ERR}Down${NC}"
            fi
        done
    fi

    if [ -n "$_other" ]; then
        echo ""
        echo -e "  ${DIM2}Non-Liminal Interfaces${NC}"
        for iface in $_other; do
            _n=$((_n + 1))
            _all_list="${_all_list} ${iface}"
            _peer_count="$(count_peers "$iface")"
            if interface_device_exists "$iface"; then
                _active_count="$(count_active_peers "$iface")"
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${DIM2}${iface}${NC}  ${DIM}·${NC}  Active: ${OK}${_active_count}${NC} of ${_peer_count}"
            else
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${DIM2}${iface}${NC}  ${DIM}·${NC}  Peers: ${_peer_count}  ${DIM}·${NC}  ${ERR}Down${NC}"
            fi
        done
    fi

    echo ""
    echo -e "  ${DIM2}Enter › Back${NC}"
    echo ""
    echo -ne "  ${A}>${NC} " && read LIST_CHOICE

    [ -z "${LIST_CHOICE:-}" ] && return

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
#  RENAME INTERFACE (called from inside interface management)
# ═════════════════════════════════════════════════════════════════════

do_rename_interface() {
    _old="$1"
    echo ""
    echo -e "  ${A}Current name:${NC} ${W}${_old}${NC}"
    echo -e "  ${DIM2}(Ctrl+C = cancel)${NC}"
    echo ""

    # ── Prompt for new name ──
    while true; do
        prompt _new "New interface name" "" || return 1
        sigint_caught && return 1
        [ -z "$_new" ] && { echo -e "  ${DIM2}Cancelled${NC}"; return 1; }
        [ "$_new" = "$_old" ] && { warn "Same as current name"; continue; }
        validate_ifname "$_new" || continue
        uci_network_exists "$_new"     && { warn "Interface '$_new' already exists"; continue; }
        interface_device_exists "$_new" && { warn "Device '$_new' already exists"; continue; }
        break
    done

    _old_zone="$(find_zone_for_interface "$_old" 2>/dev/null || true)"
    _old_port="$(uci -q get "network.${_old}.listen_port" || true)"
    _has_podkop=0
    podkop_present && podkop_has_interface "$_old" 2>/dev/null && _has_podkop=1

    # ── Generate new zone & rule names ──
    _new_zone="$(generate_zone_name "$_new")"
    _new_rule="Allow-AWG-${_new}"
    rule_exists_by_name "$_new_rule" && _new_rule="$(generate_rule_name "$_new")"

    # ── Summary ──
    echo ""
    echo -e "  ${A}Will be renamed:${NC}"
    echo -e "  ${B}•${NC} Interface        ${W}${_old}${NC} → ${OK}${_new}${NC}"
    echo -e "  ${B}•${NC} Peer sections    ${W}amneziawg_${_old}${NC} → ${OK}amneziawg_${_new}${NC}"
    if [ -n "$_old_zone" ]; then
        echo -e "  ${B}•${NC} FW Zone          ${W}${_old_zone}${NC} → ${OK}${_new_zone}${NC}"
        echo -e "  ${B}•${NC} FW Forwardings   src=${W}${_old_zone}${NC} → src=${OK}${_new_zone}${NC}"
    fi
    if [ -n "$_old_port" ]; then
        echo -e "  ${B}•${NC} FW Rule          ${W}Allow-AWG-${_old}${NC} → ${OK}${_new_rule}${NC}"
    fi
    if [ "$_has_podkop" -eq 1 ]; then
        echo -e "  ${B}•${NC} Podkop           ${W}${_old}${NC} → ${OK}${_new}${NC}"
    fi
    echo ""

    confirm "Proceed with rename?" "n" || { echo -e "  ${DIM2}Cancelled${NC}"; return 1; }

    init_backup "Pre-Interface Rename"

    spinner_start "Stopping ${_old}..."
    ifdown "$_old" >/dev/null 2>&1 || true
    spinner_stop

    # ── 1. Copy network interface ──
    echo -e "  ${B}Creating${NC} new interface ${W}${_new}${NC}"
    uci set "network.${_new}=interface"
    # Copy all known fields from old to new
    for _field in proto private_key listen_port mtu dns endpoint_host disabled; do
        _val="$(uci -q get "network.${_old}.${_field}" || true)"
        [ -n "$_val" ] && uci set "network.${_new}.${_field}=${_val}"
    done
    uci set "network.${_new}._liminal_iface=${_new}"
    # Copy list fields (addresses)
    for _addr_val in $(uci -q get "network.${_old}.addresses" 2>/dev/null || true); do
        uci add_list "network.${_new}.addresses=${_addr_val}"
    done

    # ── 2. Copy all peers ──
    _old_pt="amneziawg_${_old}"
    _new_pt="amneziawg_${_new}"
    _pi=0
    while uci -q get "network.@${_old_pt}[$_pi]" >/dev/null 2>&1; do
        _sec="$(uci add network "$_new_pt")"
        for _pf in public_key private_key preshared_key route_allowed_ips allowed_ips \
                   persistent_keepalive description disabled client_allowed_ips endpoint_host; do
            _pv="$(uci -q get "network.@${_old_pt}[$_pi].${_pf}" || true)"
            [ -n "$_pv" ] && uci set "network.${_sec}.${_pf}=${_pv}"
        done
        _pi=$((_pi + 1))
    done
    echo -e "  ${B}Copied${NC} ${_pi} peer(s)"

    # ── 3. Delete old peers & interface ──
    while uci -q get "network.@${_old_pt}[0]" >/dev/null 2>&1; do
        uci delete "network.@${_old_pt}[0]"
    done
    uci delete "network.${_old}"

    # ── 4. Rename firewall zone ──
    if [ -n "$_old_zone" ]; then
        _zi="$(find_zone_index "$_old_zone" || true)"
        if [ -n "$_zi" ]; then
            _zl="$(uci -q get "firewall.@zone[$_zi]._liminal_iface" || true)"
            if [ "$_zl" = "$_old" ]; then
                echo -e "  ${B}Renaming${NC} FW zone ${W}${_old_zone}${NC} → ${OK}${_new_zone}${NC}"
                uci set "firewall.@zone[$_zi].name=${_new_zone}"
                uci del_list "firewall.@zone[$_zi].network=${_old}" 2>/dev/null || true
                uci add_list "firewall.@zone[$_zi].network=${_new}"
                uci set "firewall.@zone[$_zi]._liminal_iface=${_new}"
            else
                # Non-liminal zone: just update network list
                uci del_list "firewall.@zone[$_zi].network=${_old}" 2>/dev/null || true
                uci add_list "firewall.@zone[$_zi].network=${_new}"
            fi
        fi
    fi

    # ── 5. Update forwardings ──
    _fi=0
    while uci -q get "firewall.@forwarding[$_fi]" >/dev/null 2>&1; do
        _fl="$(uci -q get "firewall.@forwarding[$_fi]._liminal_iface" || true)"
        if [ "$_fl" = "$_old" ]; then
            _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src" || true)"
            _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" || true)"
            # Update zone references in src/dest
            [ "$_fsrc" = "$_old_zone" ] && uci set "firewall.@forwarding[$_fi].src=${_new_zone}"
            [ "$_fdst" = "$_old_zone" ] && uci set "firewall.@forwarding[$_fi].dest=${_new_zone}"
            uci set "firewall.@forwarding[$_fi]._liminal_iface=${_new}"
            echo -e "  ${B}Updated${NC} forwarding: ${OK}${_new_zone}${NC} → ${W}${_fdst}${NC}"
        fi
        _fi=$((_fi + 1))
    done

    # ── 6. Rename firewall rule ──
    _ri=0
    while uci -q get "firewall.@rule[$_ri]" >/dev/null 2>&1; do
        _rl="$(uci -q get "firewall.@rule[$_ri]._liminal_iface" || true)"
        if [ "$_rl" = "$_old" ]; then
            _rname="$(uci -q get "firewall.@rule[$_ri].name" || true)"
            echo -e "  ${B}Renaming${NC} FW rule ${W}${_rname}${NC} → ${OK}${_new_rule}${NC}"
            uci set "firewall.@rule[$_ri].name=${_new_rule}"
            uci set "firewall.@rule[$_ri]._liminal_iface=${_new}"
        fi
        _ri=$((_ri + 1))
    done

    # ── 7. Update DNS hostrecords ──
    rename_iface_hostrecords "$_old" "$_new"

    # ── 8. Update Podkop ──
    if [ "$_has_podkop" -eq 1 ]; then
        echo -e "  ${B}Updating${NC} Podkop: ${W}${_old}${NC} → ${OK}${_new}${NC}"
        uci del_list podkop.settings.source_network_interfaces="$_old" 2>/dev/null || true
        uci add_list podkop.settings.source_network_interfaces="$_new"
        uci commit podkop
    fi

    # ── 9. Commit & reload ──
    echo -e "  ${B}Committing${NC} config..."
    uci commit network
    uci commit firewall

    echo -e "  ${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload
    /etc/init.d/firewall restart 2>/dev/null
    if podkop_present && [ -x /etc/init.d/podkop ] && [ "$_has_podkop" -eq 1 ]; then
        echo -e "  ${B}Restarting${NC} Podkop..."
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
    fi

    echo -e "\n  ${OK}Interface renamed: ${_old} → ${_new}${NC}"
    PAUSE
    # Return new name via global variable
    RENAMED_IFACE="$_new"
    return 0
}

# ═════════════════════════════════════════════════════════════════════
#  DELETE INTERFACE (called from inside interface management)
# ═════════════════════════════════════════════════════════════════════

do_delete_interface() {
    DEL_IFACE="$1"

    DEL_PORT="$(uci -q get "network.${DEL_IFACE}.listen_port" || true)"
    DEL_ZONE="$(find_zone_for_interface "$DEL_IFACE" 2>/dev/null || true)"

    echo ""
    echo -e "  ${A}Will be removed:${NC}"
    echo -e "  ${ERR}-${NC} Interface        ${W}$DEL_IFACE${NC}"
    echo -e "  ${ERR}-${NC} All peers        ${W}$DEL_IFACE${NC}"
    [ -n "$DEL_ZONE" ] && \
    echo -e "  ${ERR}-${NC} FW Zone          ${W}$DEL_ZONE${NC}  (+ forwarding)"
    [ -n "$DEL_PORT" ] && \
    echo -e "  ${ERR}-${NC} FW Rules         port ${W}$DEL_PORT${NC}/udp"
    if podkop_present && podkop_has_interface "$DEL_IFACE" 2>/dev/null; then
        echo -e "  ${ERR}-${NC} Podkop           ${W}$DEL_IFACE${NC}"
    fi
    # Count DNS hostrecords
    _del_hr=0; _del_hi=0
    while uci -q get "dhcp.@hostrecord[$_del_hi]" >/dev/null 2>&1; do
        _del_hli="$(uci -q get "dhcp.@hostrecord[$_del_hi]._liminal_iface" || true)"
        [ "$_del_hli" = "$DEL_IFACE" ] && _del_hr=$((_del_hr + 1))
        _del_hi=$((_del_hi + 1))
    done
    [ "$_del_hr" -gt 0 ] && \
    echo -e "  ${ERR}-${NC} DNS records      ${W}${_del_hr}${NC} hostrecord(s)"
    echo ""

    confirm "Proceed with deletion?" "n" || return 1

    init_backup "Pre-Interface Delete"

    # ── Delete DNS hostrecords ──
    remove_iface_hostrecords "$DEL_IFACE"

    # ── Delete peers ──
    while uci -q get "network.@amneziawg_${DEL_IFACE}[0]" >/dev/null 2>&1; do
        uci delete "network.@amneziawg_${DEL_IFACE}[0]"
    done

    # ── Delete network interface ──
    echo -e "  ${B}Removing${NC} interface ${W}$DEL_IFACE${NC}"
    uci delete "network.${DEL_IFACE}"

    # ── Delete forwardings (reverse order, by _liminal_iface) ──
    _cnt=0
    while uci -q get "firewall.@forwarding[$_cnt]" >/dev/null 2>&1; do
        _cnt=$((_cnt + 1))
    done
    _fi=$((_cnt - 1))
    while [ "$_fi" -ge 0 ]; do
        _fl="$(uci -q get "firewall.@forwarding[$_fi]._liminal_iface" || true)"
        if [ "$_fl" = "$DEL_IFACE" ]; then
            _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src"  || true)"
            _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" || true)"
            echo -e "  ${B}Removing${NC} forwarding: ${_fsrc} -> ${_fdst}"
            uci delete "firewall.@forwarding[$_fi]"
        fi
        _fi=$((_fi - 1))
    done

    # Delete zone by _liminal_iface
    if [ -n "$DEL_ZONE" ]; then
        _zi="$(find_zone_index "$DEL_ZONE" || true)"
        if [ -n "$_zi" ]; then
            _zl="$(uci -q get "firewall.@zone[$_zi]._liminal_iface" || true)"
            if [ "$_zl" = "$DEL_IFACE" ]; then
                echo -e "  ${B}Removing${NC} FW zone ${W}$DEL_ZONE${NC}"
                uci delete "firewall.@zone[$_zi]"
            fi
        fi
    fi

    # ── Delete firewall rules (reverse order, by _liminal_iface) ──
    _cnt=0
    while uci -q get "firewall.@rule[$_cnt]" >/dev/null 2>&1; do
        _cnt=$((_cnt + 1))
    done
    _ri=$((_cnt - 1))
    while [ "$_ri" -ge 0 ]; do
        _rl="$(uci -q get "firewall.@rule[$_ri]._liminal_iface" || true)"
        if [ "$_rl" = "$DEL_IFACE" ]; then
            _rname="$(uci -q get "firewall.@rule[$_ri].name" || echo "unnamed")"
            echo -e "  ${B}Removing${NC} FW rule ${W}${_rname}${NC}"
            uci delete "firewall.@rule[$_ri]"
        fi
        _ri=$((_ri - 1))
    done

    # ── Remove from Podkop ──
    if podkop_present && podkop_has_interface "$DEL_IFACE" 2>/dev/null; then
        echo -e "  ${B}Removing${NC} ${W}$DEL_IFACE${NC} from Podkop"
        remove_podkop_interface "$DEL_IFACE"
    fi

    # ── Commit & reload ──
    echo -e "  ${B}Committing${NC} config..."
    uci commit network
    uci commit firewall

    echo -e "  ${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload
    /etc/init.d/firewall restart 2>/dev/null
    if podkop_present && [ -x /etc/init.d/podkop ]; then
        echo -e "  ${B}Restarting${NC} Podkop..."
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
    fi

    echo -e "\n  ${OK}Interface '${DEL_IFACE}' deleted${NC}"
    echo -e "  ${A}Backups:${NC} $BACKUP_DIR"
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

    echo -e "  ${WARN_C}NOTE: A static public IP address (or a DDNS hostname) and${NC}"
    echo -e "  ${WARN_C}NAT port forwarding (UDP) on your upstream router are${NC}"
    echo -e "  ${WARN_C}required for external clients to connect to this tunnel.${NC}"
    echo ""
    echo -e "  ${DIM2}(Ctrl+C = cancel)${NC}"
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
        validate_cidr_ipv4 "$IFADDR" || continue
        # Check for address/subnet overlap with all network interfaces
        _addr_conflict=""
        _new_subnet="$(network_base_from_cidr "$IFADDR")"
        _new_ip="${IFADDR%/*}"
        _all_ifaces="$(uci show network 2>/dev/null \
            | sed -n "s/^network\.\([^.]*\)\.addresses=.*/\1/p" \
            | sort -u)"
        for _eif in $_all_ifaces; do
            for _ev in $(uci -q get "network.${_eif}.addresses" 2>/dev/null); do
                case "$_ev" in */*) ;; *) continue ;; esac
                _esubnet="$(network_base_from_cidr "$_ev")"
                if [ "$_esubnet" = "$_new_subnet" ] || cidr_contains_ip "$_ev" "$_new_ip"; then
                    _addr_conflict="$_eif"; break 2
                fi
            done
        done
        if [ -n "$_addr_conflict" ]; then
            warn "Address ${IFADDR} overlaps with interface '${_addr_conflict}'"
            continue
        fi
        break
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
        echo -e "  ${OK}Detected LAN IP:${NC} $ROUTER_LAN_IP"
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
    echo -e "  ${OK}Auto FW zone:${NC} $ZONE_NAME"
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
    echo -e "  ${A}Available firewall zones:${NC}"
    _zi=0
    for _z in $_zones; do
        _zi=$((_zi + 1))
        echo -e "  ${B}${_zi}${NC} ${DIM2}›${NC} ${W}${_z}${NC}"
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
    echo -e "  ${OK}LAN zone:${NC} $LAN_ZONE"

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
    echo -e "  ${OK}WAN zone:${NC} $WAN_ZONE"

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
    echo -e "  ${OK}Auto FW rule:${NC} $INCOMING_RULE_NAME"

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
        echo -e "  ${OK}Podkop found${NC}"
        if [ "$SB_RUNNING" -eq 1 ] && [ "$SB_DNS" -eq 1 ]; then
            echo -e "  ${DIM2}Sing-Box listening on 127.0.0.42:53${NC}"
            if [ "$DM_FWD" -eq 1 ]; then
                echo -e "  ${DIM2}DNS chain: peer → dnsmasq → Sing-Box → internet${NC}"
            else
                echo -e "  ${WARN_C}dnsmasq is not forwarding to Sing-Box (missing server 127.0.0.42)${NC}"
            fi
        elif [ "$SB_RUNNING" -eq 0 ]; then
            echo -e "  ${WARN_C}Sing-Box is not running${NC}"
        fi
        if confirm "Configure Podkop-aware routing?" "y"; then
            USE_PODKOP="1"
            DNS_IP="$ROUTER_LAN_IP"
            if [ "$SB_DNS" -eq 1 ] && [ "$DM_FWD" -eq 1 ]; then
                echo -e "  ${OK}Client DNS:${NC} ${W}$DNS_IP${NC} ${DIM2}→ dnsmasq → Sing-Box${NC}"
            else
                echo -e "  ${OK}Client DNS:${NC} ${W}$DNS_IP${NC} ${DIM2}(router LAN)${NC}"
            fi
        fi
    fi
    if [ "$USE_PODKOP" != "1" ]; then
        while true; do
            select_dns DNS_IP && [ -n "$DNS_IP" ] && break
        done
    fi

    check_dangerous_forwarding "$ZONE_NAME"

    # ── Key generation ──
    echo ""
    echo -e "  ${B}Generating${NC} keys..."
    KEYS="$(generate_awg_keys)"
    SERVER_PRIVKEY="$(printf '%s\n' "$KEYS" | sed -n '1p')"
    SERVER_PUBKEY="$(printf  '%s\n' "$KEYS" | sed -n '2p')"

    # ── Confirmation ──
    echo ""
    echo -e "  ${V}Planned config:${NC}"
    echo -e "  ${A}Interface${NC}    ${W}$IFNAME${NC}"
    echo -e "  ${A}Address${NC}      ${W}$IFADDR${NC}"
    echo -e "  ${A}Subnet${NC}       ${W}$IF_SUBNET${NC}"
    echo -e "  ${A}Port${NC}         ${W}$PORT${NC}"
    echo -e "  ${A}MTU${NC}          ${W}$MTU_VALUE${NC}"
    echo -e "  ${A}LAN IP${NC}       ${W}$ROUTER_LAN_IP${NC}"
    echo -e "  ${A}DNS${NC}          ${W}$DNS_IP${NC}"
    echo -e "  ${A}FW Zone${NC}      ${W}$ZONE_NAME${NC}"
    echo -e "  ${A}FW Rule${NC}      ${W}$INCOMING_RULE_NAME${NC}"
    echo -e "  ${A}-> LAN${NC}       $( [ "$ALLOW_LAN_FORWARD" = "1" ] && echo -e "${OK}yes${NC}" || echo -e "${DIM2}no${NC}" )"
    echo -e "  ${A}-> WAN${NC}       $( [ "$ALLOW_WAN_FORWARD" = "1" ] && echo -e "${OK}yes${NC}" || echo -e "${DIM2}no${NC}" )"
    echo -e "  ${A}Podkop${NC}       $( [ "$USE_PODKOP" = "1" ] && echo -e "${OK}yes${NC}" || echo -e "${DIM2}no${NC}" )"
    echo ""

    trap_restore
    confirm "Apply configuration?" "y" || { log "Cancelled."; return; }

    autobackup_enabled && init_backup "Pre-Interface Create"

    # ── Apply: network ──
    echo -e "  ${B}Creating${NC} interface..."
    uci set "network.${IFNAME}=interface"
    uci set "network.${IFNAME}.proto=amneziawg"
    uci set "network.${IFNAME}._liminal_iface=${IFNAME}"
    uci set "network.${IFNAME}.private_key=${SERVER_PRIVKEY}"
    uci set "network.${IFNAME}.listen_port=${PORT}"
    uci add_list "network.${IFNAME}.addresses=${IFADDR}"
    uci set "network.${IFNAME}.mtu=${MTU_VALUE}"
    uci set "network.${IFNAME}.dns=${DNS_IP}"

    # ── Apply: firewall zone ──
    echo -e "  ${B}Creating${NC} FW zone ${W}$ZONE_NAME${NC}"
    uci add firewall zone >/dev/null
    ZONE_IDX="$(uci show firewall \
        | sed -n 's/^firewall\.@zone\[\([0-9]\+\)\]=zone$/\1/p' | tail -n1)"
    uci set "firewall.@zone[$ZONE_IDX].name=${ZONE_NAME}"
    uci set "firewall.@zone[$ZONE_IDX].input=ACCEPT"
    uci set "firewall.@zone[$ZONE_IDX].output=ACCEPT"
    uci set "firewall.@zone[$ZONE_IDX].forward=ACCEPT"
    uci add_list "firewall.@zone[$ZONE_IDX].network=${IFNAME}"
    uci set "firewall.@zone[$ZONE_IDX]._liminal_iface=${IFNAME}"

    # ── Apply: forwardings ──
    if [ "$ALLOW_LAN_FORWARD" = "1" ] && ! forwarding_exists "$ZONE_NAME" "$LAN_ZONE"; then
        echo -e "  ${B}Creating${NC} forwarding: ${W}${ZONE_NAME}${NC} -> ${W}${LAN_ZONE}${NC}"
        uci add firewall forwarding >/dev/null
        FWD_IDX="$(uci show firewall \
            | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1)"
        uci set "firewall.@forwarding[$FWD_IDX].src=${ZONE_NAME}"
        uci set "firewall.@forwarding[$FWD_IDX].dest=${LAN_ZONE}"
        uci set "firewall.@forwarding[$FWD_IDX]._liminal_iface=${IFNAME}"
    fi

    if [ "$ALLOW_WAN_FORWARD" = "1" ]; then
        if ! forwarding_exists "$ZONE_NAME" "$WAN_ZONE"; then
            echo -e "  ${B}Creating${NC} forwarding: ${W}${ZONE_NAME}${NC} -> ${W}${WAN_ZONE}${NC}"
            uci add firewall forwarding >/dev/null
            FWD_IDX="$(uci show firewall \
                | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1)"
            uci set "firewall.@forwarding[$FWD_IDX].src=${ZONE_NAME}"
            uci set "firewall.@forwarding[$FWD_IDX].dest=${WAN_ZONE}"
            uci set "firewall.@forwarding[$FWD_IDX]._liminal_iface=${IFNAME}"
        fi
        ensure_wan_masq
    fi

    # ── Apply: incoming WAN rule ──
    if ! rule_exists_by_name "$INCOMING_RULE_NAME"; then
        echo -e "  ${B}Creating${NC} FW rule ${W}$INCOMING_RULE_NAME${NC}"
        uci add firewall rule >/dev/null
        RULE_IDX="$(uci show firewall \
            | sed -n 's/^firewall\.@rule\[\([0-9]\+\)\]=rule$/\1/p' | tail -n1)"
        uci set "firewall.@rule[$RULE_IDX].name=${INCOMING_RULE_NAME}"
        uci set "firewall.@rule[$RULE_IDX].src=${WAN_ZONE}"
        uci set "firewall.@rule[$RULE_IDX].proto=udp"
        uci set "firewall.@rule[$RULE_IDX].dest_port=${PORT}"
        uci set "firewall.@rule[$RULE_IDX].target=ACCEPT"
        uci set "firewall.@rule[$RULE_IDX]._liminal_iface=${IFNAME}"
    else
        warn "Rule '$INCOMING_RULE_NAME' already exists — skipping"
    fi

    # ── Commit & reload ──
    echo -e "  ${B}Committing${NC} config..."
    uci commit network
    uci commit firewall

    echo -e "  ${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload
    /etc/init.d/firewall restart 2>/dev/null

    # ── Podkop integration ──
    if [ "$USE_PODKOP" = "1" ]; then
        if confirm "Add '$IFNAME' to Podkop source interfaces?" "y"; then
            add_podkop_interface "$IFNAME"
            if [ -x /etc/init.d/podkop ]; then
                echo -e "  ${B}Restarting${NC} Podkop..."
                /etc/init.d/podkop restart >/dev/null 2>&1 || warn "Podkop restart failed"
            fi
        fi
    fi

    # ── Summary ──
    echo ""
    echo -e "  ${OK}Interface created successfully${NC}"
    echo ""
    echo -e "  ${A}Interface${NC}    ${W}$IFNAME${NC}"
    echo -e "  ${A}Address${NC}      ${W}$IFADDR${NC}"
    echo -e "  ${A}Port${NC}         ${W}$PORT${NC}"
    echo -e "  ${A}DNS${NC}          ${W}$DNS_IP${NC}"
    echo -e "  ${A}FW Zone${NC}      ${W}$ZONE_NAME${NC}"
    echo -e "  ${A}FW Rule${NC}      ${W}$INCOMING_RULE_NAME${NC}"
    echo -e "  ${A}Public Key${NC}   ${DIM2}$SERVER_PUBKEY${NC}"
    echo -e "  ${A}Backups${NC}      ${DIM2}$BACKUP_DIR${NC}"
    echo ""
    echo -e "  ${DIM2}Verify:  awg show  |  ifstatus $IFNAME${NC}"
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
        _bsize="$(du -sh "$_bdir" 2>/dev/null | cut -f1 || echo "?")"
        echo -e "  ${A}Date${NC}         ${W}${_date}${NC}"
        echo -e "  ${A}Reason${NC}       ${W}${_reason}${NC}"
        echo -e "  ${A}Size${NC}         ${W}${_bsize}${NC}"
        echo -e "  ${A}Path${NC}         ${DIM2}${_bdir}${NC}"
        echo ""

        _has_net=""; _has_fw=""; _has_pk=""
        [ -f "$_bdir/network.bak" ] && _has_net="${OK}yes${NC}" || _has_net="${DIM2}no${NC}"
        [ -f "$_bdir/firewall.bak" ] && _has_fw="${OK}yes${NC}" || _has_fw="${DIM2}no${NC}"
        [ -f "$_bdir/podkop.bak" ] && _has_pk="${OK}yes${NC}" || _has_pk="${DIM2}no${NC}"
        echo -e "  ${A}Network${NC}      ${_has_net}"
        echo -e "  ${A}Firewall${NC}     ${_has_fw}"
        echo -e "  ${A}Podkop${NC}       ${_has_pk}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${DIM2}Actions${NC}"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Restore${NC} From This Backup"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${ERR}Delete${NC} Backup"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice _bchoice

        case "${_bchoice:-}" in
            1)  confirm "Restore from backup '${_reason}' (${_date})?" "n" || continue
                BACKUP_DIR="$_bdir"
                restore_backups
                echo -e "\n${OK}Restored from backup${NC}"
                PAUSE
                return ;;
            2)  confirm "Delete this backup?" "n" || continue
                rm -rf "$_bdir"
                echo -e "  ${OK}Backup deleted${NC}"
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
            _ab_status="${DIM2}Disabled${NC}"
        fi
        echo -e "${W}Manage Backups${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${A}Auto-Backup${NC}  ${_ab_status}"
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
            _bsize="$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")"
            echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${W}${_date}${NC} ${DIM}·${NC} ${A}${_reason}${NC} ${DIM2}${_bsize}${NC}"
        done

        [ "$_n" -eq 0 ] && echo -e "${DIM2}No backups found${NC}"

        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        if autobackup_enabled; then
            _ab_toggle="${ERR}Disable${NC} Auto-Backup"
        else
            _ab_toggle="${OK}Enable${NC} Auto-Backup"
        fi
        echo -e "  ${DIM2}Actions${NC}"
        echo -e "  ${B}c${NC} ${DIM2}›${NC} ${W}Create${NC} Backup"
        echo -e "  ${B}t${NC} ${DIM2}›${NC} ${_ab_toggle}"
        [ "$_n" -gt 0 ] && \
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Delete All${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} " && read_choice _bsel

        case "${_bsel:-}" in
            "") return ;;
            c|C)
                init_backup "Manual"
                echo -e "  ${OK}Backup created${NC}"
                PAUSE
                continue ;;
            d|D)
                if [ "$_n" -gt 0 ]; then
                    confirm "Delete all ${_n} backups?" "n" || continue
                    rm -rf "$BACKUP_BASE"/*/
                    echo -e "  ${OK}All backups deleted${NC}"
                    PAUSE
                fi
                continue ;;
            t|T)
                mkdir -p "$BACKUP_BASE"
                if autobackup_enabled; then
                    touch "$AUTOBACKUP_OFF"
                    echo -e "  ${OK}Auto-backup disabled${NC}"
                else
                    rm -f "$AUTOBACKUP_OFF"
                    echo -e "  ${OK}Auto-backup enabled${NC}"
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
    echo -e "${W}Full Reset${NC}"
    echo ""
    echo -e "${DIM}──────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${A}This will:${NC}"
    echo -e "  ${ERR}-${NC} Delete all AmneziaWG interfaces"
    echo -e "  ${ERR}-${NC} Delete all related firewall zones, rules, forwardings"
    echo -e "  ${ERR}-${NC} Remove all interfaces from Podkop"
    echo -e "  ${ERR}-${NC} Delete all Liminal backups"
    echo ""

    interfaces="$(get_awg_interfaces)"
    if [ -n "$interfaces" ]; then
        echo -e "  ${A}Interfaces to delete:${NC}"
        for iface in $interfaces; do
            _pc="$(count_peers "$iface")"
            echo -e "    ${W}${iface}${NC} ${DIM2}(${_pc} peers)${NC}"
        done
        echo ""
    fi

    echo -e "${DIM}──────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${ERR}This action cannot be undone.${NC}"
    echo ""
    confirm "Confirm full reset?" "n" || return

    # Delete each interface with full cleanup
    for iface in $interfaces; do
        _port="$(uci -q get "network.${iface}.listen_port" || true)"
        _zone="$(find_zone_for_interface "$iface" 2>/dev/null || true)"

        # Delete DNS hostrecords
        remove_iface_hostrecords "$iface"

        # Delete peers
        while uci -q get "network.@amneziawg_${iface}[0]" >/dev/null 2>&1; do
            uci delete "network.@amneziawg_${iface}[0]"
        done

        # Delete interface
        echo -e "  ${B}Removing${NC} ${W}${iface}${NC}..."
        uci delete "network.${iface}" 2>/dev/null || true

        # Delete forwardings (reverse order, by _liminal_iface)
        _cnt=0
        while uci -q get "firewall.@forwarding[$_cnt]" >/dev/null 2>&1; do
            _cnt=$((_cnt + 1))
        done
        _fi=$((_cnt - 1))
        while [ "$_fi" -ge 0 ]; do
            _fl="$(uci -q get "firewall.@forwarding[$_fi]._liminal_iface" || true)"
            [ "$_fl" = "$iface" ] && uci delete "firewall.@forwarding[$_fi]"
            _fi=$((_fi - 1))
        done

        # Delete zone by _liminal_iface
        if [ -n "$_zone" ]; then
            _zi="$(find_zone_index "$_zone" || true)"
            if [ -n "$_zi" ]; then
                _zl="$(uci -q get "firewall.@zone[$_zi]._liminal_iface" || true)"
                [ "$_zl" = "$iface" ] && uci delete "firewall.@zone[$_zi]"
            fi
        fi

        # Delete firewall rules (reverse order, by _liminal_iface)
        _cnt=0
        while uci -q get "firewall.@rule[$_cnt]" >/dev/null 2>&1; do
            _cnt=$((_cnt + 1))
        done
        _ri=$((_cnt - 1))
        while [ "$_ri" -ge 0 ]; do
            _rl="$(uci -q get "firewall.@rule[$_ri]._liminal_iface" || true)"
            [ "$_rl" = "$iface" ] && uci delete "firewall.@rule[$_ri]"
            _ri=$((_ri - 1))
        done

        # Remove from Podkop
        if podkop_present && podkop_has_interface "$iface" 2>/dev/null; then
            remove_podkop_interface "$iface"
        fi
    done

    # Commit
    uci commit network 2>/dev/null || true
    uci commit firewall 2>/dev/null || true

    echo -e "  ${B}Reloading${NC} network & firewall..."
    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
    if podkop_present && [ -x /etc/init.d/podkop ]; then
        echo -e "  ${B}Restarting${NC} Podkop..."
        /etc/init.d/podkop restart >/dev/null 2>&1 || true
    fi

    # Delete backups
    echo -e "  ${B}Removing${NC} backups..."
    rm -rf "$BACKUP_BASE"

    echo -e "\n  ${OK}Full reset complete${NC}"
    PAUSE
}

# ═════════════════════════════════════════════════════════════════════
#  SELF-UPDATE
# ═════════════════════════════════════════════════════════════════════

fetch_remote_version() {
    have_cmd wget || { echo ""; return; }
    wget -qO- "$LIMINAL_RAW_URL" 2>/dev/null \
        | sed -n 's/^LIMINAL_VERSION="\([^"]*\)"/\1/p' | head -n1
}

do_self_update() {
    echo ""
    echo -e "  ${B}Checking for updates...${NC}"
    _remote_ver="$(fetch_remote_version)"
    if [ -z "$_remote_ver" ]; then
        warn "Could not fetch remote version (no internet or wget missing)"
        PAUSE; return
    fi
    if [ "$_remote_ver" = "$LIMINAL_VERSION" ]; then
        echo -e "  ${OK}Already up to date${NC} (v${LIMINAL_VERSION})"
        PAUSE; return
    fi
    echo -e "  ${A}Current:${NC} v${LIMINAL_VERSION}"
    echo -e "  ${A}Remote:${NC}  v${_remote_ver}"
    echo ""
    confirm "Update to v${_remote_ver}?" "y" || return

    _tmp="$(mktemp /tmp/liminal-update.XXXXXX)" || { warn "mktemp failed"; PAUSE; return; }
    echo -e "  ${B}Downloading...${NC}"
    if ! wget -qO "$_tmp" "$LIMINAL_RAW_URL" 2>/dev/null; then
        rm -f "$_tmp"
        warn "Download failed"
        PAUSE; return
    fi

    # Sanity: must start with shebang
    head -c2 "$_tmp" | grep -q '#!' || {
        rm -f "$_tmp"; warn "Downloaded file is invalid"; PAUSE; return
    }

    cp "$_tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    rm -f "$_tmp"

    echo -e "  ${OK}Updated to v${_remote_ver}${NC}"
    echo -e "  ${DIM2}Restarting...${NC}"
    exec "$SCRIPT_PATH" "$@"
}

# ═════════════════════════════════════════════════════════════════════
#  EXPORT / IMPORT CONFIGURATION
# ═════════════════════════════════════════════════════════════════════

EXPORT_DIR="/root/liminal-exports"

do_export_config() {
    have_cmd jq || { warn "jq is required for export"; PAUSE; return; }

    _interfaces="$(get_awg_interfaces)"
    [ -z "$_interfaces" ] && { echo -e "${DIM2}No Liminal interfaces to export${NC}"; PAUSE; return; }

    mkdir -p "$EXPORT_DIR"
    _ts="$(date +%Y%m%d-%H%M%S)"
    _outfile="${EXPORT_DIR}/liminal-export-${_ts}.json"

    echo -e "  ${B}Exporting${NC} configuration..."

    _json='{"liminal_version":"'"$LIMINAL_VERSION"'","exported":"'"$(date '+%Y-%m-%d %H:%M:%S')"'","interfaces":[]}'

    for iface in $_interfaces; do
        _addr="$(uci -q get "network.${iface}.addresses" || echo "")"
        _port="$(uci -q get "network.${iface}.listen_port" || echo "")"
        _privkey="$(uci -q get "network.${iface}.private_key" || echo "")"
        _mtu="$(uci -q get "network.${iface}.mtu" || echo "1280")"
        _dns="$(uci -q get "network.${iface}.dns" || echo "")"
        _zone="$(find_zone_for_interface "$iface" 2>/dev/null || echo "")"

        _iface_json="$(jq -n \
            --arg name "$iface" \
            --arg addr "$_addr" \
            --arg port "$_port" \
            --arg privkey "$_privkey" \
            --arg mtu "$_mtu" \
            --arg dns "$_dns" \
            --arg zone "$_zone" \
            '{name:$name, addresses:$addr, listen_port:$port, private_key:$privkey, mtu:$mtu, dns:$dns, zone:$zone, peers:[]}'
        )"

        # Export peers
        _pt="amneziawg_${iface}"
        _pi=0
        while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
            _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "")"
            _ppub="$(uci -q get "network.@${_pt}[$_pi].public_key" || echo "")"
            _ppriv="$(uci -q get "network.@${_pt}[$_pi].private_key" || echo "")"
            _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "")"
            _pka="$(uci -q get "network.@${_pt}[$_pi].persistent_keepalive" || echo "25")"
            _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"

            _peer_json="$(jq -n \
                --arg desc "$_pdesc" \
                --arg pub "$_ppub" \
                --arg priv "$_ppriv" \
                --arg aip "$_paip" \
                --arg ka "$_pka" \
                --arg dis "$_pdis" \
                '{description:$desc, public_key:$pub, private_key:$priv, allowed_ips:$aip, persistent_keepalive:$ka, disabled:$dis}'
            )"
            _iface_json="$(echo "$_iface_json" | jq --argjson p "$_peer_json" '.peers += [$p]')"
            _pi=$((_pi + 1))
        done

        _json="$(echo "$_json" | jq --argjson i "$_iface_json" '.interfaces += [$i]')"
    done

    echo "$_json" | jq '.' > "$_outfile"

    _icount=0; _pcount=0
    for iface in $_interfaces; do
        _icount=$((_icount + 1))
        _pcount=$((_pcount + $(count_peers "$iface")))
    done

    echo ""
    echo -e "  ${OK}Export complete${NC}"
    echo -e "  ${A}Interfaces${NC}   ${W}${_icount}${NC}"
    echo -e "  ${A}Peers${NC}        ${W}${_pcount}${NC}"
    echo -e "  ${A}File${NC}         ${DIM2}${_outfile}${NC}"
    PAUSE
}

do_import_config() {
    have_cmd jq || { warn "jq is required for import"; PAUSE; return; }

    echo ""
    prompt _import_file "Path to export JSON file" "" || return
    [ -z "${_import_file:-}" ] && { echo -e "${DIM2}Cancelled${NC}"; PAUSE; return; }
    [ -f "$_import_file" ] || { warn "File not found: $_import_file"; PAUSE; return; }

    _ver="$(jq -r '.liminal_version // empty' "$_import_file" 2>/dev/null || true)"
    [ -z "$_ver" ] && { warn "Invalid export file (missing liminal_version)"; PAUSE; return; }

    _exported="$(jq -r '.exported // "unknown"' "$_import_file")"
    _icount="$(jq '.interfaces | length' "$_import_file")"
    _pcount="$(jq '[.interfaces[].peers | length] | add // 0' "$_import_file")"

    echo ""
    echo -e "  ${A}Export version${NC}  ${W}${_ver}${NC}"
    echo -e "  ${A}Exported at${NC}    ${W}${_exported}${NC}"
    echo -e "  ${A}Interfaces${NC}     ${W}${_icount}${NC}"
    echo -e "  ${A}Peers${NC}          ${W}${_pcount}${NC}"
    echo ""

    confirm "Import this configuration?" "n" || return

    autobackup_enabled && init_backup "Pre-Import"

    _idx=0
    while [ "$_idx" -lt "$_icount" ]; do
        _iname="$(jq -r ".interfaces[$_idx].name" "$_import_file")"
        _iaddr="$(jq -r ".interfaces[$_idx].addresses" "$_import_file")"
        _iport="$(jq -r ".interfaces[$_idx].listen_port" "$_import_file")"
        _iprivkey="$(jq -r ".interfaces[$_idx].private_key" "$_import_file")"
        _imtu="$(jq -r ".interfaces[$_idx].mtu" "$_import_file")"
        _idns="$(jq -r ".interfaces[$_idx].dns" "$_import_file")"

        if uci_network_exists "$_iname"; then
            warn "Interface '$_iname' already exists — skipping"
            _idx=$((_idx + 1)); continue
        fi

        echo -e "  ${B}Creating${NC} interface ${W}${_iname}${NC}..."
        uci set "network.${_iname}=interface"
        uci set "network.${_iname}.proto=amneziawg"
        uci set "network.${_iname}._liminal_iface=${_iname}"
        uci set "network.${_iname}.private_key=${_iprivkey}"
        uci set "network.${_iname}.listen_port=${_iport}"
        uci add_list "network.${_iname}.addresses=${_iaddr}"
        uci set "network.${_iname}.mtu=${_imtu}"
        uci set "network.${_iname}.dns=${_idns}"

        # Import peers
        _pt="amneziawg_${_iname}"
        _pcnt="$(jq ".interfaces[$_idx].peers | length" "$_import_file")"
        _pidx=0
        while [ "$_pidx" -lt "$_pcnt" ]; do
            _pdesc="$(jq -r ".interfaces[$_idx].peers[$_pidx].description" "$_import_file")"
            _ppub="$(jq -r ".interfaces[$_idx].peers[$_pidx].public_key" "$_import_file")"
            _ppriv="$(jq -r ".interfaces[$_idx].peers[$_pidx].private_key" "$_import_file")"
            _paip="$(jq -r ".interfaces[$_idx].peers[$_pidx].allowed_ips" "$_import_file")"
            _pka="$(jq -r ".interfaces[$_idx].peers[$_pidx].persistent_keepalive" "$_import_file")"
            _pdis="$(jq -r ".interfaces[$_idx].peers[$_pidx].disabled" "$_import_file")"

            echo -e "    ${B}Adding${NC} peer ${W}${_pdesc}${NC}..."
            _sec="$(uci add network "$_pt")"
            uci set "network.${_sec}.public_key=${_ppub}"
            uci set "network.${_sec}.private_key=${_ppriv}"
            uci set "network.${_sec}.route_allowed_ips=1"
            uci set "network.${_sec}.allowed_ips=${_paip}"
            uci set "network.${_sec}.persistent_keepalive=${_pka}"
            uci set "network.${_sec}.description=${_pdesc}"
            [ "$_pdis" = "1" ] && uci set "network.${_sec}.disabled=1"

            _pidx=$((_pidx + 1))
        done

        _idx=$((_idx + 1))
    done

    uci commit network

    echo -e "  ${B}Reloading${NC} network..."
    /etc/init.d/network reload >/dev/null 2>&1 || true

    echo ""
    echo -e "  ${OK}Import complete${NC}"
    echo -e "  ${DIM2}Note: Firewall zones/rules were not imported — recreate them manually or re-run Create.${NC}"
    PAUSE
}

do_export_import_menu() {
    while true; do
        clear
        echo -e "${W}Export / Import${NC}"
        echo ""
        echo -e "${DIM}──────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${DIM2}Data${NC}"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Export${NC} Configuration"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Import${NC} Configuration"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice _eichoice

        case "${_eichoice:-}" in
            1) do_export_config ;;
            2) do_import_config ;;
            "") return ;;
            *) ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════
#  LIVE STATUS DASHBOARD
# ═════════════════════════════════════════════════════════════════════

do_live_dashboard() {
    have_cmd awg || { warn "AmneziaWG is required"; PAUSE; return; }

    _refresh=3

    trap 'trap on_error INT; return 0' INT

    while true; do
        clear
        echo -e "  ${W}Live Dashboard${NC}  ${DIM2}$(date '+%H:%M:%S')${NC}  ${DIM2}refresh ${_refresh}s · Ctrl+C exit${NC}"
        echo ""

        _interfaces="$(get_awg_interfaces)"
        if [ -z "$_interfaces" ]; then
            echo -e "  ${DIM2}No Liminal interfaces found${NC}"
        else
            for iface in $_interfaces; do
                _addr="$(uci -q get "network.${iface}.addresses" || echo "n/a")"
                _port="$(uci -q get "network.${iface}.listen_port" || echo "n/a")"
                _disabled="$(uci -q get "network.${iface}.disabled" || echo "0")"

                if [ "$_disabled" = "1" ]; then
                    box_top 100
                    box_line "  ${ICO_DIS} ${W}${iface}${NC}  ${DIM2}Disabled${NC}  ${DIM2}${_addr} :${_port}${NC}"
                    box_bot 100
                    echo ""
                    continue
                elif ! interface_device_exists "$iface"; then
                    box_top 100
                    box_line "  ${ICO_OFF} ${W}${iface}${NC}  ${ERR}Down${NC}  ${DIM2}${_addr} :${_port}${NC}"
                    box_bot 100
                    echo ""
                    continue
                fi

                _active="$(count_active_peers "$iface")"
                _total="$(count_peers "$iface")"

                box_top 100
                box_line "  ${ICO_ON} ${W}${iface}${NC}  ${OK}Up${NC}  ${DIM2}${_addr} :${_port}${NC}  ${DIM2}·${NC}  Peers: ${OK}${_active}${NC}/${_total}"
                box_sep 100

                # Table header
                _G1="\\033[6G"   # Name
                _G2="\\033[24G"  # Status
                _G3="\\033[34G"  # Address
                _G4="\\033[52G"  # Endpoint
                _G5="\\033[74G"  # Handshake
                _G6="\\033[86G"  # Rx
                _G7="\\033[98G"  # Tx

                echo -e "${DIM}${BOX_V}${NC}${_G1}${DIM2}Name${_G2}Status${_G3}Address${_G4}Endpoint${_G5}Handshake${_G6}Rx${_G7}Tx${NC}"

                _pt="amneziawg_${iface}"
                _pi=0
                while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
                    _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "peer$((_pi+1))")"
                    _ppub="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"
                    _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "?")"
                    _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"

                    if [ "$_pdis" = "1" ]; then
                        echo -e "${DIM}${BOX_V}${NC}${_G1}${DIM2}${_pdesc}${_G2}${ICO_DIS} ${DIM2}Disabled${_G3}${_paip}${NC}"
                        _pi=$((_pi + 1)); continue
                    fi

                    _hs="$(get_peer_handshake "$iface" "$_ppub")"
                    _rx="$(get_peer_rx "$iface" "$_ppub")"
                    _tx="$(get_peer_tx "$iface" "$_ppub")"
                    _ep="$(get_peer_endpoint_live "$iface" "$_ppub")"

                    _ico="${ICO_OFF}"; _status="${ERR}Offline${NC}"
                    _hs_sec="9999"
                    if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                        _hs_sec="$(awg show "$iface" 2>/dev/null | awk -v pk="$_ppub" '
                            /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                                sub(/.*latest handshake: /,"");t=0;
                                for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                                    if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                                    else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                                print t;exit}' 2>/dev/null)"
                        if [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null; then
                            _ico="${ICO_ON}"; _status="${OK}Online${NC}"
                        fi
                    fi

                    _hs_col="$(hs_colored "${_hs:--}" "${_hs_sec}")"

                    echo -e "${DIM}${BOX_V}${NC}${_G1}${W}${_pdesc}${NC}${_G2}${_ico} ${_status}${_G3}${DIM2}${_paip}${NC}${_G4}${DIM2}${_ep:--}${NC}${_G5}${_hs_col}${_G6}${DIM2}${_rx:--}${NC}${_G7}${DIM2}${_tx:--}${NC}"

                    _pi=$((_pi + 1))
                done
                box_bot 100
                echo ""
            done
        fi

        sleep "$_refresh" 2>/dev/null || return 0
    done

    trap on_error INT
}

# ═════════════════════════════════════════════════════════════════════
#  CONNECTIVITY CHECK
# ═════════════════════════════════════════════════════════════════════

do_connectivity_check() {
    have_cmd awg || { warn "AmneziaWG is required"; PAUSE; return; }

    _interfaces="$(get_awg_interfaces)"
    [ -z "$_interfaces" ] && { echo -e "${DIM2}No Liminal interfaces found${NC}"; PAUSE; return; }

    clear
    echo -e "${W}Connectivity Check${NC}"
    echo ""
    echo -e "${DIM}──────────────────────────────────────${NC}"

    for iface in $_interfaces; do
        _disabled="$(uci -q get "network.${iface}.disabled" || echo "0")"
        echo ""
        echo -e "  ${A}Interface${NC} ${W}${iface}${NC}"

        # Check 1: interface device exists
        if [ "$_disabled" = "1" ]; then
            echo -e "  ${DIM2}Device${NC}       ${ERR}Disabled${NC}"
            continue
        elif interface_device_exists "$iface"; then
            echo -e "  ${DIM2}Device${NC}       ${OK}Up${NC}"
        else
            echo -e "  ${DIM2}Device${NC}       ${ERR}Down${NC}"
            echo -e "  ${DIM2}Hint:${NC}        ${DIM2}Try: ifup $iface${NC}"
            continue
        fi

        # Check 2: awg show works
        if awg show "$iface" >/dev/null 2>&1; then
            echo -e "  ${DIM2}AWG show${NC}     ${OK}OK${NC}"
        else
            echo -e "  ${DIM2}AWG show${NC}     ${ERR}Failed${NC}"
        fi

        # Check 3: listen port
        _port="$(uci -q get "network.${iface}.listen_port" || echo "")"
        if [ -n "$_port" ] && port_in_use "$_port"; then
            echo -e "  ${DIM2}Port ${_port}${NC}    ${OK}Listening${NC}"
        else
            echo -e "  ${DIM2}Port ${_port}${NC}    ${ERR}Not listening${NC}"
        fi

        # Check 4: firewall zone
        _zone="$(find_zone_for_interface "$iface" 2>/dev/null || echo "")"
        if [ -n "$_zone" ]; then
            echo -e "  ${DIM2}FW Zone${NC}      ${OK}${_zone}${NC}"
        else
            echo -e "  ${DIM2}FW Zone${NC}      ${ERR}Missing${NC}"
        fi

        # Check 5: forwardings
        if [ -n "$_zone" ]; then
            _fwd_lan=""; forwarding_exists "$_zone" "lan" && _fwd_lan="lan"
            _fwd_wan=""; forwarding_exists "$_zone" "wan" && _fwd_wan="wan"
            _fwd_list="${_fwd_lan}${_fwd_lan:+${_fwd_wan:+, }}${_fwd_wan}"
            if [ -n "$_fwd_list" ]; then
                echo -e "  ${DIM2}Forwarding${NC}   ${OK}${_fwd_list}${NC}"
            else
                echo -e "  ${DIM2}Forwarding${NC}   ${ERR}None${NC}"
            fi
        fi

        # Check 6: ping online peers only
        _pt="amneziawg_${iface}"
        _pi=0; _online_found=0
        while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
            _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "peer$((_pi+1))")"
            _ppub="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"
            _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "")"
            _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"
            _pip="${_paip%/*}"

            # Skip disabled and offline peers
            if [ "$_pdis" = "1" ]; then
                _pi=$((_pi + 1)); continue
            fi
            _is_online=0
            if [ -n "$_ppub" ]; then
                _hs_sec="$(awg show "$iface" 2>/dev/null | awk -v pk="$_ppub" '
                    /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                        sub(/.*latest handshake: /,"");t=0;
                        for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                            if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                            else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                        print t;exit}' 2>/dev/null)"
                [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null && _is_online=1
            fi
            if [ "$_is_online" -eq 0 ]; then
                _pi=$((_pi + 1)); continue
            fi

            _online_found=1
            if [ -n "$_pip" ] && ping -c1 -W2 "$_pip" >/dev/null 2>&1; then
                echo -e "  ${DIM2}Peer${NC} ${W}${_pdesc}${NC}  ${OK}Reachable${NC} ${DIM2}(${_pip})${NC}"
            else
                echo -e "  ${DIM2}Peer${NC} ${W}${_pdesc}${NC}  ${ERR}No ping${NC} ${DIM2}(${_pip})${NC}"
            fi
            _pi=$((_pi + 1))
        done
        [ "$_online_found" -eq 0 ] && echo -e "  ${DIM2}No online peers${NC}"
    done

    echo ""
    echo -e "${DIM}──────────────────────────────────────${NC}"
    PAUSE
}

# ═════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ═════════════════════════════════════════════════════════════════════

show_menu() {
    crumb_set "Main"
    while true; do
        clear
        AWG_COUNT="$(get_awg_interfaces | wc -w)"
        if have_cmd awg; then
            _awg_ver="$(awg version 2>/dev/null | sed -n 's/.*tools \(v[^ ]*\).*/\1/p')"
            _awg_s="${ICO_OK} ${OK}${_awg_ver:-ok}${NC}"
        else
            _awg_s="${ICO_ERR} ${DIM2}n/a${NC}"
        fi
        if podkop_present && have_cmd podkop; then
            _pk_ver="$(podkop get_system_info 2>/dev/null | sed -n 's/.*"podkop_version"[^"]*"\([^"]*\)".*/\1/p')"
            _pk_s="${ICO_OK} ${OK}${_pk_ver:-ok}${NC}"
        else
            _pk_s="${ICO_ERR} ${DIM2}n/a${NC}"
        fi

        # \033[<col>G = absolute cursor column
        _C="\\033[48G"
        echo -e "${V}⠀⠀⠀⠀⠀⠀⠀⢀⡄⠀⠀⠀⠀⠀⠀⠀⠀⢸⠳⣄${NC}"
        echo -e "${V}⠀⠀⠀⠀⠀⠀⠀⡏⣧⠀⠀⠀⣀⣀⣀⣀⣀⣈⡀⠣⢧${NC}"
        echo -ne "${V}⠀⠀⠀⠀⠀⠀⣰⠀⡯⣺⠋⢿⣅⠀⠀⠈⠀⠙⢌⠀⢈⣯⡒⠛⣄${NC}" && echo -e "${_C}${W}Liminal${NC} ${DIM2}v${LIMINAL_VERSION}${NC}"
        echo -ne "${B}⠀⠀⠀⢀⠤⣼⢢⠋⠀⠀⠐⡇⠈⡄⠀⠀⠀⠀⢙⠝⠈⠀⣷⠀⠈⣧${NC}" && echo -e "${_C}${DIM2}Powered by AmneziaWG${NC}"
        echo -e "${B}⠀⠀⢰⠁⢠⢾⠃⠀⠀⠀⡆⢿⠀⠙⠀⠀⠀⠀⢋⠓⣾⢿⢿⣶⠀⠈⡆${NC}"
        echo -ne "${B}⠀⠀⢿⠁⣖⣸⠀⠀⢰⣠⣧⠀⠙⠀⢟⢄⢄⠀⣤⠋⠿⣷⢿⢿⠁⢠⢿${NC}" && echo -e "${_C}${DIM2}·${NC} ${A}Developer${NC}  ${W}Salvatore${NC}"
        echo -ne "${A}⠀⠀⣇⠀⢻⢿⠀⠀⡼⠇⠘⣆⠀⠠⣸⢀⣙⣢⣀⢢⣶⣥⢿⣯⠀⢸⢿${NC}" && echo -e "${_C}${DIM2}·${NC} ${A}GitHub${NC}     ${W}@tickcount${NC}"
        echo -ne "${A}⠀⠀⢿⠀⠰⣾⣾⠼⣷⣭⢿⡆⠳⢿⡚⢲⢿⢿⠓⠉⠉⢻⢿⢿⣀⢿⢿${NC}" && echo -e "${_C}${DIM2}·${NC} ${A}Website${NC}    ${W}aemeath.eu${NC}"
        echo -e "${A}⠀⠀⠸⡀⢠⢿⢿⡀⢧⠈⠒⠀⠀⣀⠀⠀⠁⠉⢛⠀⣠⡟⢿⢿⢿⢿⢿${NC}"
        echo -e "${DIM}⠀⠀⠀⣇⢿⢿⢿⢿⣶⣕⣤⢿⢿⣇⣀⣀⣤⠒⠓⠋⠋⠀⢿⢿⢿⢿⡟${NC}"
        echo -e "${DIM}⠀⠀⢠⣏⢿⢿⢿⠀⠀⠀⣼⢿⢿⡟⣾⢿⠟⠉⣦⠀⠀⠘⠋⠈⢿⢿⠃${NC}"
        echo -e "${DIM}⠀⢀⢿⢿⠋⠉⠀⠀⡞⠉⠉⢻⣛⢋⣶⠏⠀⣰⠁⠀⠀⠀⠀⠀⢻⢿⣧${NC}"
        echo ""

        _has_awg=0; have_cmd awg && _has_awg=1
        _has_podkop=0; podkop_present && have_cmd podkop && _has_podkop=1
        _has_qr=0; have_cmd qrencode && _has_qr=1
        _has_jq=0; have_cmd jq && _has_jq=1
        _has_b64=0; have_cmd base64 && _has_b64=1

        _qr_s="${ICO_ERR}"; [ "$_has_qr"  -eq 1 ] && _qr_s="${ICO_OK}"
        _jq_s="${ICO_ERR}"; [ "$_has_jq"  -eq 1 ] && _jq_s="${ICO_OK}"
        _b64_s="${ICO_ERR}"; [ "$_has_b64" -eq 1 ] && _b64_s="${ICO_OK}"

        box_top 56
        box_line "  ${A}awg${NC} ${_awg_s}   ${A}podkop${NC} ${_pk_s}"
        box_line "  ${DIM2}qrencode${NC} ${_qr_s}  ${DIM2}jq${NC} ${_jq_s}  ${DIM2}base64${NC} ${_b64_s}"
        box_bot 56
        echo ""

        # ── Interfaces (inline list) ──
        echo -e "  ${DIM2}Interfaces${NC}"
        _iface_list=""; _iface_n=0
        if [ "$_has_awg" -eq 1 ]; then
            _liminal="$(get_awg_interfaces)"
            _all_awg="$(get_all_awg_interfaces)"

            # Liminal interfaces
            for iface in $_liminal; do
                _iface_n=$((_iface_n + 1))
                _iface_list="${_iface_list} ${iface}"
                _pc="$(count_peers "$iface")"
                _dis="$(uci -q get "network.${iface}.disabled" || echo "0")"
                if [ "$_dis" = "1" ]; then
                    echo -e "  ${B}${_iface_n}${NC} ${DIM2}›${NC} ${ICO_DIS} ${DIM2}${iface}${NC}  ${DIM2}${_pc} peers${NC}"
                elif interface_device_exists "$iface"; then
                    _ac="$(count_active_peers "$iface")"
                    echo -e "  ${B}${_iface_n}${NC} ${DIM2}›${NC} ${ICO_ON} ${W}${iface}${NC}  ${DIM2}${_ac}/${_pc} peers${NC}"
                else
                    echo -e "  ${B}${_iface_n}${NC} ${DIM2}›${NC} ${ICO_OFF} ${W}${iface}${NC}  ${DIM2}${_pc} peers${NC}  ${ERR}Down${NC}"
                fi
            done

            # Non-liminal AWG interfaces
            for iface in $_all_awg; do
                _is_l="$(uci -q get "network.${iface}._liminal_iface" || true)"
                [ -n "$_is_l" ] && _is_l="1" || _is_l="0"
                [ "$_is_l" = "1" ] && continue
                _iface_n=$((_iface_n + 1))
                _iface_list="${_iface_list} ${iface}"
                _pc="$(count_peers "$iface")"
                if interface_device_exists "$iface"; then
                    _ac="$(count_active_peers "$iface")"
                    echo -e "  ${B}${_iface_n}${NC} ${DIM2}›${NC} ${ICO_ON} ${DIM2}${iface}${NC}  ${DIM2}${_ac}/${_pc} peers${NC}"
                else
                    echo -e "  ${B}${_iface_n}${NC} ${DIM2}›${NC} ${ICO_OFF} ${DIM2}${iface}${NC}  ${DIM2}${_pc} peers${NC}  ${ERR}Down${NC}"
                fi
            done
        fi
        if [ "$_iface_n" -eq 0 ]; then
            echo -e "  ${DIM2}No interfaces yet${NC}"
        fi
        if [ "$_has_awg" -eq 1 ]; then
            echo -e "  ${OK}+${NC} ${DIM2}›${NC} ${W}Create${NC} Interface"
        fi
        echo ""

        # ── Monitoring ──
        echo -e "  ${DIM2}Monitoring${NC}"
        if [ "$_has_awg" -eq 1 ]; then
            echo -e "  ${B}m${NC} ${DIM2}›${NC} ${W}Live${NC} Dashboard"
        else
            echo -e "  ${DIM2}m ) Live Dashboard${NC}"
        fi
        echo ""

        # ── Maintenance ──
        echo -e "  ${DIM2}Maintenance${NC}"
        echo -e "  ${B}e${NC} ${DIM2}›${NC} ${W}Export${NC} / ${W}Import${NC}"
        echo -e "  ${B}b${NC} ${DIM2}›${NC} ${W}Manage${NC} Backups"
        echo -e "  ${B}f${NC} ${DIM2}›${NC} ${ERR}Full Reset${NC}"
        echo ""
        echo -e "  ${B}u${NC} ${DIM2}›${NC} ${A}Check for Updates${NC}"
        echo ""

        # ── Install missing ──
        _install_opts=""; _missing_count=0
        if [ "$_has_awg" -eq 0 ]; then _missing_count=$((_missing_count + 1)); fi
        if [ "$_has_podkop" -eq 0 ]; then _missing_count=$((_missing_count + 1)); fi
        if [ "$_has_qr" -eq 0 ]; then _missing_count=$((_missing_count + 1)); fi
        if [ "$_has_jq" -eq 0 ]; then _missing_count=$((_missing_count + 1)); fi
        if [ "$_has_b64" -eq 0 ]; then _missing_count=$((_missing_count + 1)); fi

        if [ "$_missing_count" -gt 0 ]; then
            echo -e "  ${DIM2}Install${NC}"
            if [ "$_missing_count" -gt 1 ]; then
                echo -e "  ${OK}i${NC} ${DIM2}›${NC} ${W}Install All${NC} Missing ${DIM2}(${_missing_count})${NC}"
            fi
            if [ "$_has_awg" -eq 0 ]; then
                echo -e "  ${OK}a${NC} ${DIM2}›${NC} Install ${W}AmneziaWG${NC}"
            fi
            if [ "$_has_podkop" -eq 0 ]; then
                echo -e "  ${OK}p${NC} ${DIM2}›${NC} Install ${W}Podkop${NC}"
            fi
            if [ "$_has_qr" -eq 0 ]; then
                echo -e "  ${OK}q${NC} ${DIM2}›${NC} Install ${W}qrencode${NC}"
            fi
            if [ "$_has_jq" -eq 0 ]; then
                echo -e "  ${OK}j${NC} ${DIM2}›${NC} Install ${W}jq${NC}"
            fi
            if [ "$_has_b64" -eq 0 ]; then
                echo -e "  ${OK}x${NC} ${DIM2}›${NC} Install ${W}base64${NC}"
            fi
            echo ""
        fi

        echo -e "  ${DIM2}Enter › Exit${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice MENU_CHOICE
        if sigint_caught; then
            echo -e "  ${DIM2}Press Ctrl+C again to exit${NC}"
            read -r _confirm_exit || true
            sigint_caught && exit 0
            continue
        fi

        case "${MENU_CHOICE:-}" in
            +) if [ "$_has_awg" -eq 1 ]; then do_create; else warn "Install AmneziaWG first"; fi ;;
            m|M) if [ "$_has_awg" -eq 1 ]; then do_live_dashboard; else warn "Install AmneziaWG first"; fi ;;
            e|E) do_export_import_menu ;;
            b|B) do_manage_backups ;;
            f|F) do_full_reset ;;
            u|U) do_self_update ;;
            i|I) # Install All Missing
                if [ "$_missing_count" -gt 0 ]; then
                    confirm "Install all ${_missing_count} missing packages?" "y" || continue
                    echo ""
                    if [ "$_has_awg" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} AmneziaWG..."
                        sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) 2>&1
                    fi
                    _need_opkg=0
                    if [ "$_has_qr" -eq 0 ] || [ "$_has_jq" -eq 0 ] || [ "$_has_b64" -eq 0 ]; then
                        _need_opkg=1
                        echo -e "  ${B}Updating${NC} package list..."
                        opkg update >/dev/null 2>&1 || apk update >/dev/null 2>&1 || true
                    fi
                    if [ "$_has_podkop" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} Podkop..."
                        sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) 2>&1
                    fi
                    if [ "$_has_qr" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} qrencode..."
                        opkg install qrencode 2>/dev/null || apk add qrencode 2>/dev/null || true
                    fi
                    if [ "$_has_jq" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} jq..."
                        opkg install jq 2>/dev/null || apk add jq 2>/dev/null || true
                    fi
                    if [ "$_has_b64" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} base64..."
                        opkg install coreutils-base64 2>/dev/null || apk add coreutils 2>/dev/null || true
                    fi
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"
                    PAUSE
                fi ;;
            a|A)
                if [ "$_has_awg" -eq 0 ]; then
                    confirm "Install AmneziaWG?" "y" || continue
                    echo -e "  ${B}Installing${NC} AmneziaWG..."
                    sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) 2>&1
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"
                    PAUSE
                fi ;;
            p|P)
                if [ "$_has_podkop" -eq 0 ]; then
                    confirm "Install Podkop?" "y" || continue
                    spinner_start "Installing Podkop..."
                    sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) 2>&1
                    spinner_stop
                    PAUSE
                fi ;;
            q|Q)
                if [ "$_has_qr" -eq 0 ]; then
                    spinner_start "Installing qrencode..."
                    opkg update >/dev/null 2>&1; opkg install qrencode 2>/dev/null || apk add qrencode 2>/dev/null
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"; PAUSE
                fi ;;
            j|J)
                if [ "$_has_jq" -eq 0 ]; then
                    spinner_start "Installing jq..."
                    opkg update >/dev/null 2>&1; opkg install jq 2>/dev/null || apk add jq 2>/dev/null
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"; PAUSE
                fi ;;
            x|X)
                if [ "$_has_b64" -eq 0 ]; then
                    spinner_start "Installing coreutils-base64..."
                    opkg update >/dev/null 2>&1; opkg install coreutils-base64 2>/dev/null || apk add coreutils 2>/dev/null
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"; PAUSE
                fi ;;
            "") echo; exit 0 ;;
            *)  # Numeric = interface selection
                if [ "$_has_awg" -eq 1 ] && [ "$_iface_n" -gt 0 ]; then
                    _si=0; _sel_iface=""
                    for iface in $_iface_list; do
                        _si=$((_si + 1))
                        if [ "$_si" = "$MENU_CHOICE" ]; then _sel_iface="$iface"; break; fi
                    done
                    if [ -n "$_sel_iface" ]; then
                        do_manage_interface "$_sel_iface"
                    fi
                fi ;;
        esac
    done
}

# ═════════════════════════════════════════════════════════════════════
#  CLI (NON-INTERACTIVE) MODE
# ═════════════════════════════════════════════════════════════════════

cli_usage() {
    cat <<USAGE
Liminal v${LIMINAL_VERSION} — AmneziaWG manager for OpenWRT

Usage: $SCRIPT_NAME <command> [options]

Commands:
  status                 Show all interfaces and peers (one-shot dashboard)
  check                  Run connectivity check
  list                   List interfaces (names only)
  peers <interface>      List peers for an interface
  export [file]          Export config to JSON (default: /root/liminal-exports/...)
  import <file>          Import config from JSON
  update                 Check for updates and install if available
  version                Print version

Run without arguments for interactive menu.
USAGE
}

cli_status() {
    have_cmd awg || die "AmneziaWG is not installed"
    _interfaces="$(get_awg_interfaces)"
    [ -z "$_interfaces" ] && { echo "No Liminal interfaces"; exit 0; }

    for iface in $_interfaces; do
        _addr="$(uci -q get "network.${iface}.addresses" || echo "n/a")"
        _port="$(uci -q get "network.${iface}.listen_port" || echo "n/a")"
        _disabled="$(uci -q get "network.${iface}.disabled" || echo "0")"

        if [ "$_disabled" = "1" ]; then
            printf "%-12s  DISABLED  %s :%s\n" "$iface" "$_addr" "$_port"
            continue
        elif ! interface_device_exists "$iface"; then
            printf "%-12s  DOWN      %s :%s\n" "$iface" "$_addr" "$_port"
            continue
        fi

        _active="$(count_active_peers "$iface")"
        _total="$(count_peers "$iface")"
        printf "%-12s  UP        %s :%s  peers: %s/%s\n" "$iface" "$_addr" "$_port" "$_active" "$_total"

        _pt="amneziawg_${iface}"
        _pi=0
        while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
            _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "peer$((_pi+1))")"
            _ppub="$(uci -q get "network.@${_pt}[$_pi].public_key" || true)"
            _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "?")"
            _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"

            if [ "$_pdis" = "1" ]; then
                printf "  %-16s  DISABLED  %s\n" "$_pdesc" "$_paip"
            else
                _hs="$(get_peer_handshake "$iface" "$_ppub")"
                _online="OFFLINE"
                if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                    _hs_sec="$(awg show "$iface" 2>/dev/null | awk -v pk="$_ppub" '
                        /peer:/{cur=$NF} cur==pk&&/latest handshake:/{
                            sub(/.*latest handshake: /,"");t=0;
                            for(i=1;i<=NF;i++){if($i~/^[0-9]+$/){n=$i;u=$(i+1);
                                if(u~/^second/)t+=n;else if(u~/^minute/)t+=n*60;
                                else if(u~/^hour/)t+=n*3600;else if(u~/^day/)t+=n*86400}}
                            print t;exit}' 2>/dev/null)"
                    [ "${_hs_sec:-9999}" -le 120 ] 2>/dev/null && _online="ONLINE"
                fi
                _rx="$(get_peer_rx "$iface" "$_ppub")"
                _tx="$(get_peer_tx "$iface" "$_ppub")"
                printf "  %-16s  %-7s   %s  hs:%s  rx:%s  tx:%s\n" \
                    "$_pdesc" "$_online" "$_paip" "${_hs:-never}" "${_rx:--}" "${_tx:--}"
            fi
            _pi=$((_pi + 1))
        done
    done
}

cli_list() {
    _interfaces="$(get_awg_interfaces)"
    [ -z "$_interfaces" ] && exit 0
    for iface in $_interfaces; do echo "$iface"; done
}

cli_peers() {
    [ -z "${1:-}" ] && die "Usage: $SCRIPT_NAME peers <interface>"
    _iface="$1"
    uci_network_exists "$_iface" || die "Interface '$_iface' not found"
    _pt="amneziawg_${_iface}"
    _pi=0
    while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
        _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "peer$((_pi+1))")"
        _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "?")"
        _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"
        [ "$_pdis" = "1" ] && _st="disabled" || _st="enabled"
        printf "%s\t%s\t%s\n" "$_pdesc" "$_paip" "$_st"
        _pi=$((_pi + 1))
    done
}

cli_export() {
    have_cmd jq || die "jq is required for export"
    _interfaces="$(get_awg_interfaces)"
    [ -z "$_interfaces" ] && die "No Liminal interfaces to export"

    _outfile="${1:-}"
    if [ -z "$_outfile" ]; then
        mkdir -p "$EXPORT_DIR"
        _outfile="${EXPORT_DIR}/liminal-export-$(date +%Y%m%d-%H%M%S).json"
    fi

    _json='{"liminal_version":"'"$LIMINAL_VERSION"'","exported":"'"$(date '+%Y-%m-%d %H:%M:%S')"'","interfaces":[]}'

    for iface in $_interfaces; do
        _addr="$(uci -q get "network.${iface}.addresses" || echo "")"
        _port="$(uci -q get "network.${iface}.listen_port" || echo "")"
        _privkey="$(uci -q get "network.${iface}.private_key" || echo "")"
        _mtu="$(uci -q get "network.${iface}.mtu" || echo "1280")"
        _dns="$(uci -q get "network.${iface}.dns" || echo "")"
        _zone="$(find_zone_for_interface "$iface" 2>/dev/null || echo "")"

        _iface_json="$(jq -n \
            --arg name "$iface" --arg addr "$_addr" --arg port "$_port" \
            --arg privkey "$_privkey" --arg mtu "$_mtu" --arg dns "$_dns" --arg zone "$_zone" \
            '{name:$name, addresses:$addr, listen_port:$port, private_key:$privkey, mtu:$mtu, dns:$dns, zone:$zone, peers:[]}'
        )"

        _pt="amneziawg_${iface}"; _pi=0
        while uci -q get "network.@${_pt}[$_pi]" >/dev/null 2>&1; do
            _pdesc="$(uci -q get "network.@${_pt}[$_pi].description" || echo "")"
            _ppub="$(uci -q get "network.@${_pt}[$_pi].public_key" || echo "")"
            _ppriv="$(uci -q get "network.@${_pt}[$_pi].private_key" || echo "")"
            _paip="$(uci -q get "network.@${_pt}[$_pi].allowed_ips" || echo "")"
            _pka="$(uci -q get "network.@${_pt}[$_pi].persistent_keepalive" || echo "25")"
            _pdis="$(uci -q get "network.@${_pt}[$_pi].disabled" || echo "0")"

            _peer_json="$(jq -n \
                --arg desc "$_pdesc" --arg pub "$_ppub" --arg priv "$_ppriv" \
                --arg aip "$_paip" --arg ka "$_pka" --arg dis "$_pdis" \
                '{description:$desc, public_key:$pub, private_key:$priv, allowed_ips:$aip, persistent_keepalive:$ka, disabled:$dis}'
            )"
            _iface_json="$(echo "$_iface_json" | jq --argjson p "$_peer_json" '.peers += [$p]')"
            _pi=$((_pi + 1))
        done
        _json="$(echo "$_json" | jq --argjson i "$_iface_json" '.interfaces += [$i]')"
    done

    echo "$_json" | jq '.' > "$_outfile"
    echo "$_outfile"
}

cli_update() {
    _remote_ver="$(fetch_remote_version)"
    [ -z "$_remote_ver" ] && die "Could not fetch remote version"
    if [ "$_remote_ver" = "$LIMINAL_VERSION" ]; then
        echo "Up to date (v${LIMINAL_VERSION})"
        exit 0
    fi
    echo "Update available: v${LIMINAL_VERSION} -> v${_remote_ver}"
    _tmp="$(mktemp /tmp/liminal-update.XXXXXX)" || die "mktemp failed"
    wget -qO "$_tmp" "$LIMINAL_RAW_URL" 2>/dev/null || { rm -f "$_tmp"; die "Download failed"; }
    head -c2 "$_tmp" | grep -q '#!' || { rm -f "$_tmp"; die "Invalid download"; }
    cp "$_tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    rm -f "$_tmp"
    echo "Updated to v${_remote_ver}"
}

handle_cli() {
    _cmd="${1:-}"; shift 2>/dev/null || true
    case "$_cmd" in
        status)   cli_status ;;
        check)    do_connectivity_check ;;
        list)     cli_list ;;
        peers)    cli_peers "$@" ;;
        export)   cli_export "$@" ;;
        import)
            [ -z "${1:-}" ] && die "Usage: $SCRIPT_NAME import <file>"
            # Non-interactive import is not supported — open menu
            echo "Import requires interactive mode. Run without arguments."
            exit 1 ;;
        update)   cli_update ;;
        version)  echo "Liminal v${LIMINAL_VERSION}" ;;
        help|-h|--help) cli_usage ;;
        *)        cli_usage; exit 1 ;;
    esac
    exit 0
}


# ═══ Entry point ═════════════════════════════════════════════════════

# CLI mode: if arguments given, handle non-interactively
if [ $# -gt 0 ]; then
    ensure_required_tools
    handle_cli "$@"
fi

ensure_required_tools
ensure_base_firewall
podkop_refresh
show_menu
