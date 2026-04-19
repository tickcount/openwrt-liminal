#!/bin/sh
# liminal.sh
# OpenWRT 24.10 / BusyBox ash
# Developer: Salvatore (GitHub: @tickcount)
# Credits: @immalware — config download service (https://t.me/immalware)

set -eu

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BACKUP_DIR=""
LIMINAL_VERSION="1.5"
LIMINAL_REPO="tickcount/openwrt-liminal"
LIMINAL_RAW_URL="https://raw.githubusercontent.com/${LIMINAL_REPO}/refs/heads/main/liminal.sh"

# ─── UCI config: /etc/config/liminal ────────────────────────────────

# ensure_liminal_config — create /etc/config/liminal with defaults if absent;
#                         migrate existing config (add missing settings section / dns_presets)
ensure_liminal_config() {
    if [ -f /etc/config/liminal ]; then
        # Migrate: ensure 'settings' named section exists
        uci -q get liminal.settings >/dev/null 2>&1 || {
            uci set liminal.settings=liminal
            uci commit liminal
        }
        return 0
    fi
    cat > /etc/config/liminal <<'UCICFG'
config liminal 'settings'
    option backup_dir '/root/liminal-backups'
    option export_dir '/root/liminal-exports'
    option auto_backup '1'
    option default_mtu '1280'
    option mtu_suggestion '1380'
    option default_port '51820'
    option default_keepalive '25'
    option default_dns '1.1.1.1'
    option singbox_dns_ip '127.0.0.42'

config dns_preset
    option name 'Cloudflare'
    option ip '1.1.1.1'

config dns_preset
    option name 'Google'
    option ip '8.8.8.8'

config dns_preset
    option name 'Quad9'
    option ip '9.9.9.9'

config dns_preset
    option name 'OpenDNS'
    option ip '208.67.222.222'

config dns_preset
    option name 'AdGuard'
    option ip '94.140.14.14'

config dns_preset
    option name 'Yandex'
    option ip '77.88.8.8'
UCICFG
}

# _lcfg KEY DEFAULT — read a liminal.settings option with fallback
_lcfg() { uci -q get "liminal.settings.$1" 2>/dev/null || echo "$2"; }

# liminal_config_load — populate CFG_* variables from UCI
liminal_config_load() {
    # User-facing settings (from /etc/config/liminal)
    CFG_BACKUP_DIR="$(_lcfg backup_dir        '/root/liminal-backups')"
    CFG_EXPORT_DIR="$(_lcfg export_dir         '/root/liminal-exports')"
    CFG_AUTO_BACKUP="$(_lcfg auto_backup       '1')"
    CFG_DEFAULT_MTU="$(_lcfg default_mtu       '1280')"
    CFG_MTU_SUGGESTION="$(_lcfg mtu_suggestion '1380')"
    CFG_DEFAULT_PORT="$(_lcfg default_port     '51820')"
    CFG_DEFAULT_KEEPALIVE="$(_lcfg default_keepalive '25')"
    CFG_DEFAULT_DNS="$(_lcfg default_dns       '1.1.1.1')"
    CFG_SB_DNS_IP="$(_lcfg singbox_dns_ip      '127.0.0.42')"

    # Derived paths
    BACKUP_BASE="$CFG_BACKUP_DIR"
    EXPORT_DIR="$CFG_EXPORT_DIR"
    DOWNLOAD_RETRIES=3
}

# Load DNS presets from UCI into _DNS_PRESETS (newline-separated "Name|IP")
_load_dns_presets() {
    _DNS_PRESETS=""
    _dp_i=0
    while uci -q get "liminal.@dns_preset[$_dp_i]" >/dev/null 2>&1; do
        _dp_name="$(uci -q get "liminal.@dns_preset[$_dp_i].name" || true)"
        _dp_ip="$(uci -q get "liminal.@dns_preset[$_dp_i].ip" || true)"
        if [ -n "$_dp_name" ] && [ -n "$_dp_ip" ]; then
            _DNS_PRESETS="${_DNS_PRESETS:+${_DNS_PRESETS}
}${_dp_name}|${_dp_ip}"
        fi
        _dp_i=$((_dp_i + 1))
    done
    # Fallback if no presets in UCI (e.g. config created before dns_preset support)
    if [ -z "$_DNS_PRESETS" ]; then
        _DNS_PRESETS="Cloudflare|1.1.1.1
Google|8.8.8.8
Quad9|9.9.9.9
OpenDNS|208.67.222.222
AdGuard|94.140.14.14
Yandex|77.88.8.8"
    fi
}

ensure_liminal_config
liminal_config_load
_load_dns_presets

# ─── Package manager abstraction ────────────────────────────────────

PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

pkg_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update
    else
        opkg update
    fi
}

pkg_install() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$@"
    else
        opkg install "$@"
    fi
}

pkg_remove() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$@"
    else
        opkg remove --force-depends "$@"
    fi
}

# pkg_is_installed PKG — check if a package is installed via package manager
pkg_is_installed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | grep -q "$1"
    else
        opkg list-installed 2>/dev/null | grep -q "$1"
    fi
}

# pkg_version PKG — print installed package version (empty if not installed)
pkg_version() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | grep "$1" | head -n1 | awk '{print $1}' | sed "s/^${1}-//"
    else
        opkg list-installed 2>/dev/null | grep "$1" | head -n1 | awk '{print $3}'
    fi
}

# ─── UCI schema (source of truth for iface/peer fields) ─────────────
#
# Any new UCI field must be added here so rename/export/import pick it up.
# Split into scalar and list fields because UCI lists need `add_list`.

IFACE_SCHEMA_SCALAR="proto private_key listen_port mtu dns endpoint_host disabled
    fwmark nohostroute tunlink ip4table
    awg_jc awg_jmin awg_jmax awg_s1 awg_s2 awg_s3 awg_s4
    awg_h1 awg_h2 awg_h3 awg_h4
    awg_i1 awg_i2 awg_i3 awg_i4 awg_i5
    _liminal_iface"

IFACE_SCHEMA_LIST="addresses"

PEER_SCHEMA_SCALAR="public_key private_key preshared_key route_allowed_ips allowed_ips
    persistent_keepalive description disabled client_allowed_ips endpoint_host"

# ─── UCI helpers (reduce boilerplate, enforce schema) ────────────────

# iface_get IFACE KEY [DEFAULT]   — read network.IFACE.KEY, fallback to DEFAULT
iface_get() {
    _v="$(uci -q get "network.$1.$2" 2>/dev/null || true)"
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "${3:-}"; fi
}

# iface_set IFACE KEY VALUE        — write network.IFACE.KEY (empty VALUE = delete)
iface_set() {
    if [ -n "${3:-}" ]; then
        uci set "network.$1.$2=$3"
    else
        uci -q delete "network.$1.$2" 2>/dev/null || true
    fi
}

# peer_get PT IDX KEY [DEFAULT]    — read network.@PT[IDX].KEY, fallback to DEFAULT
peer_get() {
    _v="$(uci -q get "network.@$1[$2].$3" 2>/dev/null || true)"
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "${4:-}"; fi
}

# peer_set PT IDX KEY VALUE        — write network.@PT[IDX].KEY (empty = delete)
peer_set() {
    if [ -n "${4:-}" ]; then
        uci set "network.@$1[$2].$3=$4"
    else
        uci -q delete "network.@$1[$2].$3" 2>/dev/null || true
    fi
}

# peer_count PT — number of peer sections under the given type.
peer_count() {
    _i=0
    while uci -q get "network.@$1[$_i]" >/dev/null 2>&1; do
        _i=$((_i + 1))
    done
    echo "$_i"
}

# peer_exists PT IDX — return 0 if section exists, 1 otherwise.
peer_exists() { uci -q get "network.@$1[$2]" >/dev/null 2>&1; }

# iface_copy_fields OLD NEW — copy all schema fields from OLD to NEW iface.
# Driven by IFACE_SCHEMA_SCALAR/LIST so new fields auto-propagate.
iface_copy_fields() {
    for _f in $IFACE_SCHEMA_SCALAR; do
        _v="$(uci -q get "network.$1.$_f" 2>/dev/null || true)"
        [ -n "$_v" ] && uci set "network.$2.$_f=$_v"
    done
    for _f in $IFACE_SCHEMA_LIST; do
        _vs="$(uci -q get "network.$1.$_f" 2>/dev/null || true)"
        for _v in $_vs; do
            uci add_list "network.$2.$_f=$_v"
        done
    done
    return 0
}

# peer_copy_fields OLD_PT OLD_IDX NEW_SEC — copy all peer schema fields.
peer_copy_fields() {
    for _f in $PEER_SCHEMA_SCALAR; do
        _v="$(uci -q get "network.@$1[$2].$_f" 2>/dev/null || true)"
        [ -n "$_v" ] && uci set "network.$3.$_f=$_v"
    done
    return 0
}

# iface_to_json IFACE — build JSON object from UCI, schema-driven.
# Includes {name, zone, peers:[]} plus every schema field that has a value.
iface_to_json() {
    _name="$1"
    _zone="$(find_zone_for_interface "$_name" 2>/dev/null || echo "")"
    _j="$(jq -n --arg n "$_name" --arg z "$_zone" '{name:$n, zone:$z, peers:[]}')"
    for _f in $IFACE_SCHEMA_SCALAR $IFACE_SCHEMA_LIST; do
        _v="$(uci -q get "network.${_name}.${_f}" 2>/dev/null || true)"
        _j="$(printf '%s' "$_j" | jq --arg k "$_f" --arg v "$_v" '. + {($k): $v}')"
    done
    printf '%s' "$_j"
}

# peer_to_json PT IDX — build JSON object from UCI, schema-driven.
peer_to_json() {
    _j='{}'
    for _f in $PEER_SCHEMA_SCALAR; do
        _v="$(uci -q get "network.@$1[$2].${_f}" 2>/dev/null || true)"
        _j="$(printf '%s' "$_j" | jq --arg k "$_f" --arg v "$_v" '. + {($k): $v}')"
    done
    printf '%s' "$_j"
}

# iface_apply_json_fields IFACE JSON — write schema fields from JSON to UCI.
# Empty/missing values → field not set. Rejects malformed WG keys.
iface_apply_json_fields() {
    _name="$1"; _src="$2"
    for _f in $IFACE_SCHEMA_SCALAR; do
        _v="$(printf '%s' "$_src" | jq -r --arg k "$_f" '.[$k] // ""')"
        [ -z "$_v" ] && continue
        case "$_f" in
            private_key)
                if ! validate_wg_key "$_v" 2>/dev/null; then
                    warn "Invalid private_key in JSON for ${_name} — skipping"
                    continue
                fi
                ;;
        esac
        uci set "network.${_name}.${_f}=${_v}"
    done
    for _f in $IFACE_SCHEMA_LIST; do
        _v="$(printf '%s' "$_src" | jq -r --arg k "$_f" '.[$k] // ""')"
        [ -n "$_v" ] && uci add_list "network.${_name}.${_f}=${_v}"
    done
    return 0
}

# peer_apply_json_fields SEC JSON — write peer schema fields to UCI section.
# Rejects malformed WG keys so corrupted imports can't brick the iface.
peer_apply_json_fields() {
    _sec="$1"; _src="$2"
    for _f in $PEER_SCHEMA_SCALAR; do
        _v="$(printf '%s' "$_src" | jq -r --arg k "$_f" '.[$k] // ""')"
        [ -z "$_v" ] || [ "$_v" = "null" ] && continue
        case "$_f" in
            public_key|private_key|preshared_key)
                if ! validate_wg_key "$_v" 2>/dev/null; then
                    warn "Invalid ${_f} for peer — skipping field"
                    continue
                fi
                ;;
        esac
        uci set "network.${_sec}.${_f}=${_v}"
    done
    return 0
}

# restart_iface IFACE [MSG]        — ifdown/ifup with spinner; MSG overrides default.
restart_iface() {
    _msg="${2:-Restarting $1...}"
    spinner_start "$_msg"
    ifdown "$1" >/dev/null 2>&1 || true
    ifup   "$1" >/dev/null 2>&1 || true
    spinner_stop
}

# ─── Live AWG operations (no interface restart = no SSH drop) ────────
# These apply changes to the running kernel state via `awg set`. The UCI
# config must already be committed separately so the change persists
# after reboot (netifd rebuilds kernel state from UCI on ifup).

# live_peer_add IFACE PUBKEY ALLOWED_IPS [ENDPOINT] [PSK_B64] [KEEPALIVE]
# Any positional arg can be empty to skip. PSK is passed as literal base64.
live_peer_add() {
    have_cmd awg || return 1
    _lpa_if="$1"; _lpa_pk="$2"; _lpa_aip="$3"
    _lpa_ep="${4:-}"; _lpa_psk="${5:-}"; _lpa_ka="${6:-}"
    _lpa_psk_file=""
    set -- "$_lpa_if" peer "$_lpa_pk" allowed-ips "$_lpa_aip"
    [ -n "$_lpa_ep" ] && set -- "$@" endpoint "$_lpa_ep"
    [ -n "$_lpa_ka" ] && set -- "$@" persistent-keepalive "$_lpa_ka"
    if [ -n "$_lpa_psk" ]; then
        _lpa_psk_file="$(mktemp)"; chmod 600 "$_lpa_psk_file"
        printf '%s\n' "$_lpa_psk" > "$_lpa_psk_file"
        set -- "$@" preshared-key "$_lpa_psk_file"
    fi
    awg set "$@" 2>/dev/null
    _lpa_rc=$?
    [ -n "$_lpa_psk_file" ] && rm -f "$_lpa_psk_file"
    return "$_lpa_rc"
}

# live_peer_remove IFACE PUBKEY
live_peer_remove() { have_cmd awg && awg set "$1" peer "$2" remove 2>/dev/null; }

# live_peer_set_aip IFACE PUBKEY ALLOWED_IPS   (comma-separated, replaces full list)
live_peer_set_aip() { have_cmd awg && awg set "$1" peer "$2" allowed-ips "$3" 2>/dev/null; }

# live_peer_set_keepalive IFACE PUBKEY SECONDS (0 = off)
live_peer_set_keepalive() { have_cmd awg && awg set "$1" peer "$2" persistent-keepalive "$3" 2>/dev/null; }

# live_peer_set_endpoint IFACE PUBKEY HOST:PORT
live_peer_set_endpoint() { have_cmd awg && awg set "$1" peer "$2" endpoint "$3" 2>/dev/null; }

# live_iface_set_port IFACE PORT
live_iface_set_port() { have_cmd awg && awg set "$1" listen-port "$2" 2>/dev/null; }

# live_iface_set_fwmark IFACE MARK (0 or "off" to disable)
live_iface_set_fwmark() {
    have_cmd awg || return 1
    _fm="${2:-0}"
    [ "$_fm" = "off" ] && _fm=0
    awg set "$1" fwmark "$_fm" 2>/dev/null
}

# live_iface_set_mtu IFACE MTU — tunnel MTU (ip link, not awg set)
live_iface_set_mtu() { ip link set mtu "$2" dev "$1" 2>/dev/null; }

# live_iface_set_obf IFACE — push current UCI obfuscation values to kernel.
live_iface_set_obf() {
    have_cmd awg || return 1
    _if="$1"
    # shellcheck disable=SC2046
    set --
    for _k in jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5; do
        _v="$(iface_get "$_if" "awg_${_k}")"
        [ -n "$_v" ] && set -- "$@" "$_k" "$_v"
    done
    [ "$#" -eq 0 ] && return 0
    awg set "$_if" "$@" 2>/dev/null
}

# live_iface_clear_obf IFACE — zero-out all obfuscation on kernel (plain WG mode).
live_iface_clear_obf() {
    have_cmd awg || return 1
    awg set "$1" \
        jc 0 jmin 0 jmax 0 s1 0 s2 0 s3 0 s4 0 \
        h1 1 h2 2 h3 3 h4 4 2>/dev/null
}

# live_peer_sync_from_uci IFACE PT IDX — push the UCI-defined peer at index
# back onto the kernel (used when re-enabling a peer that was removed).
live_peer_sync_from_uci() {
    _if="$1"; _pt="$2"; _idx="$3"
    _pk="$(peer_get "$_pt" "$_idx" public_key)"
    [ -z "$_pk" ] && return 1
    _aip="$(peer_get "$_pt" "$_idx" allowed_ips)"
    _psk="$(peer_get "$_pt" "$_idx" preshared_key)"
    _ka="$(peer_get  "$_pt" "$_idx" persistent_keepalive)"
    _ep="$(peer_get  "$_pt" "$_idx" endpoint_host)"
    live_peer_add "$_if" "$_pk" "$_aip" "$_ep" "$_psk" "$_ka"
}

# awg_peer_field IFACE PUBKEY KEY — read a field from human `awg show` output.
# Use awg_dump_peer for fields covered by the machine-readable dump format.
awg_peer_field() {
    have_cmd awg || return 0
    awg show "$1" 2>/dev/null | awk -v pk="$2" -v key="$3" '
        /peer:/ { cur=$NF }
        cur==pk && index($0, key ":") {
            sub(/^[[:space:]]*/, ""); sub("^" key ":[[:space:]]*", "")
            print; exit
        }
    '
}

# awg_dump_peer IFACE PUBKEY — echo the peer's tab-separated line from
# `awg show IFACE dump`. Empty if peer not found. Fields (1-based):
#   1 public_key  2 preshared_key  3 endpoint  4 allowed_ips
#   5 last_handshake_time (unix ts, 0 = never)
#   6 rx_bytes   7 tx_bytes   8 persistent_keepalive (number or "off")
awg_dump_peer() {
    have_cmd awg || return 0
    # NR>1 skips the device line (always first in per-iface dump).
    awg show "$1" dump 2>/dev/null | awk -F'\t' -v pk="$2" 'NR>1 && $1==pk { print; exit }'
}

# awg_peer_handshake_age IFACE PUBKEY — print handshake age in seconds.
# 9999 if never (ts=0) or peer not found.
awg_peer_handshake_age() {
    _line="$(awg_dump_peer "$1" "$2")"
    [ -z "$_line" ] && { echo 9999; return 0; }
    _ts="$(printf '%s\n' "$_line" | awk -F'\t' '{print $5}')"
    if [ -z "$_ts" ] || [ "$_ts" = "0" ]; then echo 9999; return 0; fi
    echo $(( $(date +%s) - _ts ))
}

# fmt_bytes NUM — format a raw byte count into human-readable (matches the
# "1.24 MiB" style of WireGuard's human show output).
fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if      (b >= 1099511627776) printf "%.2f TiB\n", b/1099511627776
        else if (b >= 1073741824)    printf "%.2f GiB\n", b/1073741824
        else if (b >= 1048576)       printf "%.2f MiB\n", b/1048576
        else if (b >= 1024)          printf "%.2f KiB\n", b/1024
        else                         printf "%d B\n",     b
    }'
}

# ─── Firewall helpers ────────────────────────────────────────────────

# fw_new_zone / fw_new_rule / fw_new_forwarding — add a new section, echo its
# numeric index so caller can uci set "firewall.@TYPE[IDX].prop=val".
fw_new_zone()       { uci add firewall zone >/dev/null;       uci show firewall | sed -n 's/^firewall\.@zone\[\([0-9]\+\)\]=zone$/\1/p'             | tail -n1; }
fw_new_rule()       { uci add firewall rule >/dev/null;       uci show firewall | sed -n 's/^firewall\.@rule\[\([0-9]\+\)\]=rule$/\1/p'             | tail -n1; }
fw_new_forwarding() { uci add firewall forwarding >/dev/null; uci show firewall | sed -n 's/^firewall\.@forwarding\[\([0-9]\+\)\]=forwarding$/\1/p' | tail -n1; }

# fw_find_by TYPE PROP VALUE — echo index of first matching section (empty + rc=1 if none).
fw_find_by() {
    _i=0
    while uci -q get "firewall.@$1[$_i]" >/dev/null 2>&1; do
        _v="$(uci -q get "firewall.@$1[$_i].$2" 2>/dev/null || true)"
        [ "$_v" = "$3" ] && { echo "$_i"; return 0; }
        _i=$((_i + 1))
    done
    return 1
}

# fw_count TYPE — echo the number of sections of the given type.
fw_count() {
    _i=0
    while uci -q get "firewall.@$1[$_i]" >/dev/null 2>&1; do
        _i=$((_i + 1))
    done
    echo "$_i"
}

# ─── Service helpers (colors resolved at call time) ──────────────────

svc_restart() { echo -e "  ${B}Restarting${NC} $1..."; /etc/init.d/"$1" restart >/dev/null 2>&1 || true; }
svc_reload()  { echo -e "  ${B}Reloading${NC}  $1..."; /etc/init.d/"$1" reload  >/dev/null 2>&1 || true; }

# apply_all [podkop] — commit network+firewall, reload network, restart firewall.
# Pass "podkop" to also restart podkop if its init script is present.
apply_all() {
    uci commit network
    uci commit firewall
    svc_reload network
    svc_restart firewall
    if [ "${1:-}" = "podkop" ] && [ -x /etc/init.d/podkop ]; then
        svc_restart podkop
    fi
}

# cancelled — print "Cancelled" in dim. Use in `|| { cancelled; PAUSE; return; }`.
cancelled() { echo -e "  ${DIM2}Cancelled${NC}"; }


# ─── Colors (soft white-blue-violet palette) ─────────────────────────

W="\033[38;5;255m"            # clean bright white
B="\033[38;5;111m"            # soft blue
V="\033[38;5;141m"            # soft violet
A="\033[38;5;146m"            # soft steel blue (labels)
DIM="\033[2m\033[38;5;240m"   # very faded — box frames only (borders/sep)
DIM2="\033[38;5;245m"         # readable dim gray — inline content hints
OK="\033[38;5;114m"           # soft green
WARN_C="\033[38;5;180m"       # soft wheat/amber
ERR="\033[38;5;174m"          # soft rose/red
NC="\033[0m"

# ─── Icons & box-drawing ────────────────────────────────────────────

ICO_ON="${OK}●${NC}"
ICO_OFF="${ERR}●${NC}"
ICO_DIS="${DIM2}○${NC}"
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

# ─── Auto-sizing box buffer ─────────────────────────────────────────
# Pattern: collect content via box_buf_line / box_buf_sep, then flush via
# box_buf_flush. Flush measures the widest buffered line (ANSI stripped)
# and sizes the frame accordingly, so long hostnames / resolved-IP hints
# never overflow.

_BOX_BUF=""
_BOX_BUF_SEP="$(printf '\037')"   # ASCII unit-separator (0x1F)

box_buf_reset() { _BOX_BUF=""; }
box_buf_line()  { _BOX_BUF="${_BOX_BUF}${1}${_BOX_BUF_SEP}"; }
box_buf_sep()   { _BOX_BUF="${_BOX_BUF}__BOXSEP__${_BOX_BUF_SEP}"; }

# _visible_bytes TEXT — length after stripping ANSI CSI.
# printf %b expands the literal "\033[…m" the rest of the codebase stores,
# then sed removes the real escape bytes. Multibyte runes (●, ↳, ✓) count
# as 3 bytes each — box ends up a few chars wider than strictly needed.
_visible_bytes() {
    _vb="$(printf '%b' "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*[mGKHJ]//g')"
    echo "${#_vb}"
}

# box_buf_flush [min] [max] — render top + buffered lines + bot, sized to
# the widest line. Defaults: min=44, max=100.
box_buf_flush() {
    _bf_min="${1:-44}"; _bf_max="${2:-100}"
    _bf_w="$_bf_min"
    _bf_rest="$_BOX_BUF"
    while [ -n "$_bf_rest" ]; do
        _bf_line="${_bf_rest%%${_BOX_BUF_SEP}*}"
        case "$_bf_rest" in
            *"${_BOX_BUF_SEP}"*) _bf_rest="${_bf_rest#*${_BOX_BUF_SEP}}" ;;
            *) _bf_rest="" ;;
        esac
        [ -z "$_bf_line" ] && continue
        [ "$_bf_line" = "__BOXSEP__" ] && continue
        _bf_len="$(_visible_bytes "$_bf_line")"
        _bf_len=$((_bf_len + 2))   # account for "│ " prefix
        [ "$_bf_len" -gt "$_bf_w" ] && _bf_w="$_bf_len"
    done
    [ "$_bf_w" -gt "$_bf_max" ] && _bf_w="$_bf_max"

    box_top "$_bf_w"
    _bf_rest="$_BOX_BUF"
    while [ -n "$_bf_rest" ]; do
        _bf_line="${_bf_rest%%${_BOX_BUF_SEP}*}"
        case "$_bf_rest" in
            *"${_BOX_BUF_SEP}"*) _bf_rest="${_bf_rest#*${_BOX_BUF_SEP}}" ;;
            *) _bf_rest="" ;;
        esac
        if [ "$_bf_line" = "__BOXSEP__" ]; then
            box_sep "$_bf_w"
        else
            box_line "$_bf_line"
        fi
    done
    box_bot "$_bf_w"
    box_buf_reset
    return 0
}

# box_section LABEL [width] — label arg is ignored (kept for grouping at
# call sites); emits a plain separator.
box_section() {
    box_sep "${2:-54}"
}

# ─── Breadcrumbs ─────────────────────────────────────────────────────

_CRUMBS=""
crumb_set()  { _CRUMBS="$*"; }
crumb_push() { [ -n "$_CRUMBS" ] && _CRUMBS="${_CRUMBS} > $1" || _CRUMBS="$1"; }
crumb_pop()  { _CRUMBS="$(echo "$_CRUMBS" | sed 's/ > [^>]*$//')"; }
crumb_show() {
    [ -z "$_CRUMBS" ] && return
    echo -e "${DIM2}${_CRUMBS}${NC}"
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
    elif [ "$_sec" -le "30" ] 2>/dev/null; then
        printf '%b' "${OK}${_val}${NC}"
    elif [ "$_sec" -le "120" ] 2>/dev/null; then
        printf '%b' "${WARN_C}${_val}${NC}"
    else
        printf '%b' "${ERR}${_val}${NC}"
    fi
}

log()  { printf '%s\n' "$*"; }
warn() { echo -e "  ${ERR}${ICO_WARN} warning:${NC} $*" >&2; }
die()  { echo -e "  ${ERR}${ICO_ERR} error:${NC} $*" >&2; exit 1; }
PAUSE() { echo -ne "\n  ${DIM2}Press Enter...${NC}"; read dummy || true; }
section() {
    _stitle="$1"; _slen=${#_stitle}; _spad=$((34 - _slen))
    [ "$_spad" -lt 1 ] && _spad=1
    _sline=""; _si=0; while [ "$_si" -lt "$_spad" ]; do _sline="${_sline}─"; _si=$((_si+1)); done
    echo -e "\n  ${DIM2}──${NC} ${V}${_stitle}${NC} ${DIM2}${_sline}${NC}\n"
}

# read_choice VAR — read a single menu choice, strip invisible/control chars
read_choice() {
    read -r _rc_raw || true
    _rc_clean="$(printf '%s' "${_rc_raw:-}" | tr -d '\001-\037\177\200-\237' | sed 's/[^A-Za-z0-9+]//g')"
    eval "$1=\$_rc_clean"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ─── Download with retries ──────────────────────────────────────────

# wget_retry URL DEST [retries]
# Downloads URL to DEST with retries and non-empty file check.
wget_retry() {
    _wr_url="$1"; _wr_dest="$2"; _wr_max="${3:-$DOWNLOAD_RETRIES}"
    _wr_attempt=0
    while [ "$_wr_attempt" -lt "$_wr_max" ]; do
        if wget -qO "$_wr_dest" "$_wr_url" 2>/dev/null; then
            if [ -s "$_wr_dest" ]; then
                return 0
            fi
        fi
        rm -f "$_wr_dest"
        _wr_attempt=$((_wr_attempt + 1))
    done
    return 1
}

# ─── DNS connectivity check ─────────────────────────────────────────

check_dns() {
    nslookup google.com >/dev/null 2>&1
}

# check_dns_server IP — test if a specific DNS server responds
check_dns_server() {
    _cds_ip="$1"
    nslookup google.com "$_cds_ip" >/dev/null 2>&1
}

# check_internet — basic internet reachability (ping, then curl fallback)
check_internet() {
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && return 0
    have_cmd curl && curl -so /dev/null --connect-timeout 3 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null && return 0
    return 1
}

# _nslookup_ips DOMAIN [SERVER] — resolve domain, print IPs (BusyBox-safe)
# BusyBox nslookup outputs "Address N: X.X.X.X" not "Address: X.X.X.X"
# Skip the first Address line (that's the DNS server itself)
_nslookup_ips() {
    _ni_out=""
    if [ -n "${2:-}" ]; then
        _ni_out="$(nslookup "$1" "$2" 2>/dev/null || true)"
    else
        _ni_out="$(nslookup "$1" 2>/dev/null || true)"
    fi
    echo "$_ni_out" | awk '
        /^$/ { body=1; next }
        body && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
            for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i
        }'
}

# check_dns_port53 IP — test if port 53 is reachable (not blocked by ISP)
check_dns_port53() {
    _cd53_ip="$1"
    _cd53_ips="$(_nslookup_ips "google.com" "$_cd53_ip")"
    [ -n "$_cd53_ips" ] && return 0
    return 1
}

# check_dns_poisoning DOMAIN [SERVER] — detect DNS poisoning (127.x.x.x response)
check_dns_poisoning() {
    _cdp_ips="$(_nslookup_ips "$1" "${2:-}")"
    # No response at all
    [ -z "$_cdp_ips" ] && return 2
    echo "$_cdp_ips" | grep -qE '^127\.' && return 1
    return 0
}

# check_dns_same_ip DOMAIN1 DOMAIN2 [SERVER] — detect if two different domains resolve to same IP
check_dns_same_ip() {
    _cdsi_ip1="$(_nslookup_ips "$1" "${3:-}" | head -1)"
    _cdsi_ip2="$(_nslookup_ips "$2" "${3:-}" | head -1)"
    [ -z "$_cdsi_ip1" ] || [ -z "$_cdsi_ip2" ] && return 2  # can't resolve
    [ "$_cdsi_ip1" = "$_cdsi_ip2" ] && return 1              # same IP = suspicious
    return 0
}

# check_doh DOMAIN — resolve via DoH (Cloudflare), returns IP or empty
check_doh() {
    have_cmd curl || return 1
    _cdoh_out="$(curl -s --connect-timeout 3 -H "accept: application/dns-json" \
        "https://1.1.1.1/dns-query?name=${1}&type=A" 2>/dev/null || true)"
    echo "$_cdoh_out" | sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' | head -1
}

# check_dns_vs_doh DOMAIN [SERVER] — compare plain DNS vs DoH answer
# Returns 0=match, 1=mismatch (poisoning), 2=can't check
check_dns_vs_doh() {
    _cdd_doh="$(check_doh "$1")"
    [ -z "$_cdd_doh" ] && return 2
    _cdd_plain="$(_nslookup_ips "$1" "${2:-}" | head -1)"
    [ -z "$_cdd_plain" ] && return 2
    [ "$_cdd_doh" = "$_cdd_plain" ] && return 0
    return 1
}

# ─── Disk space check ───────────────────────────────────────────────

# ensure_disk_space [required_kb]
# Checks /overlay (or / if /overlay absent) for available space.
ensure_disk_space() {
    _eds_required="${1:-15360}" # default 15MB in KB
    if df /overlay >/dev/null 2>&1; then
        _eds_avail="$(df /overlay | awk 'NR==2 {print $4}')"
    else
        _eds_avail="$(df / | awk 'NR==2 {print $4}')"
    fi
    [ -z "$_eds_avail" ] && return 0 # can't determine — skip
    if [ "$_eds_avail" -lt "$_eds_required" ] 2>/dev/null; then
        die "Insufficient disk space: $((_eds_avail / 1024))MB available, $((_eds_required / 1024))MB required"
    fi
}

# ─── Semver comparison ───────────────────────────────────────────────

# version_newer NEW OLD — returns 0 if NEW > OLD (semver)
version_newer() {
    _vn_new="$(echo "$1" | sed 's/^v//')"; _vn_old="$(echo "$2" | sed 's/^v//')"
    [ "$_vn_new" = "$_vn_old" ] && return 1
    _vn_oldest="$(printf '%s\n%s\n' "$_vn_new" "$_vn_old" | sort -V | head -n1)"
    [ "$_vn_oldest" = "$_vn_old" ]
}

# version_major VER — returns the major number
version_major() { echo "$1" | sed 's/^v//' | cut -d. -f1; }

# ─── Backup / Restore ────────────────────────────────────────────────

init_backup() {
    _reason="${1:-Manual}"
    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="${BACKUP_BASE}/${TS}"
    mkdir -p "$BACKUP_DIR"
    cp /etc/config/network  "$BACKUP_DIR/network.bak"
    cp /etc/config/firewall "$BACKUP_DIR/firewall.bak"
    [ -f /etc/config/dhcp ]   && cp /etc/config/dhcp   "$BACKUP_DIR/dhcp.bak" || true
    [ -f /etc/config/podkop ]  && cp /etc/config/podkop  "$BACKUP_DIR/podkop.bak" || true
    [ -f /etc/config/liminal ] && cp /etc/config/liminal "$BACKUP_DIR/liminal.bak" || true
    echo "$_reason" > "$BACKUP_DIR/.reason"
    date '+%Y-%m-%d %H:%M:%S' > "$BACKUP_DIR/.date"
}

# BACKUP_BASE, EXPORT_DIR set by liminal_config_load()

autobackup_enabled() { [ "$CFG_AUTO_BACKUP" = "1" ]; }

restore_backups() {
    echo -e "  ${B}Restoring${NC} backups from $BACKUP_DIR ..."
    [ -f "$BACKUP_DIR/network.bak" ]  && cp "$BACKUP_DIR/network.bak"  /etc/config/network
    [ -f "$BACKUP_DIR/firewall.bak" ] && cp "$BACKUP_DIR/firewall.bak" /etc/config/firewall
    [ -f "$BACKUP_DIR/dhcp.bak" ]     && cp "$BACKUP_DIR/dhcp.bak"     /etc/config/dhcp || true
    [ -f "$BACKUP_DIR/podkop.bak" ]   && cp "$BACKUP_DIR/podkop.bak"   /etc/config/podkop || true
    [ -f "$BACKUP_DIR/liminal.bak" ]  && cp "$BACKUP_DIR/liminal.bak"  /etc/config/liminal && liminal_config_load || true
    svc_reload network
    svc_restart firewall
    svc_restart dnsmasq
    [ -x /etc/init.d/podkop ] && svc_restart podkop
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
        printf "  %s [%b%s%b]: " "$_q" "$DIM2" "$_def" "$NC"
    else
        printf "  %s: " "$_q"
    fi
    read -r _ans || true
    is_cancelled && { eval "$_var="; return 1; }
    # Strip control characters
    _ans="$(printf '%s' "${_ans:-}" | tr -d '\001-\037\177')"
    [ -z "${_ans:-}" ] && _ans="$_def"
    eval "$_var=\$_ans"
}

confirm() {
    _q="$1"; _def="${2:-y}"
    if [ "$_def" = "y" ]; then
        echo -ne "  ${_q} [${OK}Y${NC}/${DIM2}n${NC}] "
    else
        echo -ne "  ${_q} [${DIM2}y${NC}/${ERR}N${NC}] "
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

# _uptime_ms — current uptime in milliseconds (via /proc/uptime, ~10ms precision)
_uptime_ms() {
    awk '{split($1,a,"."); printf "%d\n", a[1]*1000 + a[2]*10}' /proc/uptime 2>/dev/null || echo ""
}

# _dns_test IP — test DNS server with actual query, print latency in ms (or "ok"/"fail")
# Verifies the IP is a real DNS server (resolves a domain), not just pingable.
_dns_test() {
    _dt_ip="$1"
    _dt_start="$(_uptime_ms)"
    # Actual DNS query — proves this is a DNS server, not just a live host
    _dt_ips="$(_nslookup_ips "google.com" "$_dt_ip")"
    [ -z "$_dt_ips" ] && { echo "fail"; return; }
    _dt_end="$(_uptime_ms)"
    if [ -n "$_dt_start" ] && [ -n "$_dt_end" ]; then
        _dt_ms=$((_dt_end - _dt_start))
        [ "$_dt_ms" -lt 0 ] && _dt_ms=0
        echo "${_dt_ms}ms"
    else
        echo "ok"
    fi
}

# _dns_test_all — test all DNS servers in parallel, write results to temp dir
_dns_test_all() {
    _dta_dir="$1"
    shift
    for _dta_ip in "$@"; do
        ( _r="$(_dns_test "$_dta_ip")"; echo "$_r" > "${_dta_dir}/${_dta_ip}" ) &
    done
    wait
}

# _dns_fmt_latency RESULT — format latency result for display
_dns_fmt_latency() {
    case "$1" in
        fail) printf '%b' "${ERR}✗${NC}" ;;
        ok)   printf '%b' "${OK}✓${NC}" ;;
        *)    printf '%b' "${OK}✓${NC} ${DIM2}${1}${NC}" ;;
    esac
}

# select_dns VAR [current_dns]
# Shows a numbered list of DNS servers with latency. Sets VAR to the chosen IP.
# Returns 1 if cancelled.
select_dns() {
    _sd_var="$1"; _sd_cur="${2:-}"
    _sd_lan="$(detect_router_lan_ip 2>/dev/null || true)"

    # Read cached state (set by podkop_refresh at startup)
    _sd_sb_active=0
    if [ "${SB_RUNNING:-0}" -eq 1 ] && [ "${SB_DNS:-0}" -eq 1 ]; then
        _sd_sb_active=1
    fi

    # ── Collect all IPs to test ──
    _sd_all_ips=""
    [ -n "$_sd_lan" ] && _sd_all_ips="$_sd_lan"
    _sd_ifs="$IFS"; IFS='
'
    for _sd_entry in $_DNS_PRESETS; do
        IFS="$_sd_ifs"
        _sd_eip="${_sd_entry##*|}"
        _sd_all_ips="${_sd_all_ips:+${_sd_all_ips} }${_sd_eip}"
    done
    IFS="$_sd_ifs"
    [ -n "$_sd_cur" ] && case " $_sd_all_ips " in
        *" $_sd_cur "*) ;;
        *) _sd_all_ips="${_sd_all_ips:+${_sd_all_ips} }${_sd_cur}" ;;
    esac

    # ── Test latency in parallel ──
    echo -ne "  ${DIM2}Testing DNS servers...${NC}"
    _sd_tmp="$(mktemp -d 2>/dev/null || echo "/tmp/liminal-dns-$$")"
    mkdir -p "$_sd_tmp"
    _dns_test_all "$_sd_tmp" $_sd_all_ips
    echo -ne "\r\033[K"

    # Helper: read latency result for an IP
    _sd_lat() { cat "${_sd_tmp}/${1}" 2>/dev/null || echo "fail"; }

    # ── Determine recommendation ──
    _sd_rec=""
    _sd_rec_reason=""
    if [ "$_sd_sb_active" -eq 1 ] && [ -n "$_sd_lan" ]; then
        _sd_rl="$(_sd_lat "$_sd_lan")"
        if [ "$_sd_rl" != "fail" ]; then
            _sd_rec="$_sd_lan"
            _sd_rec_reason="routes through Sing-Box"
        fi
    fi
    # If no recommendation yet, pick fastest responding preset
    if [ -z "$_sd_rec" ]; then
        _sd_best_ms=99999; _sd_best_ip=""
        _sd_ifs="$IFS"; IFS='
'
        for _sd_entry in $_DNS_PRESETS; do
            IFS="$_sd_ifs"
            _sd_eip="${_sd_entry##*|}"
            _sd_rl="$(_sd_lat "$_sd_eip")"
            case "$_sd_rl" in fail|ok) continue ;; esac
            _sd_rl_num="$(echo "$_sd_rl" | tr -dc '0-9')"
            [ -z "$_sd_rl_num" ] && continue
            if [ "$_sd_rl_num" -lt "$_sd_best_ms" ] 2>/dev/null; then
                _sd_best_ms="$_sd_rl_num"; _sd_best_ip="$_sd_eip"
            fi
        done
        IFS="$_sd_ifs"
        if [ -n "$_sd_best_ip" ]; then
            _sd_rec="$_sd_best_ip"
            _sd_rec_reason="fastest"
        fi
    fi

    # ── Display ──
    echo ""
    echo -e "  ${A}Select DNS server:${NC}"
    echo ""

    _sd_n=0
    _sd_list=""

    # Column positions (ANSI escape)
    _C1="\033[8G"   # name column
    _C2="\033[22G"  # ip column
    _C3="\033[42G"  # latency column
    _C4="\033[54G"  # note column

    # Helper: print one DNS row
    # _sd_row NAME IP LATENCY NOTE
    _sd_row() {
        _sd_out="  ${B}${_sd_n}${NC} ${DIM2}›${NC}${_C1}${W}${1}${NC}${_C2}${DIM2}${2}${NC}${_C3}${3}"
        [ -n "${4}" ] && _sd_out="${_sd_out}${_C4}${4}"
        echo -e "$_sd_out"
    }

    # ── Group: Current ──
    if [ -n "$_sd_cur" ]; then
        _sd_n=$((_sd_n + 1))
        _sd_cur_name=""
        _sd_cur_note="${OK}current${NC}"
        if [ -n "$_sd_lan" ] && [ "$_sd_cur" = "$_sd_lan" ]; then
            _sd_cur_name="Router LAN"
        else
            _sd_ifs="$IFS"; IFS='
'
            for _sd_entry in $_DNS_PRESETS; do
                IFS="$_sd_ifs"
                _sd_eip="${_sd_entry##*|}"
                [ "$_sd_cur" = "$_sd_eip" ] && { _sd_cur_name="${_sd_entry%%|*}"; break; }
            done
            IFS="$_sd_ifs"
        fi
        [ -z "$_sd_cur_name" ] && _sd_cur_name="Custom"
        _sd_cl="$(_dns_fmt_latency "$(_sd_lat "$_sd_cur")")"
        _sd_row "$_sd_cur_name" "$_sd_cur" "$_sd_cl" "$_sd_cur_note"
        _sd_list="${_sd_list} ${_sd_cur}"
    fi

    # ── Group: Recommended (if different from current) ──
    if [ -n "$_sd_rec" ]; then
        if [ -z "$_sd_cur" ] || [ "$_sd_rec" != "$_sd_cur" ]; then
            echo ""
            echo -e "  ${DIM2}Recommended${NC}"
            _sd_n=$((_sd_n + 1))
            _sd_rec_name=""
            if [ -n "$_sd_lan" ] && [ "$_sd_rec" = "$_sd_lan" ]; then
                _sd_rec_name="Router LAN"
            else
                _sd_ifs="$IFS"; IFS='
'
                for _sd_entry in $_DNS_PRESETS; do
                    IFS="$_sd_ifs"
                    _sd_eip="${_sd_entry##*|}"
                    [ "$_sd_rec" = "$_sd_eip" ] && { _sd_rec_name="${_sd_entry%%|*}"; break; }
                done
                IFS="$_sd_ifs"
            fi
            [ -z "$_sd_rec_name" ] && _sd_rec_name="$_sd_rec"
            _sd_cl="$(_dns_fmt_latency "$(_sd_lat "$_sd_rec")")"
            _sd_row "$_sd_rec_name" "$_sd_rec" "$_sd_cl" "${V}★ ${_sd_rec_reason}${NC}"
            _sd_list="${_sd_list} ${_sd_rec}"
        fi
    fi

    # ── Group: Router LAN (if not already shown) ──
    _sd_lan_shown=0
    if [ -n "$_sd_lan" ]; then
        if [ "$_sd_cur" = "$_sd_lan" ] || { [ -n "$_sd_rec" ] && [ "$_sd_rec" = "$_sd_lan" ]; }; then
            _sd_lan_shown=1
        fi
        if [ "$_sd_lan_shown" -eq 0 ]; then
            echo ""
            if [ "$_sd_sb_active" -eq 1 ]; then
                echo -e "  ${DIM2}Local${NC}  ${DIM2}(→ Sing-Box)${NC}"
            else
                echo -e "  ${DIM2}Local${NC}"
            fi
            _sd_n=$((_sd_n + 1))
            _sd_cl="$(_dns_fmt_latency "$(_sd_lat "$_sd_lan")")"
            _sd_row "Router LAN" "$_sd_lan" "$_sd_cl" ""
            _sd_list="${_sd_list} ${_sd_lan}"
        fi
    fi

    # ── Group: Public DNS (skip current & recommended, sorted by latency) ──
    _sd_sortbuf=""
    _sd_ifs="$IFS"; IFS='
'
    for _sd_entry in $_DNS_PRESETS; do
        IFS="$_sd_ifs"
        _sd_name="${_sd_entry%%|*}"
        _sd_ip="${_sd_entry##*|}"
        [ -n "$_sd_cur" ] && [ "$_sd_cur" = "$_sd_ip" ] && continue
        [ -n "$_sd_rec" ] && [ "$_sd_rec" = "$_sd_ip" ] && continue
        _sd_ms="$(_sd_lat "$_sd_ip")"
        # Pad for sort: strip unit suffix, zero-pad, fail/ok go last
        _sd_ms_num="$(echo "$_sd_ms" | tr -dc '0-9')"
        case "$_sd_ms" in
            fail) _sd_sort_key="99998" ;;
            ok)   _sd_sort_key="99997" ;;
            *)    _sd_sort_key="$(printf '%05d' "$_sd_ms_num" 2>/dev/null || echo "99999")" ;;
        esac
        _sd_sortbuf="${_sd_sortbuf:+${_sd_sortbuf}
}${_sd_sort_key}|${_sd_name}|${_sd_ip}"
    done
    IFS="$_sd_ifs"
    _sd_sorted="$(echo "$_sd_sortbuf" | sort -t'|' -k1,1n)"

    _sd_pub_header=0
    _sd_ifs="$IFS"; IFS='
'
    for _sd_sline in $_sd_sorted; do
        IFS="$_sd_ifs"
        [ -z "$_sd_sline" ] && continue
        _sd_name="$(echo "$_sd_sline" | cut -d'|' -f2)"
        _sd_ip="$(echo "$_sd_sline" | cut -d'|' -f3)"
        if [ "$_sd_pub_header" -eq 0 ]; then
            echo ""
            if [ "$_sd_sb_active" -eq 1 ]; then
                echo -e "  ${DIM2}Public DNS${NC}  ${WARN_C}(bypasses Sing-Box)${NC}"
            else
                echo -e "  ${DIM2}Public DNS${NC}"
            fi
            _sd_pub_header=1
        fi
        _sd_n=$((_sd_n + 1))
        _sd_cl="$(_dns_fmt_latency "$(_sd_lat "$_sd_ip")")"
        _sd_row "$_sd_name" "$_sd_ip" "$_sd_cl" ""
        _sd_list="${_sd_list} ${_sd_ip}"
    done
    IFS="$_sd_ifs"

    echo ""
    echo -e "  ${B}0${NC} ${DIM2}›${NC}${_C1}${W}Custom${NC}${_C2}${DIM2}enter manually${NC}"
    echo ""

    # Prompt with default recommendation
    _sd_max="$_sd_n"
    _sd_def_n=""
    if [ -n "$_sd_rec" ]; then
        _sd_ri=0
        for _sd_rip in $_sd_list; do
            _sd_ri=$((_sd_ri + 1))
            [ "$_sd_rip" = "$_sd_rec" ] && { _sd_def_n="$_sd_ri"; break; }
        done
    fi

    while true; do
        if [ -n "$_sd_def_n" ]; then
            echo -ne "  ${A}>${NC} ${DIM2}[${_sd_def_n}]${NC} "; read -r _sd_choice || true
        else
            echo -ne "  ${A}>${NC} "; read -r _sd_choice || true
        fi
        sigint_caught && { rm -rf "$_sd_tmp"; return 1; }
        _sd_choice="$(printf '%s' "${_sd_choice:-}" | tr -d '\001-\037\177')"

        # Empty = select recommendation (or cancel if no recommendation)
        if [ -z "$_sd_choice" ]; then
            if [ -n "$_sd_def_n" ]; then
                _sd_choice="$_sd_def_n"
            else
                rm -rf "$_sd_tmp"; return 1
            fi
        fi

        # Custom prompt
        if [ "$_sd_choice" = "0" ]; then
            rm -rf "$_sd_tmp"
            while true; do
                prompt _sd_custom "DNS server (IPv4)" "" || return 1
                sigint_caught && return 1
                [ -z "$_sd_custom" ] && return 1
                validate_ipv4 "$_sd_custom" || continue
                break
            done
            eval "$_sd_var=\$_sd_custom"
            return 0
        fi

        case "$_sd_choice" in *[!0-9]*) warn "Invalid selection"; continue ;; esac
        if [ "$_sd_choice" -lt 1 ] 2>/dev/null; then warn "Invalid selection"; continue; fi
        if [ "$_sd_choice" -gt "$_sd_max" ] 2>/dev/null; then warn "Invalid selection"; continue; fi

        # Map choice to IP from ordered list
        _sd_i=0; _sd_result=""
        for _sd_ip in $_sd_list; do
            _sd_i=$((_sd_i + 1))
            if [ "$_sd_i" = "$_sd_choice" ]; then _sd_result="$_sd_ip"; fi
        done

        if [ -z "$_sd_result" ]; then
            warn "Invalid selection"; continue
        fi

        rm -rf "$_sd_tmp"
        eval "$_sd_var=\$_sd_result"
        break
    done
    return 0
}

# ─── DNS & Network diagnostics (unified) ──────────────────────────────

# do_dns_network_test IFACE [PEER_IP] [HOSTNAME] [IS_ONLINE]
# Full DNS & network diagnostic. Called from both peer and interface menus.
do_dns_network_test() {
    _dt_iface="$1"
    _dt_pip="${2:-}"        # peer VPN IP (empty = interface-level test)
    _dt_fqdn="${3:-}"       # peer hostname (empty = skip hostname check)
    _dt_online="${4:-0}"    # 1 if peer is online

    _dt_dns="$(iface_get "$_dt_iface" dns)"
    _dt_lan="$(detect_router_lan_ip 2>/dev/null || true)"
    _dt_is_local=0
    [ -n "$_dt_lan" ] && [ -n "$_dt_dns" ] && [ "$_dt_dns" = "$_dt_lan" ] && _dt_is_local=1
    _dt_sb_chain=0
    [ "${SB_DNS:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 1 ] && _dt_sb_chain=1
    _TC="\033[36G"

    echo ""
    echo -e "  ${V}── DNS & Network Diagnostics ──${NC}"
    echo ""

    # Header
    if [ -n "$_dt_pip" ]; then
        echo -e "  ${A}Interface:${NC} ${W}${_dt_iface}${NC}  ${A}Peer:${NC} ${W}${_dt_pip}${NC}"
    else
        echo -e "  ${A}Interface:${NC} ${W}${_dt_iface}${NC}"
    fi
    if [ -n "$_dt_dns" ]; then
        if [ "$_dt_sb_chain" -eq 1 ] && [ "${PK_LINKED:-0}" -eq 1 ]; then
            echo -e "  ${A}DNS:${NC}       ${W}${_dt_dns}${NC}  ${DIM2}│ peer → dnsmasq → Sing-Box${NC}"
        elif [ "$_dt_sb_chain" -eq 1 ]; then
            echo -e "  ${A}DNS:${NC}       ${W}${_dt_dns}${NC}  ${DIM2}│ dnsmasq → Sing-Box${NC}"
        elif [ "${DM_DNSCRYPT:-0}" -eq 1 ]; then
            echo -e "  ${A}DNS:${NC}       ${W}${_dt_dns}${NC}  ${DIM2}│ dnsmasq → DNSCrypt${NC}"
        elif [ "${DM_STUBBY:-0}" -eq 1 ]; then
            echo -e "  ${A}DNS:${NC}       ${W}${_dt_dns}${NC}  ${DIM2}│ dnsmasq → Stubby${NC}"
        else
            echo -e "  ${A}DNS:${NC}       ${W}${_dt_dns}${NC}"
        fi
    else
        echo -e "  ${A}DNS:${NC}       ${DIM2}not configured${NC}"
    fi

    # ── 1. Internet ──
    echo ""
    echo -e "  ${A}1. Internet${NC}"
    echo -ne "  ${DIM2}Connectivity${NC}${_TC}"
    if check_internet; then
        echo -e "${ICO_OK} ${OK}Available${NC}"
    else
        echo -e "${ICO_ERR} ${ERR}No internet${NC}"
        echo -e "  ${WARN_C}All DNS tests may fail — check WAN connection${NC}"
    fi

    # ── 2. DNS Server ──
    echo ""
    echo -e "  ${A}2. DNS Server${NC}"
    if [ -n "$_dt_dns" ]; then
        echo -ne "  ${DIM2}Responds to queries${NC}${_TC}"
        if check_dns_server "$_dt_dns"; then
            echo -e "${ICO_OK} ${OK}Yes${NC}"
        else
            echo -e "${ICO_ERR} ${ERR}No${NC}"
        fi
    else
        echo -e "  ${DIM2}No DNS configured for this interface${NC}"
    fi

    # ── 3. Port 53 (ISP blocking) ──
    echo ""
    echo -e "  ${A}3. Port 53 Blocking${NC}"
    _dt_p53_ok=0
    for _dt_ext in 1.1.1.1 8.8.8.8; do
        echo -ne "  ${DIM2}${_dt_ext}${NC}${_TC}"
        if check_dns_port53 "$_dt_ext"; then
            echo -e "${ICO_OK} ${OK}Open${NC}"
            _dt_p53_ok=1
        else
            echo -e "${ICO_WARN} ${WARN_C}Blocked / timeout${NC}"
        fi
    done
    [ "$_dt_p53_ok" -eq 0 ] && \
        echo -e "  ${WARN_C}ISP may be blocking DNS port 53${NC}"

    # ── 4. DNS Poisoning ──
    echo ""
    echo -e "  ${A}4. DNS Poisoning${NC}"
    _dt_poison_ok=1
    for _dt_dom in facebook.com instagram.com; do
        echo -ne "  ${DIM2}${_dt_dom}${NC}${_TC}"
        check_dns_poisoning "$_dt_dom"
        _dt_pr=$?
        if [ "$_dt_pr" -eq 0 ]; then
            echo -e "${ICO_OK} ${OK}Clean${NC}"
        elif [ "$_dt_pr" -eq 1 ]; then
            echo -e "${ICO_ERR} ${ERR}127.x.x.x detected${NC}"
            _dt_poison_ok=0
        else
            echo -e "${ICO_WARN} ${WARN_C}No response${NC}"
        fi
    done
    echo -ne "  ${DIM2}facebook ≠ instagram IP${NC}${_TC}"
    check_dns_same_ip "facebook.com" "instagram.com"
    _dt_si=$?
    if [ "$_dt_si" -eq 0 ]; then
        echo -e "${ICO_OK} ${OK}Different${NC}"
    elif [ "$_dt_si" -eq 1 ]; then
        echo -e "${ICO_ERR} ${ERR}Same IP — poisoned${NC}"
        _dt_poison_ok=0
    else
        echo -e "${ICO_WARN} ${WARN_C}Can't check${NC}"
    fi
    [ "$_dt_poison_ok" -eq 0 ] && \
        echo -e "  ${WARN_C}DNS responses appear tampered${NC}"

    # ── 5. DoH vs Plain DNS ──
    # Only meaningful when DNS is a direct external server (not via router/VPN/Sing-Box).
    # If DNS = Router LAN, Sing-Box chain, DNSCrypt, Stubby, or any local resolver —
    # the router resolves through its own chain (VPN, Sing-Box, etc.) so the IP will
    # differ from Cloudflare DoH. That's normal, not poisoning.
    if have_cmd curl; then
        _dt_doh_skip=""
        [ "$_dt_is_local" -eq 1 ] && _dt_doh_skip="DNS via router (resolves through local chain)"
        [ "$_dt_sb_chain" -eq 1 ] && _dt_doh_skip="DNS via Sing-Box"
        [ "${DM_DNSCRYPT:-0}" -eq 1 ] && [ "$_dt_is_local" -eq 1 ] && _dt_doh_skip="DNS via DNSCrypt"
        [ "${DM_STUBBY:-0}" -eq 1 ] && [ "$_dt_is_local" -eq 1 ] && _dt_doh_skip="DNS via Stubby"

        echo ""
        echo -e "  ${A}5. DoH Comparison${NC}"
        if [ -n "$_dt_doh_skip" ]; then
            echo -e "  ${DIM2}Skipped — ${_dt_doh_skip} (mismatch expected)${NC}"
        else
            echo -ne "  ${DIM2}DoH available${NC}${_TC}"
            _dt_doh_ip="$(check_doh "facebook.com")"
            if [ -n "$_dt_doh_ip" ]; then
                echo -e "${ICO_OK} ${OK}Yes${NC}"
                echo -ne "  ${DIM2}Plain DNS = DoH${NC}${_TC}"
                _dt_doh_r=2
                _dt_plain="$(_nslookup_ips "facebook.com" | head -1)"
                if [ -n "$_dt_doh_ip" ] && [ -n "$_dt_plain" ]; then
                    if [ "$_dt_doh_ip" = "$_dt_plain" ]; then _dt_doh_r=0; else _dt_doh_r=1; fi
                fi
                if [ "$_dt_doh_r" -eq 0 ]; then
                    echo -e "${ICO_OK} ${OK}Match${NC}"
                elif [ "$_dt_doh_r" -eq 1 ]; then
                    echo -e "${ICO_ERR} ${ERR}Mismatch — DNS may be tampered${NC}"
                else
                    echo -e "${ICO_WARN} ${WARN_C}Can't compare${NC}"
                fi
            else
                echo -e "${ICO_WARN} ${WARN_C}Unavailable${NC}"
            fi
        fi
    fi

    # ── 6. Firewall ──
    _dt_zone="$(find_zone_for_interface "$_dt_iface" 2>/dev/null || true)"
    if [ -n "$_dt_zone" ] && [ "$_dt_is_local" -eq 1 ]; then
        echo ""
        echo -e "  ${A}6. Firewall${NC}"
        _dt_zi="$(find_zone_index "$_dt_zone" || true)"
        if [ -n "$_dt_zi" ]; then
            _dt_input="$(uci -q get "firewall.@zone[$_dt_zi].input" || echo "DROP")"
            echo -ne "  ${DIM2}Zone allows DNS${NC}${_TC}"
            if [ "$_dt_input" = "ACCEPT" ]; then
                echo -e "${ICO_OK} ${OK}Yes${NC} ${DIM2}(input=ACCEPT)${NC}"
            else
                _dt_dns_ok=0; _dt_ri=0
                while uci -q get "firewall.@rule[$_dt_ri]" >/dev/null 2>&1; do
                    _dt_src="$(uci -q get "firewall.@rule[$_dt_ri].src" || true)"
                    _dt_dp="$(uci -q get "firewall.@rule[$_dt_ri].dest_port" || true)"
                    _dt_tgt="$(uci -q get "firewall.@rule[$_dt_ri].target" || true)"
                    [ "$_dt_src" = "$_dt_zone" ] && [ "$_dt_dp" = "53" ] && [ "$_dt_tgt" = "ACCEPT" ] && { _dt_dns_ok=1; break; }
                    _dt_ri=$((_dt_ri + 1))
                done
                if [ "$_dt_dns_ok" -eq 1 ]; then
                    echo -e "${ICO_OK} ${OK}Yes${NC} ${DIM2}(port 53 rule)${NC}"
                else
                    echo -e "${ICO_ERR} ${ERR}No${NC} ${DIM2}(${_dt_input}, no port 53)${NC}"
                fi
            fi
        fi
    fi

    # ── 7. DNS Chain ──
    echo ""
    echo -e "  ${A}7. DNS Chain${NC}"
    echo -ne "  ${DIM2}dnsmasq running${NC}${_TC}"
    if pgrep -x dnsmasq >/dev/null 2>&1; then
        echo -e "${ICO_OK} ${OK}Yes${NC}"
    else
        echo -e "${ICO_ERR} ${ERR}No${NC}"
    fi

    if [ "$_dt_sb_chain" -eq 1 ] || [ "${SB_RUNNING:-0}" -eq 1 ]; then
        echo -ne "  ${DIM2}Sing-Box process${NC}${_TC}"
        if [ "${SB_RUNNING:-0}" -eq 1 ]; then
            echo -e "${ICO_OK} ${OK}Running${NC}"
        else
            echo -e "${ICO_ERR} ${ERR}Not running${NC}"
        fi
        echo -ne "  ${DIM2}Sing-Box DNS :53${NC}${_TC}"
        if [ "${SB_DNS:-0}" -eq 1 ]; then
            echo -e "${ICO_OK} ${OK}Listening${NC}"
        else
            echo -e "${ICO_ERR} ${ERR}Not listening${NC}"
        fi
        if [ "${SB_CFG_OK:-0}" -eq 1 ]; then
            echo -e "  ${DIM2}Sing-Box config${NC}${_TC}${ICO_OK} ${OK}Valid${NC}"
        elif [ -f /etc/sing-box/config.json ]; then
            echo -e "  ${DIM2}Sing-Box config${NC}${_TC}${ICO_ERR} ${ERR}Invalid${NC}"
        fi
        if ip link show tun0 >/dev/null 2>&1; then
            if [ "${SB_ROUTE_OK:-0}" -eq 1 ]; then
                echo -e "  ${DIM2}VPN routing table${NC}${_TC}${ICO_OK} ${OK}Exists${NC}"
            else
                echo -e "  ${DIM2}VPN routing table${NC}${_TC}${ICO_WARN} ${WARN_C}Missing${NC}"
            fi
        fi
        echo -ne "  ${DIM2}dnsmasq → ${CFG_SB_DNS_IP}${NC}${_TC}"
        if [ "${DM_FWD:-0}" -eq 1 ]; then
            echo -e "${ICO_OK} ${OK}Configured${NC}"
        else
            echo -e "${ICO_ERR} ${ERR}Not forwarding${NC}"
        fi
        if [ "$_dt_is_local" -eq 0 ] && [ -n "$_dt_dns" ]; then
            echo -e "  ${WARN_C}DNS ${_dt_dns} bypasses the Sing-Box chain${NC}"
        fi
    fi

    # DNSCrypt / Stubby
    if [ "${DM_DNSCRYPT:-0}" -eq 1 ]; then
        echo -ne "  ${DIM2}DNSCrypt (127.0.0.53)${NC}${_TC}"
        if pgrep -f "dnscrypt-proxy" >/dev/null 2>&1; then
            echo -e "${ICO_OK} ${OK}Running${NC}"
        else
            echo -e "${ICO_ERR} ${ERR}Not running${NC}"
        fi
    fi
    if [ "${DM_STUBBY:-0}" -eq 1 ]; then
        echo -ne "  ${DIM2}Stubby (127.0.0.1#5453)${NC}${_TC}"
        if pgrep -f "stubby" >/dev/null 2>&1; then
            echo -e "${ICO_OK} ${OK}Running${NC}"
        else
            echo -e "${ICO_ERR} ${ERR}Not running${NC}"
        fi
    fi

    # ── 8. Podkop ──
    if [ "${PK_INSTALLED:-0}" -eq 1 ]; then
        echo ""
        echo -e "  ${A}8. Podkop${NC}"
        echo -ne "  ${DIM2}Linked to ${_dt_iface}${NC}${_TC}"
        if [ "${PK_LINKED:-0}" -eq 1 ]; then
            echo -e "${ICO_OK} ${OK}Yes${NC}"
        else
            echo -e "${DIM2}No${NC}"
        fi
        echo -ne "  ${DIM2}nftables PodkopTable${NC}${_TC}"
        if [ "${PK_NFT_ACTIVE:-0}" -eq 1 ]; then
            echo -e "${ICO_OK} ${OK}Active${NC}"
        else
            echo -e "${ICO_WARN} ${WARN_C}Missing${NC}"
        fi
    fi

    # ── 9. Hostname ──
    if [ -n "$_dt_fqdn" ]; then
        echo ""
        echo -e "  ${A}9. Hostname${NC}  ${W}${_dt_fqdn}${NC}"
        if [ "$_dt_is_local" -eq 1 ]; then
            echo -ne "  ${DIM2}Will resolve via dnsmasq${NC}${_TC}"
            if pgrep -x dnsmasq >/dev/null 2>&1; then
                echo -e "${ICO_OK} ${OK}Yes${NC}"
            else
                echo -e "${ICO_ERR} ${ERR}dnsmasq not running${NC}"
            fi
        else
            echo -e "  ${DIM2}DNS → router${NC}${_TC}${ICO_ERR} ${ERR}No — won't resolve${NC}"
            [ -n "$_dt_lan" ] && echo -e "  ${DIM2}Change DNS to ${_dt_lan} for hostnames to work${NC}"
        fi
    elif [ -z "$_dt_pip" ]; then
        # Interface-level: check if any hostrecords exist for this interface
        _dt_has_hr=0; _dt_hi=0
        while uci -q get "dhcp.@hostrecord[$_dt_hi]" >/dev/null 2>&1; do
            _dt_hli="$(uci -q get "dhcp.@hostrecord[$_dt_hi]._liminal_iface" || true)"
            [ "$_dt_hli" = "$_dt_iface" ] && { _dt_has_hr=1; break; }
            _dt_hi=$((_dt_hi + 1))
        done
        if [ "$_dt_has_hr" -eq 1 ]; then
            echo ""
            echo -e "  ${A}9. Hostnames${NC}"
            if [ "$_dt_is_local" -eq 1 ]; then
                echo -ne "  ${DIM2}Will resolve via dnsmasq${NC}${_TC}"
                if pgrep -x dnsmasq >/dev/null 2>&1; then
                    echo -e "${ICO_OK} ${OK}Yes${NC}"
                else
                    echo -e "${ICO_ERR} ${ERR}dnsmasq not running${NC}"
                fi
            else
                echo -e "  ${DIM2}DNS → router${NC}${_TC}${ICO_ERR} ${ERR}No — won't resolve${NC}"
                [ -n "$_dt_lan" ] && echo -e "  ${DIM2}Change DNS to ${_dt_lan} for hostrecords to work${NC}"
            fi
        fi
    fi

    # ── 10. Connectivity ──
    if [ "$_dt_online" -eq 1 ] && [ -n "$_dt_pip" ]; then
        echo ""
        echo -e "  ${A}10. Peer Connectivity${NC}"
        echo -ne "  ${DIM2}Ping ${_dt_pip}${NC}${_TC}"
        if ping -c1 -W2 "$_dt_pip" >/dev/null 2>&1; then
            echo -e "${ICO_OK} ${OK}Reachable${NC}"
        else
            echo -e "${ICO_WARN} ${WARN_C}No reply${NC}"
        fi
    fi

    echo ""
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

# prompt_custom_hostname IFACE_DOMAIN LAN_DOMAIN
# Interactive 3-option submenu for composing a hostname:
#   1 → iface-scoped  (hostname.IFACE_DOMAIN, e.g. mybox.awg1.lan)
#   2 → lan-scoped    (hostname.LAN_DOMAIN,   e.g. mybox.lan)
#   3 → literal FQDN  (hostname used as typed, with chars sanitized)
# Output: sets the global CUSTOM_HOSTNAME_RESULT. Empty = cancelled/invalid.
prompt_custom_hostname() {
    _ch_ifd="$1"; _ch_lan="$2"
    CUSTOM_HOSTNAME_RESULT=""
    echo ""
    echo -e "    ${B}1${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(hostname.${_ch_ifd})${NC}"
    echo -e "    ${B}2${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(hostname.${_ch_lan})${NC}"
    echo -e "    ${B}3${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(hostname — literal FQDN)${NC}"
    echo -e "    ${DIM2}Enter › Cancel${NC}"
    echo ""
    echo -ne "  ${A}>${NC} "; read -r _ch_sub || true
    sigint_caught && return 1
    _ch_suffix=""; _ch_literal=0
    case "${_ch_sub:-}" in
        1) _ch_suffix=".${_ch_ifd}" ;;
        2) _ch_suffix=".${_ch_lan}" ;;
        3) _ch_literal=1 ;;
        *) return 1 ;;
    esac
    while true; do
        prompt _ch_name "Hostname" "" || return 1
        sigint_caught && return 1
        [ -z "$_ch_name" ] && return 1
        if [ "$_ch_literal" -eq 1 ]; then
            _ch_clean="$(printf '%s' "$_ch_name" | sed 's/[^a-zA-Z0-9.-]//g')"
            _ch_clean="${_ch_clean#.}"; _ch_clean="${_ch_clean%.}"
            [ -z "$_ch_clean" ] && { warn "Invalid hostname"; continue; }
            CUSTOM_HOSTNAME_RESULT="$_ch_clean"
        else
            _ch_san="$(sanitize_hostname "$_ch_name")"
            [ -z "$_ch_san" ] && { warn "Invalid hostname"; continue; }
            CUSTOM_HOSTNAME_RESULT="${_ch_san}${_ch_suffix}"
        fi
        return 0
    done
}

# resolve_custom_hostname INPUT IFACE_DOMAIN LAN_DOMAIN — turn user input into
# a full FQDN using precedence rules that work for any LAN domain:
#   - empty input → empty output (signals "cancel")
#   - input ends in LAN_DOMAIN (or equals it)  → used as-is
#   - input contains a dot                     → LAN_DOMAIN appended
#                                                ("web.foo" → "web.foo.<lan>")
#   - bare label (no dot)                      → IFACE_DOMAIN appended
#                                                ("foo" → "foo.<iface>.<lan>")
# Characters outside [A-Za-z0-9.-] are stripped silently.
resolve_custom_hostname() {
    _rh_in="$1"; _rh_ifd="$2"; _rh_lan="$3"
    _rh_clean="$(printf '%s' "$_rh_in" | sed 's/[^a-zA-Z0-9.-]//g')"
    [ -z "$_rh_clean" ] && { printf ''; return 1; }
    # Collapse leading/trailing dots if user pasted awkward input.
    _rh_clean="${_rh_clean#.}"; _rh_clean="${_rh_clean%.}"
    [ -z "$_rh_clean" ] && { printf ''; return 1; }

    # Already in the LAN zone — use literal.
    case "$_rh_clean" in
        "$_rh_lan"|*".$_rh_lan") printf '%s\n' "$_rh_clean"; return 0 ;;
    esac
    # Dotted short form outside LAN zone — append LAN domain.
    case "$_rh_clean" in
        *.*) printf '%s.%s\n' "$_rh_clean" "$_rh_lan"; return 0 ;;
    esac
    # Bare label — full iface-scoped path.
    printf '%s.%s\n' "$_rh_clean" "$_rh_ifd"
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
    svc_restart dnsmasq
    echo -e "  ${ICO_OK} ${OK}DNS:${NC} ${_ah_fqdn} → ${_ah_ip}"
}

# Remove hostrecord for a specific peer
remove_peer_hostrecord() {
    _rh_idx="$(find_hostrecord "$1" "$2" 2>/dev/null)" || return 0
    _rh_fqdn="$(uci -q get "dhcp.@hostrecord[$_rh_idx].name" || true)"
    uci delete "dhcp.@hostrecord[$_rh_idx]"
    uci commit dhcp
    svc_restart dnsmasq
    [ -n "$_rh_fqdn" ] && echo -e "  ${B}Removed${NC} DNS: ${_rh_fqdn}"
    return 0
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
        svc_restart dnsmasq
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
        svc_restart dnsmasq
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
    _chw_dns="$(iface_get "$_chw_iface" dns)"
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
            warn "${_chw_label}: Sing-Box not listening on ${CFG_SB_DNS_IP}:53"
            _chw_ok=1
        elif [ "${DM_FWD:-0}" -eq 0 ]; then
            warn "${_chw_label}: dnsmasq missing server ${CFG_SB_DNS_IP}"
            _chw_ok=1
        elif [ "${PK_DNS_VIA_ROUTER:-0}" -eq 1 ]; then
            echo -e "  ${ICO_OK} ${DIM2}${_chw_label}: peer → dnsmasq → Sing-Box (hostrecords OK)${NC}"
        fi
        if [ "${DM_NORESOLV:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 0 ]; then
            warn "${_chw_label}: noresolv=1 but no server ${CFG_SB_DNS_IP} — DNS broken"
            _chw_ok=1
        fi
        if [ "${PK_DTD:-0}" -eq 1 ]; then
            warn "Podkop: dont_touch_dhcp=1 — verify dnsmasq config manually"
            if [ "${DM_FWD:-0}" -eq 0 ]; then
                warn "Add 'list server ${CFG_SB_DNS_IP}' to dhcp config"
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

# validate_ipv4_cidr CIDR — "IP/mask" with mask 0-32. Uses validate_ipv4 for
# the IP portion (re-warns on bad IP).
validate_ipv4_cidr() {
    case "${1:-}" in
        */0|*/[1-9]|*/[12][0-9]|*/3[0-2]) ;;
        *) warn "Invalid CIDR mask in: ${1:-<empty>}"; return 1 ;;
    esac
    validate_ipv4 "${1%/*}"
}

# validate_ipv6_cidr CIDR — loose "any:colons/mask0-128" check. Only syntactic,
# no range/expansion validation (enough to catch obvious typos).
validate_ipv6_cidr() {
    _cv="${1:-}"
    case "$_cv" in
        *:*/*) ;;
        *) warn "Invalid IPv6 CIDR: ${_cv:-<empty>}"; return 1 ;;
    esac
    _mask="${_cv##*/}"
    case "$_mask" in
        ''|*[!0-9]*) warn "Invalid IPv6 mask: ${_mask}"; return 1 ;;
    esac
    [ "$_mask" -ge 0 ] && [ "$_mask" -le 128 ] 2>/dev/null || {
        warn "IPv6 mask out of range 0-128: ${_mask}"; return 1
    }
    # Addr part must contain at least one ':'
    case "${_cv%/*}" in
        *:*) return 0 ;;
        *) warn "Invalid IPv6 address: ${_cv%/*}"; return 1 ;;
    esac
}

# validate_allowed_ips STR — comma/space-separated list of IPv4[/N] or
# IPv6[/N] entries. Warns on the first bad entry.
validate_allowed_ips() {
    _al="${1:-}"
    [ -z "$_al" ] && { warn "AllowedIPs is empty"; return 1; }
    # Split on comma and/or whitespace
    _oldifs="$IFS"; IFS=', 	'
    # shellcheck disable=SC2086
    set -- $_al
    IFS="$_oldifs"
    for _e in "$@"; do
        [ -z "$_e" ] && continue
        case "$_e" in
            *:*) validate_ipv6_cidr "$_e" || return 1 ;;
            */*) validate_ipv4_cidr "$_e" || return 1 ;;
            *)   validate_ipv4 "$_e"      || return 1 ;;
        esac
    done
    return 0
}

# validate_fqdn STR — loose FQDN check (labels 1-63 chars, letters/digits/hyphen,
# no leading/trailing hyphen per label, at least one dot OR single-label name).
validate_fqdn() {
    _fq="${1:-}"
    [ -z "$_fq" ] && { warn "Hostname is empty"; return 1; }
    [ "${#_fq}" -le 253 ] || { warn "Hostname too long (>253 chars)"; return 1; }
    printf '%s' "$_fq" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' || {
        warn "Invalid hostname: ${_fq}"; return 1
    }
}

# validate_host_or_ip STR — accepts IPv4, IPv6 literal, or FQDN.
validate_host_or_ip() {
    _hv="${1:-}"
    case "$_hv" in
        *:*) return 0 ;;  # IPv6 literal — accept without deeper check
        *[!0-9.]*)
            validate_fqdn "$_hv"
            return $?
            ;;
        *)
            validate_ipv4 "$_hv"
            return $?
            ;;
    esac
}

# validate_generated_conf TEXT — sanity-check a rendered WG/AWG .conf before
# it leaves the tool. Catches corrupted UCI values that would give the client
# a dead config. Warns on first failure and returns 1.
validate_generated_conf() {
    _gc="${1:-}"
    [ -z "$_gc" ] && { warn "Generated config is empty"; return 1; }

    # sed-based: takes everything after the first '=' — awk -F' *= *' would
    # wrongly split on '=' that appears inside values (e.g. base64 padding).
    _gc_get() {
        printf '%s\n' "$_gc" \
            | sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" \
            | head -n1
    }

    _gc_priv="$(_gc_get PrivateKey)"
    _gc_pub="$(_gc_get PublicKey)"
    _gc_psk="$(_gc_get PresharedKey)"
    _gc_addr="$(_gc_get Address)"
    _gc_aips="$(_gc_get AllowedIPs)"
    _gc_ep="$(_gc_get Endpoint)"
    _gc_mtu="$(_gc_get MTU)"
    _gc_dns="$(_gc_get DNS)"
    _gc_ka="$(_gc_get PersistentKeepAlive)"

    # Required fields
    validate_wg_key "$_gc_priv" 2>/dev/null || { warn "Bad client PrivateKey in generated conf"; return 1; }
    validate_wg_key "$_gc_pub"  2>/dev/null || { warn "Bad server PublicKey in generated conf"; return 1; }
    [ -n "$_gc_addr" ] || { warn "Missing Address in generated conf"; return 1; }
    validate_ipv4_cidr "$_gc_addr" 2>/dev/null || { warn "Bad Address: $_gc_addr"; return 1; }
    [ -n "$_gc_aips" ] || { warn "Missing AllowedIPs in generated conf"; return 1; }
    validate_allowed_ips "$_gc_aips" 2>/dev/null || { warn "Bad AllowedIPs: $_gc_aips"; return 1; }
    [ -n "$_gc_ep" ] || { warn "Missing Endpoint in generated conf"; return 1; }
    _gc_ep_host="${_gc_ep%:*}"
    _gc_ep_port="${_gc_ep##*:}"
    validate_host_or_ip "$_gc_ep_host" 2>/dev/null || { warn "Bad Endpoint host: $_gc_ep_host"; return 1; }
    validate_port        "$_gc_ep_port" 2>/dev/null || { warn "Bad Endpoint port: $_gc_ep_port"; return 1; }

    # Optional fields
    if [ -n "$_gc_psk" ]; then
        validate_wg_key "$_gc_psk" 2>/dev/null || { warn "Bad PresharedKey in generated conf"; return 1; }
    fi
    if [ -n "$_gc_mtu" ]; then
        case "$_gc_mtu" in *[!0-9]*) warn "Bad MTU: $_gc_mtu"; return 1 ;; esac
        [ "$_gc_mtu" -ge 576 ] && [ "$_gc_mtu" -le 65535 ] 2>/dev/null \
            || { warn "MTU out of range: $_gc_mtu"; return 1; }
    fi
    if [ -n "$_gc_ka" ]; then
        case "$_gc_ka" in *[!0-9]*) warn "Bad PersistentKeepAlive: $_gc_ka"; return 1 ;; esac
        [ "$_gc_ka" -le 65535 ] 2>/dev/null || { warn "KeepAlive out of range: $_gc_ka"; return 1; }
    fi
    if [ -n "$_gc_dns" ]; then
        _gc_oi="$IFS"; IFS=','
        # shellcheck disable=SC2086
        set -- $_gc_dns
        IFS="$_gc_oi"
        for _gc_t in "$@"; do
            _gc_t="${_gc_t# }"; _gc_t="${_gc_t% }"
            [ -z "$_gc_t" ] && continue
            validate_host_or_ip "$_gc_t" 2>/dev/null \
                || { warn "Bad DNS entry: $_gc_t"; return 1; }
        done
    fi

    # AWG obfuscation params — enforce ranges from docs.amnezia.org/amnezia-wg.
    _jc="$(_gc_get Jc)"
    _jmin="$(_gc_get Jmin)"
    _jmax="$(_gc_get Jmax)"
    _s1="$(_gc_get S1)"; _s2="$(_gc_get S2)"; _s3="$(_gc_get S3)"; _s4="$(_gc_get S4)"
    _h1="$(_gc_get H1)"; _h2="$(_gc_get H2)"; _h3="$(_gc_get H3)"; _h4="$(_gc_get H4)"

    # NAME VAL LO HI — integer in [LO,HI]. Empty VAL is OK (skip).
    _check_range() {
        [ -z "$2" ] && return 0
        case "$2" in ''|*[!0-9]*) warn "$1 not integer: $2"; return 1 ;; esac
        [ "$2" -ge "$3" ] 2>/dev/null && [ "$2" -le "$4" ] 2>/dev/null \
            || { warn "$1 out of range $3-$4: $2"; return 1; }
        return 0
    }
    _check_range Jc   "$_jc"   0 10   || return 1
    _check_range Jmin "$_jmin" 64 1024 || return 1
    _check_range Jmax "$_jmax" 64 1024 || return 1
    if [ -n "$_jmin" ] && [ -n "$_jmax" ]; then
        [ "$_jmin" -le "$_jmax" ] 2>/dev/null \
            || { warn "Jmin ($_jmin) must be <= Jmax ($_jmax)"; return 1; }
    fi
    _check_range S1 "$_s1" 0 64 || return 1
    _check_range S2 "$_s2" 0 64 || return 1
    _check_range S3 "$_s3" 0 64 || return 1
    _check_range S4 "$_s4" 0 32 || return 1
    _check_range H1 "$_h1" 0 4294967295 || return 1
    _check_range H2 "$_h2" 0 4294967295 || return 1
    _check_range H3 "$_h3" 0 4294967295 || return 1
    _check_range H4 "$_h4" 0 4294967295 || return 1
    # H1-H4 must all be distinct — overlapping magic bytes break dispatch.
    # NAME_A VAL_A NAME_B VAL_B — fail if A and B both set and equal.
    _check_distinct() {
        { [ -z "$2" ] || [ -z "$4" ]; } && return 0
        [ "$2" != "$4" ] || { warn "$1/$3 collide — must be distinct (both=$2)"; return 1; }
    }
    _check_distinct H1 "$_h1" H2 "$_h2" || return 1
    _check_distinct H1 "$_h1" H3 "$_h3" || return 1
    _check_distinct H1 "$_h1" H4 "$_h4" || return 1
    _check_distinct H2 "$_h2" H3 "$_h3" || return 1
    _check_distinct H2 "$_h2" H4 "$_h4" || return 1
    _check_distinct H3 "$_h3" H4 "$_h4" || return 1
    # I1-I5 — hex blob; accept '0x' prefix and optional whitespace
    for _gc_k in I1 I2 I3 I4 I5; do
        _gc_v="$(_gc_get "$_gc_k")"
        [ -z "$_gc_v" ] && continue
        _gc_vs="${_gc_v#0x}"
        _gc_vs="$(printf '%s' "$_gc_vs" | tr -d ' ')"
        case "$_gc_vs" in
            ''|*[!0-9a-fA-F]*) warn "Bad $_gc_k (not hex): $_gc_v"; return 1 ;;
        esac
        # Hex blobs must be even-length (whole bytes)
        case $(( ${#_gc_vs} % 2 )) in
            0) ;;
            *) warn "$_gc_k hex has odd length: $_gc_v"; return 1 ;;
        esac
    done
    return 0
}

# validate_wg_key KEY — a WireGuard/AmneziaWG key is 32 bytes of base64,
# which is always exactly 44 characters long and ends with '='. Matches the
# regex LuCI uses (luci-proto-amneziawg/amneziawg.js).
validate_wg_key() {
    case "$1" in
        '') warn "Key is empty"; return 1 ;;
    esac
    if ! printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
        warn "Invalid key — must be 44-char base64 ending with '='"
        return 1
    fi
    return 0
}

# validate_fwmark INPUT — decimal (1..2^32-1) or 0xHEX.
validate_fwmark() {
    case "$1" in
        ''|off|OFF) return 0 ;;
        0x*)
            _h="${1#0x}"
            case "$_h" in ''|*[!0-9A-Fa-f]*) warn "Invalid hex fwmark: $1"; return 1 ;; esac
            return 0
            ;;
        *)
            case "$1" in *[!0-9]*) warn "fwmark must be decimal or 0xHEX"; return 1 ;; esac
            return 0
            ;;
    esac
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

# detect_lan_zone — auto-find the FW zone that acts as LAN.
# Heuristic: zone literally named "lan" → else first zone whose `network`
# list contains a UCI network interface with private RFC1918 `ipaddr` → else
# hardcoded "lan" (matches fallback callers expect).
detect_lan_zone() {
    if zone_exists "lan"; then echo "lan"; return 0; fi
    _dz_i=0
    while uci -q get "firewall.@zone[$_dz_i]" >/dev/null 2>&1; do
        _dz_name="$(uci -q get "firewall.@zone[$_dz_i].name" || true)"
        _dz_nets="$(uci -q get "firewall.@zone[$_dz_i].network" || true)"
        for _dz_n in $_dz_nets; do
            _dz_ip="$(uci -q get "network.${_dz_n}.ipaddr" 2>/dev/null || true)"
            case "$_dz_ip" in
                10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                    echo "$_dz_name"; return 0 ;;
            esac
        done
        _dz_i=$((_dz_i + 1))
    done
    echo "lan"
}

# detect_wan_zone — auto-find the FW zone that acts as WAN.
# Heuristic: zone named "wan" → else zone with masq=1 → else "wan".
detect_wan_zone() {
    if zone_exists "wan"; then echo "wan"; return 0; fi
    _dz_i=0
    while uci -q get "firewall.@zone[$_dz_i]" >/dev/null 2>&1; do
        _dz_masq="$(uci -q get "firewall.@zone[$_dz_i].masq" 2>/dev/null || true)"
        if [ "$_dz_masq" = "1" ]; then
            uci -q get "firewall.@zone[$_dz_i].name" || true
            return 0
        fi
        _dz_i=$((_dz_i + 1))
    done
    echo "wan"
}

# _forwarding_dest_for VPN_ZONE PREDICATE — echo the first zone this VPN
# zone forwards into that PREDICATE (called with the candidate) accepts.
_forwarding_dest_for() {
    _fdz_vpn="$1"; _fdz_pred="$2"
    [ -z "$_fdz_vpn" ] && return 1
    _fdz_i=0
    while uci -q get "firewall.@forwarding[$_fdz_i]" >/dev/null 2>&1; do
        _fdz_src="$(uci -q get "firewall.@forwarding[$_fdz_i].src"  2>/dev/null || true)"
        _fdz_dst="$(uci -q get "firewall.@forwarding[$_fdz_i].dest" 2>/dev/null || true)"
        if [ "$_fdz_src" = "$_fdz_vpn" ] && [ -n "$_fdz_dst" ] && "$_fdz_pred" "$_fdz_dst"; then
            printf '%s\n' "$_fdz_dst"
            return 0
        fi
        _fdz_i=$((_fdz_i + 1))
    done
    return 1
}

# _zone_is_wan ZONE — returns 0 if zone looks like a WAN (masq=1 OR name
# contains "wan"). Predicate for _forwarding_dest_for.
_zone_is_wan() {
    _z="$1"
    _zi="$(find_zone_index "$_z" 2>/dev/null)" || return 1
    _m="$(uci -q get "firewall.@zone[$_zi].masq" 2>/dev/null || true)"
    [ "$_m" = "1" ] && return 0
    case "$_z" in *wan*|*Wan*|*WAN*) return 0 ;; esac
    return 1
}

# _zone_is_lan ZONE — returns 0 if zone looks like a LAN (name "lan" or
# network list contains an RFC1918 interface).
_zone_is_lan() {
    _z="$1"
    [ "$_z" = "lan" ] && return 0
    _zi="$(find_zone_index "$_z" 2>/dev/null)" || return 1
    _nets="$(uci -q get "firewall.@zone[$_zi].network" 2>/dev/null || true)"
    for _n in $_nets; do
        _ip="$(uci -q get "network.${_n}.ipaddr" 2>/dev/null || true)"
        case "$_ip" in
            10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        esac
    done
    return 1
}

# iface_lan_zone IFACE — LAN zone this VPN is wired to.
#   1. existing forwarding vpn_zone → <lan-ish zone>  (self-consistent)
#   2. global heuristic (detect_lan_zone)
iface_lan_zone() {
    _vz="$(find_zone_for_interface "$1" 2>/dev/null || true)"
    _r="$(_forwarding_dest_for "$_vz" _zone_is_lan 2>/dev/null || true)"
    [ -n "$_r" ] && { printf '%s' "$_r"; return 0; }
    detect_lan_zone
}

# iface_wan_zone IFACE — WAN zone this VPN is wired to.
# Same precedence as iface_lan_zone so multi-WAN setups (wan, wan6,
# wan_wwan, wan2, …) stay on whatever zone the user actually picked.
iface_wan_zone() {
    _vz="$(find_zone_for_interface "$1" 2>/dev/null || true)"
    _r="$(_forwarding_dest_for "$_vz" _zone_is_wan 2>/dev/null || true)"
    [ -n "$_r" ] && { printf '%s' "$_r"; return 0; }
    detect_wan_zone
}

# detect_lan_netiface — UCI network interface name that carries LAN IPs.
# "lan" if it exists, else the first iface with RFC1918 ipaddr.
detect_lan_netiface() {
    if uci -q get network.lan >/dev/null 2>&1; then echo "lan"; return 0; fi
    for _dn in $(uci -q show network 2>/dev/null \
            | sed -n "s/^network\.\([^.=]*\)=interface$/\1/p"); do
        _dn_ip="$(uci -q get "network.${_dn}.ipaddr" 2>/dev/null || true)"
        case "$_dn_ip" in
            10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                echo "$_dn"; return 0 ;;
        esac
    done
    echo "lan"
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

# port_allowed_in_zone PORT ZONE [PROTO] — 0 if there is a firewall.@rule
# accepting PORT/PROTO into the zone (i.e. exposed to it). PROTO defaults to
# "udp". Matches single values, space-separated lists, and ranges "N-M".
port_allowed_in_zone() {
    _pz_port="$1"; _pz_zone="$2"; _pz_proto="${3:-udp}"
    [ -z "$_pz_port" ] || [ -z "$_pz_zone" ] && return 1
    _pz_i=0
    while uci -q get "firewall.@rule[$_pz_i]" >/dev/null 2>&1; do
        _pz_src="$(uci -q get "firewall.@rule[$_pz_i].src" 2>/dev/null || true)"
        _pz_tgt="$(uci -q get "firewall.@rule[$_pz_i].target" 2>/dev/null || true)"
        _pz_proto_rule="$(uci -q get "firewall.@rule[$_pz_i].proto" 2>/dev/null || true)"
        _pz_dport="$(uci -q get "firewall.@rule[$_pz_i].dest_port" 2>/dev/null || true)"
        _pz_enabled="$(uci -q get "firewall.@rule[$_pz_i].enabled" 2>/dev/null || true)"
        _pz_i=$((_pz_i + 1))
        [ "$_pz_src" = "$_pz_zone" ] || continue
        [ "$_pz_tgt" = "ACCEPT" ] || continue
        [ "${_pz_enabled:-1}" = "0" ] && continue
        case "$_pz_proto_rule" in
            ''|any|"$_pz_proto"|*"$_pz_proto"*) ;;
            *) continue ;;
        esac
        # dest_port: "51820", "51820 51830", or "51820-51830"
        case " $_pz_dport " in
            *" $_pz_port "*) return 0 ;;
        esac
        case "$_pz_dport" in
            *-*)
                _pz_lo="${_pz_dport%-*}"
                _pz_hi="${_pz_dport#*-}"
                case "$_pz_lo$_pz_hi" in *[!0-9]*) continue ;; esac
                [ "$_pz_port" -ge "$_pz_lo" ] 2>/dev/null \
                    && [ "$_pz_port" -le "$_pz_hi" ] 2>/dev/null \
                    && return 0
                ;;
        esac
    done
    return 1
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

find_free_subnet() {
    # Try 10.x.0.1/24 where x = 10,20,30..250, then 10.x.y.1/24
    for _x in 10 20 30 40 50 60 70 80 90 100 110 120 130 140 150 160 170 180 190 200 210 220 230 240 250; do
        _candidate="10.${_x}.0.1/24"
        _cand_subnet="$(network_base_from_cidr "$_candidate")"
        _cand_ip="${_candidate%/*}"
        _conflict=""
        _all_ifs="$(uci show network 2>/dev/null \
            | sed -n "s/^network\.\([^.]*\)\.addresses=.*/\1/p" \
            | sort -u)"
        for _eif in $_all_ifs; do
            for _ev in $(iface_get "$_eif" addresses); do
                case "$_ev" in */*) ;; *) continue ;; esac
                _esubnet="$(network_base_from_cidr "$_ev")"
                if [ "$_esubnet" = "$_cand_subnet" ] || cidr_contains_ip "$_ev" "$_cand_ip"; then
                    _conflict=1; break 2
                fi
            done
        done
        # Also check against LAN subnet
        _lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
        _lan_mask="$(uci -q get network.lan.netmask 2>/dev/null || true)"
        if [ -n "$_lan_ip" ] && [ -n "$_lan_mask" ]; then
            _lbits=0; OLDIFS="$IFS"; IFS='.'
            for _oct in $_lan_mask; do
                case "$_oct" in
                    255) _lbits=$((_lbits+8)) ;; 254) _lbits=$((_lbits+7)) ;;
                    252) _lbits=$((_lbits+6)) ;; 248) _lbits=$((_lbits+5)) ;;
                    240) _lbits=$((_lbits+4)) ;; 224) _lbits=$((_lbits+3)) ;;
                    192) _lbits=$((_lbits+2)) ;; 128) _lbits=$((_lbits+1)) ;;
                esac
            done; IFS="$OLDIFS"
            _lan_cidr_chk="${_lan_ip}/${_lbits}"
            _lan_base="$(network_base_from_cidr "$_lan_cidr_chk")"
            [ "$_lan_base" = "$_cand_subnet" ] && _conflict=1
        fi
        [ -z "$_conflict" ] && { printf '%s\n' "$_candidate"; return 0; }
    done
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

# ─── AWG obfuscation parameter generation ────────────────────────────

# awg_rand_u32 — print a random unsigned 32-bit integer
awg_rand_u32() {
    if [ -r /dev/urandom ]; then
        _v="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')"
        if [ -n "$_v" ]; then
            printf '%s' "$_v"
            return
        fi
    fi
    awk 'BEGIN { srand(); printf "%u", int(rand() * 4294967295) }'
}

# awg_rand_range MIN MAX — random int in [MIN, MAX] inclusive
awg_rand_range() {
    _min="$1"; _max="$2"
    _span=$((_max - _min + 1))
    if [ -r /dev/urandom ]; then
        _v="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')"
        [ -n "$_v" ] && { echo $((_min + _v % _span)); return; }
    fi
    awk -v mn="$_min" -v sp="$_span" 'BEGIN { srand(); printf "%d", mn + int(rand() * sp) }'
}

# generate_awg_obfuscation — emit 12 newline-separated values (AWG 2.0):
#   Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1
# Per AmneziaWG recommendations: Jc 4-8, Jmin 40-80, Jmax 900-1200,
# S1/S2/S3/S4 in 15-100 with S1+56 != S2 handshake-overlap avoidance;
# H1-H4 distinct u32 avoiding reserved WG values {1,2,3,4,5}.
# I1 left "0" — this is a tagged-junk string (AWG 2.0); default keeps
# backward compatibility with older AmneziaWG kernel modules.
generate_awg_obfuscation() {
    # Ranges per docs.amnezia.org/documentation/amnezia-wg.
    # Jmin/Jmax: 64-1024 bytes; S1/S2/S3: 0-64; S4: 0-32; Jc: 0-10.
    _Jc="$(awg_rand_range 4 10)"
    _Jmin="$(awg_rand_range 64 128)"
    _Jmax="$(awg_rand_range 256 1024)"
    _S1="$(awg_rand_range 15 64)"
    _S2="$(awg_rand_range 15 64)"
    # S2 must not equal S1+56 (WireGuard init message size) — causes collision.
    while [ $((_S1 + 56)) -eq "$_S2" ]; do
        _S2="$(awg_rand_range 15 64)"
    done
    _S3="$(awg_rand_range 15 64)"
    _S4="$(awg_rand_range 8 32)"

    _reserved="1 2 3 4 5"
    _picked=""
    _i=0
    while [ "$_i" -lt 4 ]; do
        _h="$(awg_rand_u32)"
        [ "$_h" -eq 0 ] 2>/dev/null && continue
        _collide=0
        for _r in $_reserved $_picked; do
            [ "$_h" = "$_r" ] && { _collide=1; break; }
        done
        [ "$_collide" -eq 1 ] && continue
        _picked="$_picked $_h"
        _i=$((_i + 1))
    done

    # shellcheck disable=SC2086
    set -- $_picked
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$_Jc" "$_Jmin" "$_Jmax" "$_S1" "$_S2" "$_S3" "$_S4" \
        "$1" "$2" "$3" "$4" "0"
}

# awg_iface_get_param IFACE KEY — read UCI `network.IFACE.awg_KEY`,
# fallback to runtime `awg show` value keyed by the same short name.
awg_iface_get_param() {
    _if="$1"; _key="$2"
    _v="$(uci -q get "network.${_if}.awg_${_key}" 2>/dev/null || true)"
    if [ -n "$_v" ]; then
        printf '%s' "$_v"
        return 0
    fi
    awg_iface_show_val "$_if" "$_key"
}

# render_awg_obfuscation_block IFACE — print AWG [Interface]-section lines
# (Jc/Jmin/Jmax/S1/S2/H1-H4/I1) so AmneziaWG-aware clients parse them.
# Emits nothing if the interface has no obfuscation configured.
render_awg_obfuscation_block() {
    _if="$1"
    _jc="$(iface_get "$_if" awg_jc)"
    [ -z "$_jc" ] && return 0
    _jmin="$(iface_get "$_if" awg_jmin)"
    _jmax="$(iface_get "$_if" awg_jmax)"
    _s1="$(iface_get "$_if" awg_s1)"
    _s2="$(iface_get "$_if" awg_s2)"
    _s3="$(iface_get "$_if" awg_s3)"
    _s4="$(iface_get "$_if" awg_s4)"
    _h1="$(awg_iface_get_param "$_if" h1)"
    _h2="$(awg_iface_get_param "$_if" h2)"
    _h3="$(awg_iface_get_param "$_if" h3)"
    _h4="$(awg_iface_get_param "$_if" h4)"
    _i1="$(awg_iface_get_param "$_if" i1)"
    _i2="$(iface_get "$_if" awg_i2)"
    _i3="$(iface_get "$_if" awg_i3)"
    _i4="$(iface_get "$_if" awg_i4)"
    _i5="$(iface_get "$_if" awg_i5)"
    [ -n "$_jc"   ] && printf 'Jc = %s\n'   "$_jc"
    [ -n "$_jmin" ] && printf 'Jmin = %s\n' "$_jmin"
    [ -n "$_jmax" ] && printf 'Jmax = %s\n' "$_jmax"
    [ -n "$_s1"   ] && printf 'S1 = %s\n'   "$_s1"
    [ -n "$_s2"   ] && printf 'S2 = %s\n'   "$_s2"
    [ -n "$_s3"   ] && printf 'S3 = %s\n'   "$_s3"
    [ -n "$_s4"   ] && printf 'S4 = %s\n'   "$_s4"
    [ -n "$_h1"   ] && printf 'H1 = %s\n'   "$_h1"
    [ -n "$_h2"   ] && printf 'H2 = %s\n'   "$_h2"
    [ -n "$_h3"   ] && printf 'H3 = %s\n'   "$_h3"
    [ -n "$_h4"   ] && printf 'H4 = %s\n'   "$_h4"
    [ -n "$_i1"   ] && printf 'I1 = %s\n'   "$_i1"
    [ -n "$_i2"   ] && printf 'I2 = %s\n'   "$_i2"
    [ -n "$_i3"   ] && printf 'I3 = %s\n'   "$_i3"
    [ -n "$_i4"   ] && printf 'I4 = %s\n'   "$_i4"
    [ -n "$_i5"   ] && printf 'I5 = %s\n'   "$_i5"
    return 0
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
    ensure_disk_space 15360
}

ensure_base_firewall() {
    zone_exists "wan" || die "Firewall zone 'wan' not found"
    zone_exists "lan" || die "Firewall zone 'lan' not found"
}

ensure_wan_masq() {
    # Accept an explicit zone argument (preferred) or fall back to the
    # wizard-level $WAN_ZONE global for legacy callers.
    _wz="${1:-${WAN_ZONE:-wan}}"
    wan_idx="$(find_zone_index "$_wz" || true)"
    [ -n "$wan_idx" ] || die "Firewall zone '$_wz' not found"
    masq="$(uci -q get "firewall.@zone[$wan_idx].masq" || true)"
    if [ "$masq" != "1" ]; then
        warn "Masquerading disabled on '$_wz'. VPN clients may lack internet."
        if confirm "Enable masquerading on '$_wz'?" "y"; then
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
# SB_DNS        — Sing-Box listening on ${CFG_SB_DNS_IP}:53
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
    SB_RUNNING=0; SB_DNS=0; SB_TPROXY=0; SB_CFG_OK=0; SB_ROUTE_OK=0
    PK_INSTALLED=0; PK_ENABLED=0; PK_NFT_ACTIVE=0; PK_DTD=0
    DM_FWD=0; DM_NORESOLV=0; DM_OK=0
    DM_DNSCRYPT=0; DM_STUBBY=0
    PK_LINKED=0; PK_DNS_VIA_ROUTER=0

    # Sing-Box (standalone or via podkop)
    if pgrep -f "sing-box" >/dev/null 2>&1; then SB_RUNNING=1; fi

    if [ "$SB_RUNNING" -eq 1 ]; then
        _dpk_ports="$(netstat -ln 2>/dev/null || true)"
        if echo "$_dpk_ports" | grep -q "${CFG_SB_DNS_IP}:53"; then SB_DNS=1; fi
        if echo "$_dpk_ports" | grep -q "127\.0\.0\.1:1602"; then SB_TPROXY=1; fi
    fi

    # Sing-Box config validation
    if [ -f /etc/sing-box/config.json ] && have_cmd sing-box; then
        if sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 \
           || sing-box -c /etc/sing-box/config.json check >/dev/null 2>&1; then
            SB_CFG_OK=1
        fi
    elif [ "$SB_RUNNING" -eq 1 ]; then
        SB_CFG_OK=1  # running = config was valid at start
    fi

    # Sing-Box / VPN routing table
    if ip route show table vpn 2>/dev/null | grep -q "default dev tun0"; then
        SB_ROUTE_OK=1
    fi

    # dnsmasq configuration (independent of podkop)
    _dpk_cachesize="$(uci -q get "dhcp.@dnsmasq[0].cachesize" 2>/dev/null || true)"
    if [ "$(uci -q get "dhcp.@dnsmasq[0].noresolv" 2>/dev/null || true)" = "1" ]; then DM_NORESOLV=1; fi
    for _dpk_srv in $(uci -q get "dhcp.@dnsmasq[0].server" 2>/dev/null || true); do
        case "$_dpk_srv" in ${CFG_SB_DNS_IP}|${CFG_SB_DNS_IP}\#*) DM_FWD=1 ;; esac
        case "$_dpk_srv" in 127.0.0.53|127.0.0.53\#*) DM_DNSCRYPT=1 ;; esac
        case "$_dpk_srv" in 127.0.0.1\#5453) DM_STUBBY=1 ;; esac
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
        _dpk_dns="$(iface_get "$_dpk_iface" dns)"
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

# resolve_hostname HOSTNAME — echo the first A-record IP for HOSTNAME, or
# empty if input is already an IP / is an IPv6 literal / fails to resolve.
# Tries getent first (NSS path), falls back to nslookup (busybox).
resolve_hostname() {
    _rh_in="$1"
    [ -z "$_rh_in" ] && return 1
    # Skip anything already numeric / IPv6 literal — only hostnames need resolving.
    case "$_rh_in" in
        *:*) return 1 ;;                       # IPv6 literal
        *[!0-9.]*) ;;                          # has non-digit non-dot → hostname
        *) return 1 ;;                         # pure IPv4 literal
    esac
    _rh_ip="$(getent hosts "$_rh_in" 2>/dev/null | awk '{print $1; exit}')"
    [ -z "$_rh_ip" ] && _rh_ip="$(nslookup "$_rh_in" 2>/dev/null \
        | awk '/^Address: /{print $2; exit}')"
    [ -z "$_rh_ip" ] && return 1
    printf '%s\n' "$_rh_ip"
}

# resolve_hostname_via HOSTNAME DNS_SERVER — resolve via a specific server,
# bypassing local split-horizon records. Used to see what external clients
# would get. Empty if it fails.
resolve_hostname_via() {
    _rh_in="$1"; _rh_srv="$2"
    [ -z "$_rh_in" ] || [ -z "$_rh_srv" ] && return 1
    case "$_rh_in" in
        *:*|*[!0-9.]*) ;;
        *) return 1 ;;
    esac
    # nslookup output on BusyBox: the answer's "Address" line comes after
    # the server's own address line. Take the last non-server Address.
    _rh_ip="$(nslookup "$_rh_in" "$_rh_srv" 2>/dev/null \
        | awk -v srv="$_rh_srv" '
            /^Address/ {
                sub(/.*:[[:space:]]*/, "")
                if ($0 != srv && $0 != "") last=$0
            }
            END { if (last) print last }')"
    [ -z "$_rh_ip" ] && return 1
    printf '%s\n' "$_rh_ip"
}

# classify_endpoint_ip IP — echo a short context label for an endpoint IP:
#   "wan"      → matches this router's WAN IP
#   "hairpin"  → matches this router's LAN IP (split-horizon DNS)
#   "private"  → RFC1918 / link-local but NOT this router
#   "external" → public IP, but NOT this router's WAN
#   (empty)    → could not classify
classify_endpoint_ip() {
    _cip="$1"
    [ -z "$_cip" ] && return 1
    # Router's own LAN IP → intentional split-horizon / hairpin DNS setup.
    _lan_ip="$(detect_router_lan_ip 2>/dev/null || true)"
    if [ -n "$_lan_ip" ] && [ "$_cip" = "$_lan_ip" ]; then
        echo "hairpin"; return 0
    fi
    case "$_cip" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|169.254.*|127.*)
            echo "private"; return 0 ;;
    esac
    _wan_ip="$(detect_wan_ip 2>/dev/null || true)"
    if [ -n "$_wan_ip" ] && [ "$_cip" = "$_wan_ip" ]; then
        echo "wan"; return 0
    fi
    echo "external"
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
    have_cmd awg || { echo "0"; return; }
    awg show "$1" dump 2>/dev/null | awk -F'\t' -v now="$(date +%s)" -v th=120 '
        NR>1 && $5 != "0" && (now - $5) <= th { a++ }
        END { print a+0 }'
}

active_peer_names() {
    # Returns comma-separated list of peer descriptions whose handshake is
    # within the last 120s. Pair each dump row with its UCI description.
    _iface="$1"; _pt="amneziawg_${_iface}"
    have_cmd awg || return
    # Collect active public keys from dump, one per line.
    _active_pks="$(awg show "$_iface" dump 2>/dev/null | awk -F'\t' -v now="$(date +%s)" -v th=120 '
        NR>1 && $5 != "0" && (now - $5) <= th { print $1 }')"
    [ -z "$_active_pks" ] && { echo ""; return; }

    _names=""
    _pi=0
    while peer_exists "$_pt" "$_pi"; do
        _pk="$(peer_get "$_pt" "$_pi" public_key)"
        _desc="$(peer_get "$_pt" "$_pi" description)"
        [ -z "$_desc" ] && _desc="peer$((_pi+1))"
        if [ -n "$_pk" ] && printf '%s\n' "$_active_pks" | grep -Fxq -- "$_pk"; then
            _names="${_names:+${_names}, }${_desc}"
        fi
        _pi=$((_pi + 1))
    done
    echo "$_names"
}

# sample_throughput IFACE [INTERVAL_MS] — measure rx/tx bytes delta over the
# interval (default 500ms). Echoes "RX_BPS TX_BPS". Zero if iface has no stats.
sample_throughput() {
    _st_if="$1"; _st_ms="${2:-500}"
    _rx_f="/sys/class/net/${_st_if}/statistics/rx_bytes"
    _tx_f="/sys/class/net/${_st_if}/statistics/tx_bytes"
    [ -r "$_rx_f" ] && [ -r "$_tx_f" ] || { echo "0 0"; return 0; }
    _rx0="$(cat "$_rx_f" 2>/dev/null || echo 0)"
    _tx0="$(cat "$_tx_f" 2>/dev/null || echo 0)"
    # BusyBox 'sleep' accepts only integers; usleep takes microseconds.
    # Trailing `|| true` swallows SIGINT-death in child so `set -e` doesn't fire.
    if [ "$_st_ms" -ge 1000 ]; then
        sleep $((_st_ms / 1000)) 2>/dev/null || true
    elif have_cmd usleep; then
        usleep $(( _st_ms * 1000 )) 2>/dev/null || true
    else
        sleep 1 2>/dev/null || true
    fi
    _rx1="$(cat "$_rx_f" 2>/dev/null || echo 0)"
    _tx1="$(cat "$_tx_f" 2>/dev/null || echo 0)"
    awk -v r0="$_rx0" -v r1="$_rx1" -v t0="$_tx0" -v t1="$_tx1" -v ms="$_st_ms" \
        'BEGIN { s=ms/1000; if (s<=0) s=1; printf "%d %d\n", (r1-r0)/s, (t1-t0)/s }'
    return 0
}

# fmt_rate BPS — bytes/sec → human-readable ("1.23 MB/s", "456 KB/s", "89 B/s").
fmt_rate() {
    awk -v b="${1:-0}" 'BEGIN {
        if      (b >= 1073741824) printf "%.2f GB/s\n", b/1073741824
        else if (b >= 1048576)    printf "%.2f MB/s\n", b/1048576
        else if (b >= 1024)       printf "%.2f KB/s\n", b/1024
        else                      printf "%d B/s\n",    b
    }'
}

# fmt_handshake_age SECONDS — terse duration ("12s", "3m", "1h 20m", "2d 4h").
fmt_handshake_age() {
    _age="${1:-0}"
    [ "$_age" -lt 0 ] && _age=0
    if   [ "$_age" -lt 60 ];    then printf '%ds\n'     "$_age"
    elif [ "$_age" -lt 3600 ];  then printf '%dm\n'     "$((_age/60))"
    elif [ "$_age" -lt 86400 ]; then printf '%dh %dm\n' "$((_age/3600))" "$(((_age%3600)/60))"
    else                             printf '%dd %dh\n' "$((_age/86400))" "$(((_age%86400)/3600))"
    fi
}

# get_peer_handshake IFACE PUBKEY — human-readable age, "never" if no handshake
# yet, "-" if peer not found.
get_peer_handshake() {
    _line="$(awg_dump_peer "$1" "$2")"
    [ -z "$_line" ] && { echo "-"; return; }
    _ts="$(printf '%s\n' "$_line" | awk -F'\t' '{print $5}')"
    if [ -z "$_ts" ] || [ "$_ts" = "0" ]; then echo "never"; return; fi
    fmt_handshake_age "$(( $(date +%s) - _ts ))"
}

get_peer_rx() {
    _line="$(awg_dump_peer "$1" "$2")"
    [ -z "$_line" ] && { echo "0 B"; return; }
    _b="$(printf '%s\n' "$_line" | awk -F'\t' '{print $6}')"
    fmt_bytes "${_b:-0}"
}

get_peer_tx() {
    _line="$(awg_dump_peer "$1" "$2")"
    [ -z "$_line" ] && { echo "0 B"; return; }
    _b="$(printf '%s\n' "$_line" | awk -F'\t' '{print $7}')"
    fmt_bytes "${_b:-0}"
}

# get_peer_endpoint_live IFACE PUBKEY — "host:port", empty if "(none)"/missing.
get_peer_endpoint_live() {
    _line="$(awg_dump_peer "$1" "$2")"
    [ -z "$_line" ] && return
    _ep="$(printf '%s\n' "$_line" | awk -F'\t' '{print $3}')"
    [ -z "$_ep" ] || [ "$_ep" = "(none)" ] && return
    printf '%s\n' "$_ep"
}

# get_peer_keepalive_live IFACE PUBKEY — "every Ns" or empty if off.
get_peer_keepalive_live() {
    _line="$(awg_dump_peer "$1" "$2")"
    [ -z "$_line" ] && return
    _ka="$(printf '%s\n' "$_line" | awk -F'\t' '{print $8}')"
    [ -z "$_ka" ] || [ "$_ka" = "off" ] || [ "$_ka" = "0" ] && return
    printf 'every %ss\n' "$_ka"
}

list_used_hosts() {
    _iface="$1"; _prefix="$2"
    _pt="amneziawg_${_iface}"
    uci -q show network 2>/dev/null \
        | grep "=${_pt}$" \
        | sed "s/^network\.//; s/=${_pt}$//" \
        | while read -r _sec; do
            printf '%s\n' "$(iface_get "$_sec" allowed_ips)"
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

# pick_random_free_ip IFACE PREFIX — random /32 from the 2-254 range, skipping
# used hosts. Falls back to sequential if the pool is ≥90% full (random becomes
# pathological at that density).
pick_random_free_ip() {
    _iface="$1"; _prefix="$2"
    _used="$(list_used_hosts "$_iface" "$_prefix")"
    _used_count="$(printf '%s\n' "$_used" | grep -c '^[0-9]' 2>/dev/null || echo 0)"
    if [ "${_used_count:-0}" -ge 228 ]; then
        pick_free_ip "$_iface" "$_prefix"
        return $?
    fi
    _tries=0
    while [ "$_tries" -lt 200 ]; do
        _r=$(( (RANDOM % 253) + 2 ))
        if ! echo "$_used" | grep -qx "$_r" 2>/dev/null; then
            printf '%s.%s/32\n' "$_prefix" "$_r"
            return 0
        fi
        _tries=$((_tries + 1))
    done
    pick_free_ip "$_iface" "$_prefix"
}

# ip_is_used IFACE PREFIX HOST — 0 if host octet already assigned, 1 otherwise.
ip_is_used() {
    list_used_hosts "$1" "$2" | grep -qx "$3"
}

awg_iface_show_val() {
    # $1 = iface, $2 = key (e.g. "h1", "listening port")
    have_cmd awg || return 0
    awg show "$1" 2>/dev/null \
        | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" \
        | head -n1 || true
}

# ─── Amnezia config output ───────────────────────────────────────────

# ─── Peer config rendering (single source of truth) ──────────────────

# _resolve_endpoint_host IFACE [PT IDX] — resolve the endpoint to put in a
# client .conf. Precedence: per-peer override (if PT/IDX given) → interface
# override → WAN auto-detect → placeholder.
_resolve_endpoint_host() {
    _eh=""
    if [ "$#" -ge 3 ]; then
        _eh="$(uci -q get "network.@$2[$3].endpoint_host" 2>/dev/null || true)"
    fi
    [ -z "$_eh" ] && _eh="$(uci -q get "network.$1.endpoint_host" 2>/dev/null || true)"
    # Legacy safety net: earlier versions allowed users to type "inherit" as
    # the endpoint and saved it verbatim. Treat such values as unset.
    case "$_eh" in inherit|INHERIT|Inherit|none|NONE) _eh="" ;; esac
    [ -z "$_eh" ] && _eh="$(detect_wan_ip 2>/dev/null || true)"
    [ -z "$_eh" ] && _eh="YOUR_SERVER_IP"
    printf '%s' "$_eh"
}

# _base64_1line STRING — emit single-line base64 (with fallback)
_base64_1line() {
    printf '%s' "$1" | base64 -w 0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

# reconstruct_peer_config IFACE PEER_IDX — emit the peer's WireGuard .conf on stdout
reconstruct_peer_config() {
    _iface="$1"; _idx="$2"; _pt="amneziawg_${_iface}"

    _client_priv="$(peer_get "$_pt" "$_idx" "private_key")"
    [ -z "$_client_priv" ] && { echo ""; return 1; }

    _peer_ip="$(peer_get "$_pt" "$_idx" "allowed_ips" "?")"
    _keepalive="$(peer_get "$_pt" "$_idx" "persistent_keepalive" "$CFG_DEFAULT_KEEPALIVE")"
    _psk="$(peer_get "$_pt" "$_idx" "preshared_key")"
    _client_allowed_ips="$(peer_get "$_pt" "$_idx" "client_allowed_ips" "0.0.0.0/0, ::/0")"

    _server_priv="$(iface_get "$_iface" "private_key")"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey 2>/dev/null || true)"

    _port="$(iface_get "$_iface" "listen_port" "$CFG_DEFAULT_PORT")"
    _dns="$(iface_get "$_iface" "dns")"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "$CFG_DEFAULT_DNS")"
    _mtu="$(iface_get "$_iface" "mtu" "$CFG_DEFAULT_MTU")"
    _endpoint_host="$(_resolve_endpoint_host "$_iface" "$_pt" "$_idx")"

    # If a LAN domain is explicitly configured in dnsmasq, append it as a
    # search domain so the client resolves short hostnames (e.g. "router"
    # → "router.${lan_domain}"). Fallback "lan" is not auto-included.
    _dom_explicit="$(uci -q get "dhcp.@dnsmasq[0].domain" 2>/dev/null || true)"
    if [ -n "$_dom_explicit" ]; then
        _dns_line="${_dns}, ${_dom_explicit}"
    else
        _dns_line="$_dns"
    fi

    _out="$(printf "[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = %s\nMTU = %s\n" \
        "$_client_priv" "$_peer_ip" "$_dns_line" "$_mtu")"
    _obf_block="$(render_awg_obfuscation_block "$_iface")"
    [ -n "$_obf_block" ] && _out="$(printf '%s\n%s' "$_out" "$_obf_block")"
    _out="$(printf '%s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s\nEndpoint = %s:%s\nPersistentKeepAlive = %s' \
        "$_out" "$_server_pub" "$_client_allowed_ips" "$_endpoint_host" "$_port" "$_keepalive")"
    [ -n "$_psk" ] && _out="$(printf '%s\nPresharedKey = %s' "$_out" "$_psk")"

    # Validate before emitting — catches corrupted UCI values that would give
    # the client a dead config. On failure, empty output lets callers bail out
    # via their existing `[ -z "$_conf" ]` guards.
    if ! validate_generated_conf "$_out"; then
        return 1
    fi
    printf '%s\n' "$_out"
    return 0
}

# _build_amnezia_json IFACE CLIENT_PRIV CLIENT_V4 CLIENT_V6 SERVER_PUB CONF HOST PORT
# Produce the Amnezia container JSON (input to vpn:// base64). Internal helper.
_build_amnezia_json() {
    _iface="$1" _pr="$2" _v4="$3" _v6="$4" _pp="$5" _conf="$6" _host="$7" _port="$8"

    _h1="$(awg_iface_get_param "$_iface" "h1")"; : "${_h1:=1}"
    _h2="$(awg_iface_get_param "$_iface" "h2")"; : "${_h2:=2}"
    _h3="$(awg_iface_get_param "$_iface" "h3")"; : "${_h3:=3}"
    _h4="$(awg_iface_get_param "$_iface" "h4")"; : "${_h4:=4}"
    _i1="$(awg_iface_get_param "$_iface" "i1")"; : "${_i1:=0}"
    _jc="$(iface_get   "$_iface" "awg_jc"   "120")"
    _jmin="$(iface_get "$_iface" "awg_jmin" "23")"
    _jmax="$(iface_get "$_iface" "awg_jmax" "911")"
    _s1="$(iface_get   "$_iface" "awg_s1"   "0")"
    _s2="$(iface_get   "$_iface" "awg_s2"   "0")"
    _mtu="$(iface_get  "$_iface" "mtu" "$CFG_DEFAULT_MTU")"

    _conf_crlf="$(printf '%s' "$_conf" | sed 's/$/\r/')"
    _aip_json="$(printf '%s' "$_conf" | sed -n 's/^AllowedIPs = //p' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)"

    _inner="$(jq -n \
      --arg pr "$_pr" --arg i1 "$_i1" \
      --arg v4 "$_v4" --arg v6 "${_v6:-}" \
      --arg pp "$_pp" --arg cf "$_conf_crlf" \
      --arg h1 "$_h1" --arg h2 "$_h2" --arg h3 "$_h3" --arg h4 "$_h4" \
      --arg jc "$_jc" --arg jmin "$_jmin" --arg jmax "$_jmax" \
      --arg s1 "$_s1" --arg s2 "$_s2" \
      --arg host "$_host" --arg port "$_port" --arg mtu "$_mtu" \
      --argjson allowed_ips "$_aip_json" \
      '{
          H1: $h1, H2: $h2, H3: $h3, H4: $h4,
          I1: $i1, Jc: $jc, Jmax: $jmax, Jmin: $jmin, S1: $s1, S2: $s2,
          allowed_ips: $allowed_ips,
          client_ip: (if $v6 != "" then ($v4 + ", " + $v6) else $v4 end),
          client_priv_key: $pr, config: $cf,
          hostName: $host, mtu: ($mtu|tonumber), port: ($port|tonumber),
          server_pub_key: $pp
      }'
    )"

    jq -n --arg last "$_inner" --arg name "AWG $_iface" \
          --arg host "$_host" --arg port "$_port" \
      '{
          containers: [{ container: "amnezia-awg", awg: {
              isThirdPartyConfig: true, last_config: $last,
              port: $port, transport_proto: "udp"
          }}],
          defaultContainer: "amnezia-awg", description: $name, hostName: $host
      }'
}

# build_vpn_key IFACE PEER_IDX — emit a vpn:// URL for the peer.
build_vpn_key() {
    _iface="$1"; _idx="$2"; _pt="amneziawg_${_iface}"

    _client_priv="$(peer_get "$_pt" "$_idx" "private_key")"
    _client_v4="$(peer_get "$_pt" "$_idx" "allowed_ips")"

    _server_priv="$(iface_get "$_iface" "private_key")"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey 2>/dev/null || true)"

    _port="$(iface_get "$_iface" "listen_port" "$CFG_DEFAULT_PORT")"
    _host="$(_resolve_endpoint_host "$_iface" "$_pt" "$_idx")"
    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"

    _amnezia_json="$(_build_amnezia_json "$_iface" "$_client_priv" "$_client_v4" "" \
                                         "$_server_pub" "$_conf" "$_host" "$_port")"
    printf 'vpn://%s' "$(_base64_1line "$_amnezia_json")"
}

# emit_peer_config IFACE PEER_IDX [HOST] — print .conf + vpn:// + download + QR.
# HOST is optional override; when omitted, uses the same resolver as build_vpn_key.
emit_peer_config() {
    _iface="$1"; _idx="$2"; _host="${3:-}"
    _pt="amneziawg_${_iface}"

    _conf="$(reconstruct_peer_config "$_iface" "$_idx")"
    [ -z "$_conf" ] && { warn "Failed to read peer private key"; return 1; }

    _client_priv="$(peer_get "$_pt" "$_idx" "private_key")"
    _client_v4="$(peer_get "$_pt" "$_idx" "allowed_ips")"
    _server_priv="$(iface_get "$_iface" "private_key")"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey 2>/dev/null || true)"
    _port="$(iface_get "$_iface" "listen_port" "$CFG_DEFAULT_PORT")"
    [ -z "$_host" ] && _host="$(_resolve_endpoint_host "$_iface" "$_pt" "$_idx")"

    _amnezia_json="$(_build_amnezia_json "$_iface" "$_client_priv" "$_client_v4" "" \
                                         "$_server_pub" "$_conf" "$_host" "$_port")"
    _vpn_key="vpn://$(_base64_1line "$_amnezia_json")"

    echo ""
    echo -e "  ${V}── Peer Config ──${NC}"
    echo ""
    echo -e "${W}${_conf}${NC}"
    echo ""
    echo -e "  ${A}AmneziaVPN key:${NC}"
    echo "$_vpn_key"
    echo ""
    _conf_b64="$(_base64_1line "$_conf")"
    echo -e "  ${A}Download:${NC} https://immalware.vercel.app/download?filename=awg_${_iface}.conf&content=${_conf_b64}"
    echo ""

    if have_cmd qrencode; then
        echo -e "  ${A}QR Code:${NC}"
        qrencode -t ANSIUTF8 "$_conf" 2>/dev/null || true
        echo ""
    fi
    return 0
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
    _fname="$(printf '%s_%s' "${3:-peer}" "$1" | tr 'A-Z ' 'a-z-' | sed 's/[^a-z0-9_-]//g')"
    echo ""
    echo -e "  ${A}Download link:${NC}"
    echo "https://immalware.vercel.app/download?filename=${_fname}.conf&content=${_b64}"
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
    emit_peer_config "$1" "$2" || { PAUSE; return; }
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

    _rp_hr_idx="$(find_hostrecord "$_iface" "$_old_desc" 2>/dev/null)" && {
        _rp_ip="$(uci -q get "dhcp.@hostrecord[$_rp_hr_idx].ip" || true)"
        _rp_fqdn="$(build_peer_fqdn "$_iface" "$_new_name")"
        uci set "dhcp.@hostrecord[$_rp_hr_idx].name=${_rp_fqdn}"
        uci set "dhcp.@hostrecord[$_rp_hr_idx]._liminal_peer=${_new_name}"
        uci commit dhcp
        svc_restart dnsmasq
        echo -e "  ${B}Updated${NC} DNS: ${W}${_rp_fqdn}${NC}"
    }

    echo -e "  ${OK}Renamed:${NC} ${_old_desc} -> ${W}${_new_name}${NC}"
    PAUSE
    PEER_NEW_NAME="$_new_name"
    return 0
}

# _pm_edit_endpoint IFACE PT IDX — per-peer endpoint_host override. Empty
# value clears the override so the peer inherits the interface setting.
_pm_edit_endpoint() {
    _iface="$1"; _pt="$2"; _idx="$3"
    _cur="$(peer_get "$_pt" "$_idx" endpoint_host)"
    _iface_ep="$(iface_get "$_iface" endpoint_host)"
    _wan_ep="$(detect_wan_ip 2>/dev/null || true)"
    section "Edit Endpoint"
    echo -e "  ${A}Current:${NC} ${W}${_cur:-inherit from interface}${NC}"
    if [ -n "$_iface_ep" ]; then
        echo -e "  ${DIM2}Interface endpoint: ${_iface_ep}${NC}"
    elif [ -n "$_wan_ep" ]; then
        echo -e "  ${DIM2}Auto-detected WAN: ${_wan_ep}${NC}"
    fi
    echo ""
    echo -e "  ${DIM2}Override the endpoint this peer's .conf gets. Useful when${NC}"
    echo -e "  ${DIM2}multiple domains/IPs point to the router and you want this${NC}"
    echo -e "  ${DIM2}specific peer to connect via a specific one.${NC}"
    echo -e "  ${DIM2}Leave empty to inherit the interface default.${NC}"
    echo ""
    prompt _new_ep "Endpoint (leave blank to inherit from interface)" "$_cur" || return 0
    sigint_caught && return 0
    # Accept common attempts to clear the override: empty, "clear", "inherit",
    # "none". Stored as empty → _resolve_endpoint_host falls back to the iface.
    case "${_new_ep:-}" in
        ""|clear|CLEAR|inherit|INHERIT|Inherit|none|NONE) _new_ep="" ;;
    esac
    if [ -n "$_new_ep" ]; then
        validate_host_or_ip "$_new_ep" || { PAUSE; return 0; }
    fi
    if [ "$_new_ep" = "$_cur" ]; then
        echo -e "  ${DIM2}No change${NC}"; PAUSE; return 0
    fi
    peer_set "$_pt" "$_idx" endpoint_host "$_new_ep"
    uci commit network
    if [ -n "$_new_ep" ]; then
        echo -e "  ${ICO_OK} ${OK}Endpoint set to ${_new_ep}${NC}"
    else
        echo -e "  ${ICO_OK} ${OK}Endpoint cleared (will inherit)${NC}"
    fi
    echo -e "  ${WARN_C}Re-download client config to apply${NC}"
    PAUSE
    return 0
}

# _pm_rotate_secrets IFACE PT IDX DESC PUBKEY — rotate keypair / PSK / both.
# Live-swaps the peer on the kernel (remove + re-add) and invalidates any
# previously-emitted configs for this peer.
_pm_rotate_secrets() {
    _iface="$1"; _pt="$2"; _idx="$3"; _desc="$4"; _old_pub="$5"
    section "Rotate Secrets"
    echo -e "  ${A}This invalidates the current client .conf/QR/vpn://${NC}"
    echo -e "  ${A}for '${W}${_desc}${A}'. Re-download after rotation.${NC}"
    echo ""
    echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Client keypair${NC}  ${DIM2}(client will need new private key)${NC}"
    echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}PreSharedKey${NC}    ${DIM2}(extra layer, rotated independently)${NC}"
    echo -e "  ${B}3${NC} ${DIM2}›${NC} ${W}Both${NC}             ${DIM2}(full rotation)${NC}"
    echo -e "  ${DIM2}Enter › Cancel${NC}"
    echo ""
    prompt _rs_choice "Select" "" || return 0
    sigint_caught && return 0
    _regen_keys=0; _regen_psk=0
    case "${_rs_choice:-}" in
        1) _regen_keys=1 ;;
        2) _regen_psk=1 ;;
        3) _regen_keys=1; _regen_psk=1 ;;
        *) return 0 ;;
    esac
    confirm "Proceed with rotation?" "n" || { cancelled; PAUSE; return 0; }

    _new_priv=""; _new_pub=""
    if [ "$_regen_keys" -eq 1 ]; then
        _new_priv="$(awg genkey)" || { warn "Key generation failed"; PAUSE; return 0; }
        _new_pub="$(printf '%s' "$_new_priv" | awg pubkey)" || { warn "pubkey derivation failed"; PAUSE; return 0; }
        peer_set "$_pt" "$_idx" private_key "$_new_priv"
        peer_set "$_pt" "$_idx" public_key  "$_new_pub"
    fi
    if [ "$_regen_psk" -eq 1 ]; then
        _new_psk="$(awg genpsk)" || { warn "PSK generation failed"; PAUSE; return 0; }
        peer_set "$_pt" "$_idx" preshared_key "$_new_psk"
    fi
    uci commit network

    # Live swap on kernel. If we changed the pubkey, we must remove the old
    # peer (by old pubkey) and re-add; otherwise just re-add with new PSK.
    _live_ok=0
    _eff_pub="${_new_pub:-$_old_pub}"
    if [ -n "$_old_pub" ]; then
        live_peer_remove "$_iface" "$_old_pub" >/dev/null 2>&1 || true
        live_peer_sync_from_uci "$_iface" "$_pt" "$_idx" && _live_ok=1
    fi
    [ "$_live_ok" -eq 0 ] && restart_iface "$_iface" "Restarting AWG..."

    _msg=""
    [ "$_regen_keys" -eq 1 ] && _msg="keys"
    [ "$_regen_psk"  -eq 1 ] && _msg="${_msg:+$_msg + }PSK"
    echo -e "  ${ICO_OK} ${OK}Rotated ${_msg}${NC}"
    echo -e "  ${WARN_C}Old client config is now invalid — re-download${NC}"
    PAUSE
    PEER_NEW_PUB="${_new_pub:-$_old_pub}"
    return 0
}

_pm_generate_config() {
    _iface="$1"; _idx="$2"; _desc="$3"
    crumb_push "Generate Config"
    while true; do
        clear
        crumb_show
        echo -e "${W}Generate Config${NC}  ${DIM2}·${NC}  ${W}${_desc}${NC}"
        echo ""
        echo -e "${DIM2}──────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}QR Code${NC}"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Download Link${NC}"
        echo -e "  ${B}3${NC} ${DIM2}›${NC} ${W}vpn:// Key${NC}     ${DIM2}(AmneziaVPN)${NC}"
        echo -e "  ${B}4${NC} ${DIM2}›${NC} ${W}Setup Config${NC}   ${DIM2}(plain .conf)${NC}"
        echo -e "  ${B}5${NC} ${DIM2}›${NC} ${W}Show All${NC}       ${DIM2}(QR + link + vpn:// + conf)${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} " && read_choice _gc_choice
        sigint_caught && { crumb_pop; return; }
        case "${_gc_choice:-}" in
            "") crumb_pop; return ;;
            1)  show_peer_qr       "$_iface" "$_idx" ;;
            2)  show_peer_download "$_iface" "$_idx" "$_desc" ;;
            3)  show_peer_vpn_key  "$_iface" "$_idx" ;;
            4)  show_peer_conf     "$_iface" "$_idx" ;;
            5)  show_peer_all      "$_iface" "$_idx" "$_desc" ;;
            *)  warn "Unknown option"; PAUSE ;;
        esac
    done
}

# ─── Peer sub-menu ────────────────────────────────────────────────

do_peer_menu() {
    _iface="$1"; _idx="$2"; _desc="$3"
    _pt="amneziawg_${_iface}"
    crumb_push "$_desc"

    while true; do
        clear
        crumb_show
        _aip="$(peer_get "$_pt" "$_idx" allowed_ips "?")"
        _pub="$(peer_get "$_pt" "$_idx" public_key)"
        _peer_disabled="$(peer_get "$_pt" "$_idx" disabled "0")"
        [ "$_peer_disabled" != "1" ] && _peer_disabled=0
        _shortpub=""
        [ -n "$_pub" ] && _shortpub="$(printf '%s' "$_pub" | cut -c1-10)..."

        _hs=""; _rx=""; _tx=""; _ep=""
        _ka="$(peer_get "$_pt" "$_idx" persistent_keepalive "0")"
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
                _hs_sec="$(awg_peer_handshake_age "$_iface" "$_pub")"
                if [ "${_hs_sec:-9999}" -le "120" ] 2>/dev/null; then
                    _st_ico="${ICO_ON}"; _online="${OK}Online${NC}"
                    _is_online=1
                fi
            fi
        fi

        _hs_disp="${_hs:--}"
        case "$_hs_disp" in
            -|never|"") ;;
            *) _hs_disp="${_hs_disp} ago" ;;
        esac
        _hs_col="$(hs_colored "$_hs_disp" "${_hs_sec}")"

        detect_podkop_state "$_iface"

        _hr_fqdn="$(get_peer_hostrecord_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
        _peer_dns="$(iface_get "$_iface" dns "n/a")"
        _pdns_chain="$(dns_chain_label "$_iface")"
        [ -n "$_pdns_chain" ] && _pdns_chain="  ${_pdns_chain}"
        # Match interface box: append LAN domain as search suffix so what
        # the user sees here equals what goes into the client's .conf.
        _pdns_search="$(uci -q get "dhcp.@dnsmasq[0].domain" 2>/dev/null || true)"
        if [ -n "$_pdns_search" ] && [ "$_peer_dns" != "n/a" ]; then
            _peer_dns_shown="${_peer_dns}, ${_pdns_search}"
        else
            _peer_dns_shown="$_peer_dns"
        fi

        _peer_psk="$(peer_get "$_pt" "$_idx" preshared_key)"
        _peer_ep_override="$(peer_get "$_pt" "$_idx" endpoint_host)"

        box_buf_reset
        box_buf_line "  ${_st_ico} ${W}${_desc}${NC}  ${_online}"

        # Identity
        box_buf_sep
        box_buf_line "  ${A}Address${NC}      ${W}${_aip}${NC}"
        box_buf_line "  ${A}Public${NC}       ${DIM2}${_shortpub}${NC}"
        if [ -n "$_peer_psk" ]; then
            _shortpsk="$(printf '%s' "$_peer_psk" | cut -c1-10)..."
            box_buf_line "  ${A}PSK${NC}          ${DIM2}${_shortpsk}${NC}"
        else
            box_buf_line "  ${A}PSK${NC}          ${DIM2}—${NC}"
        fi
        if [ -n "$_hr_fqdn" ]; then
            box_buf_line "  ${A}Hostname${NC}     ${W}${_hr_fqdn}${NC}"
        else
            box_buf_line "  ${A}Hostname${NC}     ${DIM2}none${NC}"
        fi

        # Connection — only when enabled
        if [ "$_peer_disabled" -eq 0 ]; then
            box_buf_sep
            box_buf_line "  ${A}Handshake${NC}    ${_hs_col}"
            if [ "$_is_online" -eq 1 ] && [ -n "$_ep" ]; then
                box_buf_line "  ${A}Endpoint${NC}     ${W}${_ep}${NC}"
            fi
            if [ -n "$_peer_ep_override" ]; then
                box_buf_line "  ${A}Configured${NC}   ${W}${_peer_ep_override}${NC}  ${DIM2}(override)${NC}"
            fi
            _rx_show="${_rx:-0 B}"
            _tx_show="${_tx:-0 B}"
            box_buf_line "  ${A}Traffic${NC}      ${DIM2}↓${NC} ${W}${_rx_show}${NC}  ${DIM2}↑${NC} ${W}${_tx_show}${NC}"
        fi

        # Client Config — inherited from the interface
        box_buf_sep
        box_buf_line "  ${A}DNS${NC}          ${W}${_peer_dns_shown}${NC}${_pdns_chain}"
        if [ -n "$_ka" ] && [ "$_ka" != "0" ]; then
            box_buf_line "  ${A}Keepalive${NC}    ${DIM2}every ${_ka}s${NC}"
        else
            box_buf_line "  ${A}Keepalive${NC}    ${DIM2}off${NC}"
        fi
        box_buf_flush 44

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
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: Sing-Box not listening on ${CFG_SB_DNS_IP}:53${NC}"
                    _dns_warns=1
                elif [ "${DM_FWD:-0}" -eq 0 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: dnsmasq missing server ${CFG_SB_DNS_IP}${NC}"
                    _dns_warns=1
                elif [ "${PK_DNS_VIA_ROUTER:-0}" -eq 1 ]; then
                    echo -e "  ${ICO_OK} ${DIM2}${_sb_label}: peer → dnsmasq → Sing-Box (hostrecords OK)${NC}"
                fi
                if [ "${DM_NORESOLV:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 0 ]; then
                    echo -e "  ${ICO_WARN} ${WARN_C}${_sb_label}: noresolv=1 but no server ${CFG_SB_DNS_IP}${NC}"
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

        # Column-aligned Settings — same technique as the peer list uses
        # (ANSI cursor positioning). Value column starts at ~24.
        _SV="\\033[26G"

        _cur_caip="$(peer_get "$_pt" "$_idx" client_allowed_ips "0.0.0.0/0, ::/0")"
        _hr_disp="${_hr_fqdn:-none}"
        _cur_pep="$(peer_get "$_pt" "$_idx" endpoint_host)"
        _pep_label="${_cur_pep:-inherit}"

        echo -e "  ${DIM2}Routing${NC}"
        echo -e "  ${B}a${NC} ${DIM2}›${NC} ${W}AllowedIPs${NC}${_SV}${DIM2}${_cur_caip}${NC}"
        echo -e "  ${B}k${NC} ${DIM2}›${NC} ${W}Keepalive${NC}${_SV}${DIM2}${_ka}s${NC}"
        echo -e "  ${B}e${NC} ${DIM2}›${NC} ${W}Endpoint${NC}${_SV}${DIM2}${_pep_label}${NC}"
        echo ""
        echo -e "  ${DIM2}DNS${NC}"
        echo -e "  ${B}h${NC} ${DIM2}›${NC} ${W}Hostname${NC}${_SV}${DIM2}${_hr_disp}${NC}"
        echo -e "  ${B}g${NC} ${DIM2}›${NC} ${W}Test DNS & Network${NC}"
        echo ""
        echo -e "  ${DIM2}Actions${NC}"
        echo -e "  ${B}c${NC} ${DIM2}›${NC} ${W}Generate Config${NC}"
        echo -e "  ${B}6${NC} ${DIM2}›${NC} ${W}Rename${NC} Peer"
        echo -e "  ${B}7${NC} ${DIM2}›${NC} ${WARN_C}Rotate${NC} Secrets"
        echo -e "  ${B}8${NC} ${DIM2}›${NC} ${_peer_toggle}"
        echo -e "  ${B}9${NC} ${DIM2}›${NC} ${ERR}Delete${NC} Peer"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice _peer_choice
        sigint_caught && { crumb_pop; return; }

        case "${_peer_choice:-}" in
            c|C) _pm_generate_config "$_iface" "$_idx" "$_desc" ;;
            e|E) _pm_edit_endpoint      "$_iface" "$_pt" "$_idx" ;;
            6)  PEER_NEW_NAME=""
                if do_rename_peer "$_iface" "$_idx" "$_desc"; then
                    _desc="$PEER_NEW_NAME"
                    crumb_pop; crumb_push "$_desc"
                fi ;;
            7)  PEER_NEW_PUB=""
                _pm_rotate_secrets "$_iface" "$_pt" "$_idx" "$_desc" "$_pub"
                [ -n "$PEER_NEW_PUB" ] && _pub="$PEER_NEW_PUB" ;;
            8)  if [ "$_peer_disabled" -eq 1 ]; then
                    uci delete "network.@${_pt}[$_idx].disabled" 2>/dev/null || true
                    uci commit network
                    live_peer_sync_from_uci "$_iface" "$_pt" "$_idx" \
                        || restart_iface "$_iface" "Enabling peer..."
                    echo -e "  ${ICO_OK} ${OK}Peer '${_desc}' enabled${NC}"
                else
                    uci set "network.@${_pt}[$_idx].disabled=1"
                    uci commit network
                    [ -n "$_pub" ] && live_peer_remove "$_iface" "$_pub" \
                        || restart_iface "$_iface" "Disabling peer..."
                    echo -e "  ${ICO_OK} ${OK}Peer '${_desc}' disabled${NC}"
                fi
                PAUSE ;;
            9)  confirm "Delete peer '${_desc}'?" "n" || continue
                sigint_caught && continue
                remove_peer_hostrecord "$_iface" "$_desc"
                uci delete "network.@${_pt}[$_idx]"
                uci commit network
                # Live-remove from kernel so active tunnels stay up
                # (avoids ifdown/ifup which would drop this very SSH session).
                if [ -n "$_pub" ]; then
                    live_peer_remove "$_iface" "$_pub" \
                        || restart_iface "$_iface" "Restarting AWG..."
                fi
                echo -e "  ${ICO_OK} ${OK}Peer '${_desc}' deleted${NC}"
                PAUSE
                crumb_pop; return ;;
            a) # Edit AllowedIPs
                section "Edit AllowedIPs"
                _cur_caip="$(peer_get "$_pt" "$_idx" client_allowed_ips "0.0.0.0/0, ::/0")"
                echo -e "  ${A}Current:${NC} ${W}${_cur_caip}${NC}"
                echo ""
                echo -e "  ${DIM2}Presets:${NC}"
                echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Full tunnel${NC}   ${DIM2}0.0.0.0/0, ::/0${NC}"
                echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Custom${NC}       ${DIM2}enter manually${NC}"
                echo -e "  ${DIM2}Enter › Cancel${NC}"
                echo ""
                prompt _aip_choice "Select" "" || continue
                sigint_caught && continue
                [ -z "$_aip_choice" ] && { cancelled; PAUSE; continue; }
                case "$_aip_choice" in
                    1) _new_caip="0.0.0.0/0, ::/0" ;;
                    2) prompt _new_caip "AllowedIPs" "$_cur_caip" || continue
                       sigint_caught && continue
                       [ -z "$_new_caip" ] && { cancelled; PAUSE; continue; }
                       validate_allowed_ips "$_new_caip" || { PAUSE; continue; }
                       ;;
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
                section "Manage Hostname"
                _cur_hr="$(get_peer_hostrecord_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
                _peer_ip_bare="${_aip%%/*}"
                if [ -n "$_cur_hr" ]; then
                    echo -e "  ${A}Current:${NC} ${W}${_cur_hr}${NC} → ${W}${_peer_ip_bare}${NC}"
                    echo ""
                    echo -e "    ${B}1${NC} ${DIM2}›${NC} ${W}Change${NC} hostname"
                    echo -e "    ${B}2${NC} ${DIM2}›${NC} ${ERR}Remove${NC} hostname"
                    echo -e "    ${DIM2}Enter › Cancel${NC}"
                    echo ""
                    echo -ne "  ${A}>${NC} "; read -r _h_choice || true
                    sigint_caught && continue
                    case "${_h_choice:-}" in
                        1)  _h_lan_domain="$(get_lan_domain)"
                            _h_domain="$(sanitize_hostname "$_iface").${_h_lan_domain}"
                            _h_auto="$(build_peer_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
                            _h_short="$(sanitize_hostname "$_desc").${_h_lan_domain}"
                            echo ""
                            echo -e "    ${B}1${NC} ${DIM2}›${NC} ${W}${_h_auto}${NC}"
                            echo -e "    ${B}2${NC} ${DIM2}›${NC} ${W}${_h_short}${NC}  ${DIM2}(short, no iface suffix)${NC}"
                            echo -e "    ${B}3${NC} ${DIM2}›${NC} ${W}Custom${NC}"
                            echo -e "    ${DIM2}Enter › Cancel${NC}"
                            echo ""
                            echo -ne "  ${A}>${NC} "; read -r _h_sub || true
                            sigint_caught && continue
                            _h_fqdn=""
                            case "${_h_sub:-}" in
                                1) _h_fqdn="$_h_auto"  ;;
                                2) _h_fqdn="$_h_short" ;;
                                3)  prompt_custom_hostname "$_h_domain" "$_h_lan_domain" \
                                        && _h_fqdn="$CUSTOM_HOSTNAME_RESULT" \
                                        || _h_fqdn="" ;;
                                *)  _h_fqdn="" ;;
                            esac
                            if [ -n "$_h_fqdn" ]; then
                                if [ "$_h_fqdn" = "$_cur_hr" ]; then
                                    echo -e "  ${DIM2}No change${NC}"
                                elif hostrecord_fqdn_exists "$_h_fqdn"; then
                                    warn "Hostname '${_h_fqdn}' already exists"
                                else
                                    _h_idx="$(find_hostrecord "$_iface" "$_desc")"
                                    uci set "dhcp.@hostrecord[$_h_idx].name=${_h_fqdn}"
                                    uci commit dhcp
                                    svc_restart dnsmasq
                                    echo -e "  ${ICO_OK} ${OK}Hostname changed:${NC} ${_h_fqdn}"
                                fi
                            fi ;;
                        2)  remove_peer_hostrecord "$_iface" "$_desc" ;;
                        *)  continue ;;
                    esac
                else
                    echo -e "  ${A}No DNS record for this peer${NC}"
                    echo ""
                    _h_auto="$(build_peer_fqdn "$_iface" "$_desc" 2>/dev/null || true)"
                    _h_lan_domain="$(get_lan_domain)"
                    _h_domain="$(sanitize_hostname "$_iface").$_h_lan_domain"
                    _h_short="$(sanitize_hostname "$_desc").$_h_lan_domain"
                    echo -e "    ${B}1${NC} ${DIM2}›${NC} ${W}${_h_auto}${NC}"
                    echo -e "    ${B}2${NC} ${DIM2}›${NC} ${W}${_h_short}${NC}  ${DIM2}(short, no iface suffix)${NC}"
                    echo -e "    ${B}3${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(enter hostname.${_h_domain})${NC}"
                    echo -e "    ${DIM2}Enter › Skip${NC}"
                    echo ""
                    echo -ne "  ${A}>${NC} "; read -r _h_choice || true
                    sigint_caught && { PAUSE; continue; }
                    _h_fqdn=""
                    case "${_h_choice:-}" in
                        1)  _h_fqdn="$_h_auto" ;;
                        2)  _h_fqdn="$_h_short" ;;
                        3)  while true; do
                                prompt_custom_hostname "$_h_domain" "$_h_lan_domain" || { _h_fqdn=""; break; }
                                _h_fqdn="$CUSTOM_HOSTNAME_RESULT"
                                [ -z "$_h_fqdn" ] && break
                                if hostrecord_fqdn_exists "$_h_fqdn"; then
                                    warn "Hostname '${_h_fqdn}' already exists"
                                    _h_fqdn=""
                                    continue
                                fi
                                break
                            done ;;
                        *)  continue ;;
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
                section "Edit Keepalive"
                _cur_ka="$(peer_get "$_pt" "$_idx" persistent_keepalive "$CFG_DEFAULT_KEEPALIVE")"
                echo -e "  ${A}Current:${NC} ${W}${_cur_ka}s${NC}"
                echo -e "  ${DIM2}0 = off, 25 = recommended for NAT${NC}"
                prompt _new_ka "Keepalive" "$_cur_ka" || continue
                sigint_caught && continue
                case "$_new_ka" in *[!0-9]*) warn "Must be numeric"; PAUSE; continue ;; esac
                if [ "$_new_ka" != "$_cur_ka" ]; then
                    confirm "Change keepalive ${_cur_ka}s → ${_new_ka}s?" "y" || continue
                    uci set "network.@${_pt}[$_idx].persistent_keepalive=$_new_ka"
                    uci commit network
                    [ -n "$_pub" ] && live_peer_set_keepalive "$_iface" "$_pub" "$_new_ka" \
                        || restart_iface "$_iface"
                    echo -e "  ${ICO_OK} ${OK}Keepalive updated to ${_new_ka}s${NC}"
                    echo -e "  ${WARN_C}Re-download client config to apply${NC}"
                else
                    echo -e "  ${DIM2}No change${NC}"
                fi
                PAUSE ;;

            g|G) # Test DNS & Network Diagnostics
                do_dns_network_test "$_iface" "${_aip%%/*}" "$_hr_fqdn" "$_is_online"
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
    while peer_exists "$_pt" "$_pi"; do
        _found=1; _n=$((_pi + 1))
        _desc="$(peer_get "$_pt" "$_pi" description "(unnamed)")"
        _aip="$(peer_get "$_pt" "$_pi" allowed_ips "?")"
        _pub="$(peer_get "$_pt" "$_pi" public_key)"

        _pdis="$(peer_get "$_pt" "$_pi" disabled "0")"
        if [ "$_pdis" = "1" ]; then
            echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${ICO_DIS} ${DIM2}${_desc}${NC}  ${DIM2}${_aip}${NC}"
        else
            _hs="$(get_peer_handshake "$_iface" "$_pub")"
            _hs_sec=9999
            if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                _hs_sec="$(awg_peer_handshake_age "$_iface" "$_pub")"
                if [ "${_hs_sec:-9999}" -le "120" ] 2>/dev/null; then
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
    _sel_desc="$(peer_get "$_pt" "$_sel_idx" description)"
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

    # ── Peer ─────────────────────────────────────────────────────────
    section "Peer"

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

    _addr="$(iface_get "$_iface" addresses)"
    [ -z "$_addr" ] && { die "Cannot read interface address for $_iface"; }
    _prefix="$(get_ip_prefix "$_addr")"
    _iface_subnet="$(network_base_from_cidr "$_addr")"

    echo ""
    echo -e "  ${A}IP assignment:${NC}"
    echo ""
    echo -e "    ${B}1${NC} ${DIM2}›${NC} ${W}First available${NC}  ${DIM2}(lowest free in ${_prefix}.2-254)${NC}"
    echo -e "    ${B}2${NC} ${DIM2}›${NC} ${W}Random${NC}           ${DIM2}(random free host)${NC}"
    echo -e "    ${B}3${NC} ${DIM2}›${NC} ${W}Custom${NC}           ${DIM2}(enter manually)${NC}"
    echo ""
    _peer_ip=""
    while [ -z "$_peer_ip" ]; do
        prompt _ip_mode "Select" "1" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        case "${_ip_mode:-1}" in
            1) _peer_ip="$(pick_free_ip        "$_iface" "$_prefix")" ;;
            2) _peer_ip="$(pick_random_free_ip "$_iface" "$_prefix")" ;;
            3)
                while true; do
                    prompt _ip_in "Host octet or full IP" "" || break
                    is_cancelled && break
                    [ -z "$_ip_in" ] && break
                    case "$_ip_in" in
                        *.*.*.*) _cand="${_ip_in%/*}" ;;
                        *)       _cand="${_prefix}.${_ip_in}" ;;
                    esac
                    if ! cidr_contains_ip "$_iface_subnet" "$_cand"; then
                        warn "IP ${_cand} is outside subnet ${_iface_subnet}"; continue
                    fi
                    _host="${_cand##*.}"
                    if [ "$_host" = "1" ] || [ "$_host" = "0" ] || [ "$_host" = "255" ]; then
                        warn "Reserved host octet (${_host})"; continue
                    fi
                    if ip_is_used "$_iface" "$_prefix" "$_host"; then
                        warn "IP ${_cand} is already assigned"; continue
                    fi
                    _peer_ip="${_cand}/32"
                    break
                done
                ;;
            *) warn "Invalid choice"; continue ;;
        esac
    done

    _peer_ip_bare="${_peer_ip%/*}"
    if ! cidr_contains_ip "$_iface_subnet" "$_peer_ip_bare"; then
        die "Generated peer IP $_peer_ip is outside interface subnet $_iface_subnet"
    fi
    echo -e "  ${ICO_OK} ${OK}IP:${NC} ${W}$_peer_ip${NC} ${DIM2}(subnet: ${_iface_subnet})${NC}"

    # ── Connection ───────────────────────────────────────────────────
    section "Connection"

    _ep_iface="$(iface_get "$_iface" endpoint_host)"
    _ep_wan="$(detect_wan_ip || true)"

    echo -e "  ${A}Endpoint for client config:${NC}"
    echo ""
    _ep_n=0
    _ep_list=""
    if [ -n "$_ep_iface" ]; then
        _ep_n=$((_ep_n + 1))
        echo -e "    ${B}${_ep_n}${NC} ${DIM2}›${NC} ${W}Interface endpoint${NC}  ${DIM2}${_ep_iface}${NC}"
        _ep_list="${_ep_list} ${_ep_iface}"
    fi
    if [ -n "$_ep_wan" ]; then
        _ep_n=$((_ep_n + 1))
        _ep_same=""
        if [ "$_ep_wan" = "$_ep_iface" ]; then _ep_same="  ${DIM2}(same)${NC}"; fi
        echo -e "    ${B}${_ep_n}${NC} ${DIM2}›${NC} ${W}WAN IP${NC}  ${DIM2}${_ep_wan}${NC}${_ep_same}"
        _ep_list="${_ep_list} ${_ep_wan}"
    fi
    _ep_n=$((_ep_n + 1))
    echo -e "    ${B}${_ep_n}${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(enter manually)${NC}"
    echo ""
    _ep_max="$_ep_n"

    # _peer_endpoint_override: only non-empty if user picked Custom — that's
    # the one case where we want the choice to persist per-peer (options 1/2
    # are just "inherit from iface" which is the default anyway).
    _peer_endpoint_override=""
    while true; do
        echo -ne "  ${A}>${NC} "; read -r _ep_choice || true
        sigint_caught && return
        is_cancelled && return
        [ -z "$_ep_choice" ] && { _ep_choice=1; }
        case "$_ep_choice" in *[!0-9]*) warn "Invalid selection"; continue ;; esac
        if [ "$_ep_choice" -lt 1 ] 2>/dev/null || [ "$_ep_choice" -gt "$_ep_max" ] 2>/dev/null; then
            warn "Invalid selection"; continue
        fi
        # Custom
        if [ "$_ep_choice" -eq "$_ep_max" ]; then
            prompt _endpoint_host "Endpoint address" "" || return
            sigint_caught && return
            [ -z "$_endpoint_host" ] && { warn "Required field"; continue; }
            _peer_endpoint_override="$_endpoint_host"
            break
        fi
        # Pick from list
        _ep_i=0
        for _ep_val in $_ep_list; do
            _ep_i=$((_ep_i + 1))
            if [ "$_ep_i" = "$_ep_choice" ]; then _endpoint_host="$_ep_val"; fi
        done
        [ -n "$_endpoint_host" ] && break
    done
    echo -e "  ${ICO_OK} ${OK}Endpoint:${NC} ${W}$_endpoint_host${NC}"

    _port="$(iface_get "$_iface" listen_port "$CFG_DEFAULT_PORT")"
    _dns="$(iface_get "$_iface" dns)"
    [ -z "$_dns" ] && _dns="$(detect_router_lan_ip || echo "$CFG_DEFAULT_DNS")"
    _keepalive="$CFG_DEFAULT_KEEPALIVE"
    _mtu="$(iface_get "$_iface" mtu "$CFG_DEFAULT_MTU")"

    echo -e "  ${ICO_OK} ${OK}DNS:${NC} ${W}$_dns${NC}"
    echo -e "  ${ICO_OK} ${OK}MTU:${NC} ${W}$_mtu${NC}"

    # ── Routing ──────────────────────────────────────────────────────
    section "Routing"

    _vpn_zone="$(find_zone_for_interface "$_iface" 2>/dev/null || true)"
    _ap_lan_zone="$(iface_lan_zone "$_iface")"
    _ap_wan_zone="$(iface_wan_zone "$_iface")"
    _has_wan_fwd=0; _has_lan_fwd=0
    if [ -n "$_vpn_zone" ]; then
        forwarding_exists "$_vpn_zone" "$_ap_wan_zone" && _has_wan_fwd=1
        forwarding_exists "$_vpn_zone" "$_ap_lan_zone" && _has_lan_fwd=1
    fi

    # Check the underlying network interface(s) attached to each zone still exist.
    _ap_lan_iface="$(detect_lan_netiface)"
    _lan_proto="$(uci -q get "network.${_ap_lan_iface}.proto" 2>/dev/null || true)"
    # WAN interface name varies (wan / wan6 / wan_wwan) — just check the zone.
    zone_exists "$_ap_wan_zone" || _has_wan_fwd=0
    [ -z "$_lan_proto" ] && _has_lan_fwd=0

    if [ "$_has_wan_fwd" = "0" ] && [ "$_has_lan_fwd" = "0" ]; then
        warn "No LAN or WAN access from this interface"
        warn "Client will only have access to the VPN subnet"
    else
        [ "$_has_wan_fwd" = "0" ] && warn "No WAN access — client will NOT have internet via VPN"
        [ "$_has_lan_fwd" = "0" ] && warn "No LAN access — client will NOT access server LAN via VPN"
    fi

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

    if [ "$_has_wan_fwd" = "1" ]; then
        _client_allowed_ips="0.0.0.0/0, ::/0"
    elif [ "$_has_lan_fwd" = "1" ] && [ -n "$_lan_cidr" ]; then
        _client_allowed_ips="$_lan_cidr"
    else
        _client_allowed_ips="$_peer_ip"
    fi
    echo -e "  ${ICO_OK} ${OK}AllowedIPs:${NC} ${W}$_client_allowed_ips${NC}"

    # ── Security ─────────────────────────────────────────────────────
    section "Security"

    _psk="$(awg genpsk)" || die "PSK generation failed"
    echo -e "  ${ICO_OK} ${OK}PreSharedKey:${NC} generated"

    _client_priv="$(awg genkey)" || die "Key generation failed"
    _client_pub="$(printf '%s' "$_client_priv" | awg pubkey)" \
        || die "Public key derivation failed"

    _server_priv="$(iface_get "$_iface" private_key)"
    [ -z "$_server_priv" ] && die "Missing interface private key"
    _server_pub="$(printf '%s' "$_server_priv" | awg pubkey)"
    echo -e "  ${ICO_OK} ${OK}Keys:${NC} generated"

    # ── Summary ──────────────────────────────────────────────────────
    section "Summary"

    echo -e "  ${A}Name${NC}         ${W}$PEER_NAME${NC}"
    echo -e "  ${A}IP${NC}           ${W}$_peer_ip${NC}"
    echo -e "  ${A}Endpoint${NC}     ${W}${_endpoint_host}:${_port}${NC}"
    echo -e "  ${A}DNS${NC}          ${W}$_dns${NC}"
    echo -e "  ${A}MTU${NC}          ${W}$_mtu${NC}"
    echo -e "  ${A}AllowedIPs${NC}   ${W}$_client_allowed_ips${NC}"
    echo -e "  ${A}PSK${NC}          ${W}yes${NC}"
    if [ -n "$(iface_get "$_iface" awg_jc)" ]; then
        echo -e "  ${A}Obfuscation${NC}  ${OK}enabled${NC} ${DIM2}(inherits from interface)${NC}"
    else
        echo -e "  ${A}Obfuscation${NC}  ${DIM2}plain WireGuard${NC}"
    fi
    echo ""

    confirm "Create peer?" "y" || { cancelled; PAUSE; return 0; }

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
    # Only persist endpoint override if the user explicitly chose Custom;
    # Interface/WAN selections inherit via _resolve_endpoint_host at render.
    [ -n "$_peer_endpoint_override" ] && \
        uci set "network.${_sec}.endpoint_host=$_peer_endpoint_override"

    uci commit network

    echo ""
    echo -e "  ${ICO_OK} ${OK}Peer '${PEER_NAME}' created${NC}"

    # Offer DNS hostrecord BEFORE restart_iface — if the user is SSH'd over
    # this same VPN, the iface restart drops the connection, killing any
    # interactive prompt that follows.
    _hr_auto="$(build_peer_fqdn "$_iface" "$PEER_NAME" 2>/dev/null || true)"
    if [ -n "$_hr_auto" ]; then
        _hr_lan_domain="$(get_lan_domain)"
        _hr_domain="$(sanitize_hostname "$_iface").$_hr_lan_domain"
        _hr_short="$(sanitize_hostname "$PEER_NAME").$_hr_lan_domain"
        section "Local DNS"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}${_hr_auto}${NC}"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}${_hr_short}${NC}  ${DIM2}(short, no iface suffix)${NC}"
        echo -e "  ${B}3${NC} ${DIM2}›${NC} ${W}Custom${NC}  ${DIM2}(enter hostname.${_hr_domain})${NC}"
        echo -e "  ${DIM2}Enter › Skip${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "; read -r _hr_choice || true
        sigint_caught && _hr_choice=""
        case "${_hr_choice:-}" in
            1)  _hr_fqdn="$_hr_auto" ;;
            2)  _hr_fqdn="$_hr_short" ;;
            3)  while true; do
                    prompt_custom_hostname "$_hr_domain" "$_hr_lan_domain" || { _hr_fqdn=""; break; }
                    _hr_fqdn="$CUSTOM_HOSTNAME_RESULT"
                    [ -z "$_hr_fqdn" ] && break
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

    # Apply the peer to the running kernel live — no ifdown/ifup means the VPN
    # session this script is running over stays up. UCI is already committed
    # so netifd will rebuild the same state on next reboot.
    if live_peer_add "$_iface" "$_client_pub" "$_peer_ip" "" "$_psk" "$_keepalive"; then
        echo -e "  ${ICO_OK} ${OK}Peer active${NC}"
    else
        warn "Live peer add failed — restarting interface as fallback"
        restart_iface "$_iface"
    fi
    echo -e "  ${ICO_OK} ${OK}Done${NC}"

    PAUSE

    # Find index of newly created peer for navigation
    _new_idx=0
    while peer_exists "$_pt" "$_new_idx"; do
        _nd="$(peer_get "$_pt" "$_new_idx" description)"
        if [ "$_nd" = "$PEER_NAME" ]; then
            CREATED_PEER_IDX="$_new_idx"
            CREATED_PEER_NAME="$PEER_NAME"
            return 0
        fi
        _new_idx=$((_new_idx + 1))
    done
}

# _apply_obfuscation IFACE — generate random AmneziaWG params and write to UCI.
_apply_obfuscation() {
    _if="$1"
    _obf="$(generate_awg_obfuscation)"
    iface_set "$_if" "awg_jc"   "$(printf '%s\n' "$_obf" | sed -n '1p')"
    iface_set "$_if" "awg_jmin" "$(printf '%s\n' "$_obf" | sed -n '2p')"
    iface_set "$_if" "awg_jmax" "$(printf '%s\n' "$_obf" | sed -n '3p')"
    iface_set "$_if" "awg_s1"   "$(printf '%s\n' "$_obf" | sed -n '4p')"
    iface_set "$_if" "awg_s2"   "$(printf '%s\n' "$_obf" | sed -n '5p')"
    iface_set "$_if" "awg_s3"   "$(printf '%s\n' "$_obf" | sed -n '6p')"
    iface_set "$_if" "awg_s4"   "$(printf '%s\n' "$_obf" | sed -n '7p')"
    iface_set "$_if" "awg_h1"   "$(printf '%s\n' "$_obf" | sed -n '8p')"
    iface_set "$_if" "awg_h2"   "$(printf '%s\n' "$_obf" | sed -n '9p')"
    iface_set "$_if" "awg_h3"   "$(printf '%s\n' "$_obf" | sed -n '10p')"
    iface_set "$_if" "awg_h4"   "$(printf '%s\n' "$_obf" | sed -n '11p')"
    return 0
}

# _remove_obfuscation IFACE — delete all AmneziaWG obfuscation UCI keys.
_remove_obfuscation() {
    for _k in awg_jc awg_jmin awg_jmax awg_s1 awg_s2 awg_s3 awg_s4 \
              awg_h1 awg_h2 awg_h3 awg_h4 \
              awg_i1 awg_i2 awg_i3 awg_i4 awg_i5; do
        uci -q delete "network.$1.$_k" 2>/dev/null || true
    done
    return 0
}

# _show_obfuscation_summary IFACE — print current obf params (expects params set)
_show_obfuscation_summary() {
    _if="$1"
    _s3="$(iface_get "$_if" "awg_s3")"
    _s4="$(iface_get "$_if" "awg_s4")"
    echo -e "  ${A}Jc${NC}   ${W}$(iface_get "$_if" "awg_jc"   "?")${NC}   ${A}Jmin${NC} ${W}$(iface_get "$_if" "awg_jmin" "?")${NC}   ${A}Jmax${NC} ${W}$(iface_get "$_if" "awg_jmax" "?")${NC}"
    echo -e "  ${A}S1${NC}   ${W}$(iface_get "$_if" "awg_s1"   "?")${NC}   ${A}S2${NC}   ${W}$(iface_get "$_if" "awg_s2"   "?")${NC}"
    if [ -n "$_s3" ] || [ -n "$_s4" ]; then
        echo -e "  ${A}S3${NC}   ${W}${_s3:-?}${NC}   ${A}S4${NC}   ${W}${_s4:-?}${NC}  ${DIM2}(AWG 2.0)${NC}"
    fi
    echo -e "  ${A}H1${NC}   ${DIM2}$(iface_get "$_if" "awg_h1" "?")${NC}"
    echo -e "  ${A}H2${NC}   ${DIM2}$(iface_get "$_if" "awg_h2" "?")${NC}"
    echo -e "  ${A}H3${NC}   ${DIM2}$(iface_get "$_if" "awg_h3" "?")${NC}"
    echo -e "  ${A}H4${NC}   ${DIM2}$(iface_get "$_if" "awg_h4" "?")${NC}"
}

# _mi_obfuscation IFACE — Settings → Obfuscation menu branch handler.
_mi_obfuscation() {
    _iface="$1"
    _cur_jc="$(iface_get "$_iface" "awg_jc")"
    section "Obfuscation"
    if [ -n "$_cur_jc" ]; then
        _show_obfuscation_summary "$_iface"
        # Spec compliance check (docs.amnezia.org — Jc 0-10, Jmin/Jmax 64-1024,
        # S1-S3 0-64, S4 0-32, H1-H4 distinct).
        _ob_viol=""
        _ob_add_viol() { _ob_viol="${_ob_viol}${_ob_viol:+, }$1"; }
        _ob_check() {
            _n="$1"; _v="$2"; _lo="$3"; _hi="$4"
            [ -z "$_v" ] && return 0
            case "$_v" in *[!0-9]*) _ob_add_viol "$_n not integer"; return 0 ;; esac
            if [ "$_v" -lt "$_lo" ] 2>/dev/null || [ "$_v" -gt "$_hi" ] 2>/dev/null; then
                _ob_add_viol "$_n=$_v (spec $_lo-$_hi)"
            fi
        }
        _o_jmin="$(iface_get "$_iface" awg_jmin)"
        _o_jmax="$(iface_get "$_iface" awg_jmax)"
        _ob_check Jc   "$_cur_jc" 0 10
        _ob_check Jmin "$_o_jmin" 64 1024
        _ob_check Jmax "$_o_jmax" 64 1024
        if [ -n "$_o_jmin" ] && [ -n "$_o_jmax" ] \
           && [ "$_o_jmin" -gt "$_o_jmax" ] 2>/dev/null; then
            _ob_add_viol "Jmin>Jmax"
        fi
        _ob_check S1 "$(iface_get "$_iface" awg_s1)" 0 64
        _ob_check S2 "$(iface_get "$_iface" awg_s2)" 0 64
        _ob_check S3 "$(iface_get "$_iface" awg_s3)" 0 64
        _ob_check S4 "$(iface_get "$_iface" awg_s4)" 0 32
        _h1v="$(iface_get "$_iface" awg_h1)"
        _h2v="$(iface_get "$_iface" awg_h2)"
        _h3v="$(iface_get "$_iface" awg_h3)"
        _h4v="$(iface_get "$_iface" awg_h4)"
        for _hv in "H1:$_h1v:H2:$_h2v" "H1:$_h1v:H3:$_h3v" "H1:$_h1v:H4:$_h4v" \
                   "H2:$_h2v:H3:$_h3v" "H2:$_h2v:H4:$_h4v" "H3:$_h3v:H4:$_h4v"; do
            _a_n="${_hv%%:*}"; _r1="${_hv#*:}"; _a_v="${_r1%%:*}"
            _r2="${_r1#*:}"; _b_n="${_r2%%:*}"; _b_v="${_r2#*:}"
            { [ -z "$_a_v" ] || [ -z "$_b_v" ]; } && continue
            [ "$_a_v" = "$_b_v" ] && _ob_add_viol "${_a_n}=${_b_n} collide"
        done
        if [ -n "$_ob_viol" ]; then
            echo ""
            echo -e "  ${ICO_WARN} ${WARN_C}Values out of AmneziaWG spec:${NC} ${DIM2}${_ob_viol}${NC}"
            echo -e "  ${DIM2}Clients may still work, but .conf emit will refuse.${NC}"
            echo -e "  ${DIM2}Use 'Regenerate' to replace with spec-compliant values.${NC}"
        fi
        echo ""
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${WARN_C}Regenerate${NC} (rotate all params)"
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Remove${NC} Obfuscation"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "; read -r _obf_choice || true
        sigint_caught && return 0
        case "${_obf_choice:-}" in
            r|R)
                echo ""
                echo -e "  ${WARN_C}ALL existing clients will stop connecting until they${NC}"
                echo -e "  ${WARN_C}re-download their .conf (new Jc/S1/H1... values).${NC}"
                echo ""
                confirm "Regenerate obfuscation params?" "n" || { cancelled; PAUSE; return 0; }
                _apply_obfuscation "$_iface"
                uci commit network
                live_iface_set_obf "$_iface" || restart_iface "$_iface"
                echo -e "  ${ICO_OK} ${OK}Obfuscation rotated${NC}"
                echo -e "  ${WARN_C}Regenerate and redistribute every client .conf.${NC}"
                PAUSE
                ;;
            d|D)
                echo ""
                echo -e "  ${WARN_C}ALL existing clients will stop connecting until they${NC}"
                echo -e "  ${WARN_C}re-download their .conf (plain WireGuard mode).${NC}"
                echo ""
                confirm "Remove obfuscation from interface?" "n" || { cancelled; PAUSE; return 0; }
                _remove_obfuscation "$_iface"
                uci commit network
                live_iface_clear_obf "$_iface" || restart_iface "$_iface"
                echo -e "  ${ICO_OK} ${OK}Obfuscation removed${NC}"
                echo -e "  ${WARN_C}Regenerate and redistribute every client .conf.${NC}"
                PAUSE
                ;;
            *) ;;
        esac
    else
        echo -e "  ${DIM2}Not configured — plain WireGuard on the wire.${NC}"
        echo -e "  ${DIM2}Setup will generate random AmneziaWG params:${NC}"
        echo -e "  ${DIM2}  Jc/Jmin/Jmax, S1/S2, H1-H4 (I1 left default).${NC}"
        echo ""
        echo -e "  ${WARN_C}ALL existing clients will stop connecting until they${NC}"
        echo -e "  ${WARN_C}re-download their .conf with the new AWG params.${NC}"
        echo ""
        confirm "Setup obfuscation now?" "y" || { cancelled; PAUSE; return 0; }
        _apply_obfuscation "$_iface"
        echo ""
        _show_obfuscation_summary "$_iface"
        echo ""
        confirm "Apply?" "y" || { uci revert network 2>/dev/null; cancelled; PAUSE; return 0; }
        uci commit network
        live_iface_set_obf "$_iface" || restart_iface "$_iface"
        echo -e "  ${ICO_OK} ${OK}Obfuscation enabled${NC}"
        echo -e "  ${WARN_C}Regenerate and redistribute every client .conf.${NC}"
        PAUSE
    fi
    return 0
}

# _mi_show_pubkey IFACE — print the interface's derived public key.
_mi_show_pubkey() {
    _iface="$1"
    _srv_priv="$(iface_get "$_iface" private_key)"
    _srv_pub=""
    [ -n "$_srv_priv" ] && have_cmd awg && \
        _srv_pub="$(printf '%s' "$_srv_priv" | awg pubkey 2>/dev/null || true)"
    echo ""
    if [ -n "$_srv_pub" ]; then
        echo -e "  ${A}Public Key:${NC}"
        echo "  $_srv_pub"
    else
        echo -e "  ${DIM2}Could not derive public key${NC}"
    fi
    PAUSE
}

# _mi_monitor_throughput IFACE — live RX/TX rate + peak + average tracking.
# Redraws every second until Ctrl+C. Peaks reset each time the view opens.
_mi_monitor_throughput() {
    _iface="$1"
    if ! interface_device_exists "$_iface"; then
        warn "Interface is down"; PAUSE; return 0
    fi
    _rx_f="/sys/class/net/${_iface}/statistics/rx_bytes"
    _tx_f="/sys/class/net/${_iface}/statistics/tx_bytes"
    if [ ! -r "$_rx_f" ] || [ ! -r "$_tx_f" ]; then
        warn "Cannot read kernel stats for ${_iface}"; PAUSE; return 0
    fi
    # Drop `set -e` for the duration — we want SIGINT-in-sleep to just break
    # out, not unwind the whole script. Restored on exit.
    set +e
    trap '_CANCELLED=1' INT
    _CANCELLED=0
    _peak_rx=0; _peak_tx=0
    _sum_rx=0; _sum_tx=0
    _start_ts="$(date +%s)"
    _rx0="$(cat "$_rx_f" 2>/dev/null || echo 0)"
    _tx0="$(cat "$_tx_f" 2>/dev/null || echo 0)"
    while [ "$_CANCELLED" -eq 0 ]; do
        sleep 1
        [ "$_CANCELLED" -ne 0 ] && break
        _rx1="$(cat "$_rx_f" 2>/dev/null || echo 0)"
        _tx1="$(cat "$_tx_f" 2>/dev/null || echo 0)"
        _rx_bps=$(( _rx1 - _rx0 ))
        _tx_bps=$(( _tx1 - _tx0 ))
        _rx0="$_rx1"; _tx0="$_tx1"
        [ "$_rx_bps" -gt "$_peak_rx" ] && _peak_rx="$_rx_bps"
        [ "$_tx_bps" -gt "$_peak_tx" ] && _peak_tx="$_tx_bps"
        _sum_rx=$(( _sum_rx + _rx_bps ))
        _sum_tx=$(( _sum_tx + _tx_bps ))
        _elapsed=$(( $(date +%s) - _start_ts ))
        [ "$_elapsed" -lt 1 ] && _elapsed=1
        _rx_c="$(fmt_rate "$_rx_bps")"; _tx_c="$(fmt_rate "$_tx_bps")"
        _rx_p="$(fmt_rate "$_peak_rx")"; _tx_p="$(fmt_rate "$_peak_tx")"
        _rx_a="$(fmt_rate $((_sum_rx / _elapsed)))"
        _tx_a="$(fmt_rate $((_sum_tx / _elapsed)))"
        clear
        section "Monitor Throughput — ${_iface}"
        echo -e "  ${DIM2}Live sample every 1s. ${W}Ctrl+C${NC}${DIM2} to exit.${NC}"
        echo ""
        echo -e "  ${A}Since opened${NC}   ${W}${_elapsed}s${NC}"
        echo -e "  ${A}Current${NC}        ${DIM2}↓${NC} ${W}${_rx_c}${NC}   ${DIM2}↑${NC} ${W}${_tx_c}${NC}"
        echo -e "  ${A}Peak${NC}           ${DIM2}↓${NC} ${W}${_rx_p}${NC}   ${DIM2}↑${NC} ${W}${_tx_p}${NC}"
        echo -e "  ${A}Avg${NC}            ${DIM2}↓${NC} ${W}${_rx_a}${NC}   ${DIM2}↑${NC} ${W}${_tx_a}${NC}"
        echo ""
    done
    trap on_error INT
    set -e
    _CANCELLED=0
}

# _mi_show_live_conf IFACE — dump running kernel state via `awg showconf`.
_mi_show_live_conf() {
    _iface="$1"
    echo ""
    echo -e "  ${V}── Live kernel config ──${NC}"
    echo ""
    if ! interface_device_exists "$_iface"; then
        echo -e "  ${DIM2}Interface is down — nothing to show.${NC}"
    else
        _live_conf="$(awg showconf "$_iface" 2>&1)"
        if [ -n "$_live_conf" ]; then
            echo -e "${W}${_live_conf}${NC}"
        else
            echo -e "  ${DIM2}(empty — no peers / kernel state not available)${NC}"
        fi
    fi
    echo ""
    echo -e "  ${DIM2}This is what the kernel sees right now; UCI is what survives reboot.${NC}"
    PAUSE
}

# _mi_toggle_podkop IFACE — link/unlink the interface in podkop sources.
_mi_toggle_podkop() {
    _iface="$1"
    podkop_present || { warn "Podkop is not installed"; PAUSE; return 0; }
    if podkop_has_interface "$_iface" 2>/dev/null; then
        remove_podkop_interface "$_iface"
        svc_restart podkop
        echo -e "  ${ICO_OK} ${OK}Podkop unlinked${NC}"
    else
        add_podkop_interface "$_iface"
        svc_restart podkop
        echo -e "  ${ICO_OK} ${OK}Podkop linked${NC}"
    fi
    podkop_refresh
    PAUSE
    return 0
}

# _mi_toggle_forwarding IFACE ZONE DEST ENABLED — flip forwarding ZONE→DEST.
# When enabling a WAN-like destination, also turns on masquerading there.
_mi_toggle_forwarding() {
    _iface="$1"; _zone="$2"; _dest="$3"; _enabled="$4"
    if [ "$_enabled" -eq 1 ]; then
        _fi=0
        while uci -q get "firewall.@forwarding[$_fi]" >/dev/null 2>&1; do
            _fsrc="$(uci -q get "firewall.@forwarding[$_fi].src"  2>/dev/null || true)"
            _fdst="$(uci -q get "firewall.@forwarding[$_fi].dest" 2>/dev/null || true)"
            _fl="$(uci   -q get "firewall.@forwarding[$_fi]._liminal_iface" 2>/dev/null || true)"
            if [ "$_fl" = "$_iface" ] && [ "$_fsrc" = "$_zone" ] && [ "$_fdst" = "$_dest" ]; then
                uci delete "firewall.@forwarding[$_fi]"
                break
            fi
            _fi=$((_fi + 1))
        done
        uci commit firewall
        svc_restart firewall
        echo -e "  ${ICO_OK} ${OK}Forwarding to '${_dest}' disabled${NC}"
    else
        _fwd_idx="$(fw_new_forwarding)"
        uci set "firewall.@forwarding[$_fwd_idx].src=${_zone}"
        uci set "firewall.@forwarding[$_fwd_idx].dest=${_dest}"
        uci set "firewall.@forwarding[$_fwd_idx]._liminal_iface=${_iface}"
        uci commit firewall
        [ "$_dest" = "$(iface_wan_zone "$_iface")" ] && ensure_wan_masq "$_dest"
        svc_restart firewall
        echo -e "  ${ICO_OK} ${OK}Forwarding to '${_dest}' enabled${NC}"
    fi
    PAUSE
    return 0
}

# _mi_change_port IFACE — Settings → Change Port menu branch.
_mi_change_port() {
    _iface="$1"
    section "Change Port"
    _cur_port="$(iface_get "$_iface" listen_port)"
    echo -e "  ${WARN_C}All existing peer configs will need to be updated${NC}"
    echo -e "  ${WARN_C}with the new port after this change.${NC}"
    echo ""
    prompt _new_port "New port" "$_cur_port" || return 0
    sigint_caught && return 0
    [ "$_new_port" = "$_cur_port" ] && { echo -e "  ${DIM2}No change${NC}"; PAUSE; return 0; }
    validate_port "$_new_port" || { PAUSE; return 0; }
    port_in_use "$_new_port" && { warn "Port $_new_port is already in use"; PAUSE; return 0; }
    confirm "Change port ${_cur_port} → ${_new_port}?" "n" || return 0

    autobackup_enabled && init_backup "Port Change"
    iface_set "$_iface" listen_port "$_new_port"

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
    # Live kernel update (no ifdown) + firewall reload for the rule change.
    live_iface_set_port "$_iface" "$_new_port" || restart_iface "$_iface"
    svc_restart firewall
    echo -e "  ${ICO_OK} ${OK}Port changed to ${_new_port}${NC}"
    echo -e "  ${WARN_C}Update all peer configs with new port${NC}"
    PAUSE
    return 0
}

# _mi_edit_endpoint IFACE — Settings → Endpoint menu branch.
# _mi_edit_fwmark IFACE — Settings → Edit fwmark (policy-based routing mark).
_mi_edit_fwmark() {
    _iface="$1"
    section "Edit fwmark"
    _cur_fwmark="$(iface_get "$_iface" fwmark)"
    echo -e "  ${A}Current:${NC} ${W}${_cur_fwmark:-off}${NC}"
    echo ""
    echo -e "  ${DIM2}Tags outbound packets with a firewall mark for PBR / kill-switch.${NC}"
    echo -e "  ${DIM2}Accepts decimal (123) or hex (0x7b). Empty or 'off' disables.${NC}"
    echo ""
    prompt _new_fwmark "fwmark" "${_cur_fwmark:-off}" || return 0
    sigint_caught && return 0
    # Normalize: "off"/empty means unset
    case "${_new_fwmark:-}" in ""|off|OFF) _new_fwmark="" ;; esac
    if [ "$_new_fwmark" = "$_cur_fwmark" ]; then
        echo -e "  ${DIM2}No change${NC}"
        PAUSE; return 0
    fi
    validate_fwmark "$_new_fwmark" || { PAUSE; return 0; }
    iface_set "$_iface" fwmark "$_new_fwmark"
    uci commit network
    live_iface_set_fwmark "$_iface" "${_new_fwmark:-0}" || restart_iface "$_iface"
    echo -e "  ${ICO_OK} ${OK}fwmark ${_new_fwmark:-off}${NC}"
    PAUSE
    return 0
}

# detect_upstream_mtu [TARGET_IP] — echo the MTU of the route to TARGET_IP
# (default 1.1.1.1). Falls back to 1500 if `ip route get` gives nothing.
detect_upstream_mtu() {
    _target="${1:-1.1.1.1}"
    _mtu="$(ip -o route get "$_target" 2>/dev/null | sed -n 's/.*mtu \([0-9]\+\).*/\1/p' | head -n1)"
    [ -z "$_mtu" ] && _mtu=1500
    echo "$_mtu"
}

# recommend_mtu [TARGET_IP] — upstream_mtu minus 80 (AWG/WG tunnel overhead).
recommend_mtu() {
    _up="$(detect_upstream_mtu "${1:-}")"
    _rec=$((_up - 80))
    [ "$_rec" -lt 576 ] && _rec=1280  # sanity floor
    echo "$_rec"
}

# _mi_edit_tunlink IFACE — Settings → tunlink. Pins tunnel to upstream iface.
_mi_edit_tunlink() {
    _iface="$1"
    section "tunlink"
    _cur="$(iface_get "$_iface" tunlink)"
    echo -e "  ${A}Current:${NC} ${W}${_cur:-auto}${NC}"
    echo ""
    echo -e "  ${DIM2}Binds the tunnel to a specific upstream interface${NC}"
    echo -e "  ${DIM2}(e.g. 'wan' or 'wan6'). Useful for multi-WAN where you${NC}"
    echo -e "  ${DIM2}want the VPN to exit via a specific provider.${NC}"
    echo -e "  ${DIM2}Leave empty to auto-pick via the routing table.${NC}"
    echo ""
    prompt _new_tl "tunlink (empty = auto)" "$_cur" || return 0
    sigint_caught && return 0
    [ "$_new_tl" = "$_cur" ] && { echo -e "  ${DIM2}No change${NC}"; PAUSE; return 0; }
    iface_set "$_iface" tunlink "$_new_tl"
    uci commit network
    echo -e "  ${ICO_OK} ${OK}tunlink set to ${_new_tl:-auto}${NC}"
    echo -e "  ${WARN_C}Run 'Restart Interface' to apply${NC}"
    PAUSE
    return 0
}

# _mi_edit_nohostroute IFACE — toggle nohostroute. On is needed only when
# the endpoint is reached through another tunnel (cascaded VPNs).
_mi_edit_nohostroute() {
    _iface="$1"
    _cur="$(iface_get "$_iface" nohostroute)"
    section "nohostroute"
    case "$_cur" in
        1|on|true) _label="on" ;;
        *)         _label="off" ;;
    esac
    echo -e "  ${A}Current:${NC} ${W}${_label}${NC}"
    echo ""
    echo -e "  ${DIM2}Off (default) — netifd pins a host route to the endpoint IP,${NC}"
    echo -e "  ${DIM2}               preventing a routing loop through the tunnel.${NC}"
    echo -e "  ${DIM2}On            — skip the host route. Required when the endpoint${NC}"
    echo -e "  ${DIM2}               is itself reached via another VPN/tunnel.${NC}"
    echo ""
    if [ "$_label" = "on" ]; then
        confirm "Turn nohostroute OFF (restore default)?" "y" || return 0
        iface_set "$_iface" nohostroute ""
    else
        confirm "Turn nohostroute ON?" "n" || return 0
        iface_set "$_iface" nohostroute "1"
    fi
    uci commit network
    echo -e "  ${ICO_OK} ${OK}nohostroute toggled${NC}"
    echo -e "  ${WARN_C}Run 'Restart Interface' to apply${NC}"
    PAUSE
    return 0
}

# _mi_edit_route_table IFACE — set ip4table for policy-based routing.
_mi_edit_route_table() {
    _iface="$1"
    section "Routing Table"
    _cur="$(iface_get "$_iface" ip4table)"
    echo -e "  ${A}Current ip4table:${NC} ${W}${_cur:-main}${NC}"
    echo ""
    echo -e "  ${DIM2}Installs IPv4 routes into a custom table instead of 'main'.${NC}"
    echo -e "  ${DIM2}Enter a table number (1-252), a name from /etc/iproute2/rt_tables,${NC}"
    echo -e "  ${DIM2}or leave empty / 'main' to reset to default.${NC}"
    echo -e "  ${DIM2}Applied on next ifup — use 'Restart Interface' after.${NC}"
    echo ""
    prompt _new_tab "ip4table" "${_cur:-main}" || return 0
    sigint_caught && return 0
    case "${_new_tab:-}" in ""|main) _new_tab="" ;; esac
    if [ "$_new_tab" = "$_cur" ]; then
        echo -e "  ${DIM2}No change${NC}"; PAUSE; return 0
    fi
    iface_set "$_iface" ip4table "$_new_tab"
    uci commit network
    echo -e "  ${ICO_OK} ${OK}ip4table set to ${_new_tab:-main}${NC}"
    echo -e "  ${WARN_C}Run 'Restart Interface' to apply${NC}"
    PAUSE
    return 0
}

_mi_edit_endpoint() {
    _iface="$1"
    section "Edit Endpoint"
    _cur_ep="$(iface_get "$_iface" endpoint_host)"
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
    prompt _new_ep "Endpoint host (empty = cancel)" "" || return 0
    sigint_caught && return 0
    if [ -z "$_new_ep" ]; then
        if [ -n "$_cur_ep" ]; then
            confirm "Reset to auto-detect?" "n" || return 0
            iface_set "$_iface" endpoint_host ""
            uci commit network
            echo -e "  ${ICO_OK} ${OK}Endpoint reset to auto-detect${NC}"
            echo -e "  ${WARN_C}Re-download client configs to apply${NC}"
        else
            cancelled
        fi
    elif [ "$_new_ep" != "$_cur_ep" ]; then
        validate_host_or_ip "$_new_ep" || { PAUSE; return 0; }
        # Resolve the hostname and classify the resulting IP so the user
        # can verify at a glance that the endpoint points at the right place.
        echo ""
        _new_ep_ip="$(resolve_hostname "$_new_ep" 2>/dev/null || true)"
        if [ -n "$_new_ep_ip" ]; then
            _ep_class="$(classify_endpoint_ip "$_new_ep_ip" 2>/dev/null || echo "")"
            case "$_ep_class" in
                wan)
                    echo -e "  ${ICO_OK} ${OK}Resolves to${NC} ${W}${_new_ep_ip}${NC}  ${DIM2}(matches router WAN)${NC}"
                    ;;
                hairpin)
                    # Router LAN IP → local DNS has a split-horizon record.
                    # Helpful, but external clients see a different answer
                    # — probe 1.1.1.1 for the public view.
                    echo -e "  ${ICO_OK} ${OK}Resolves to${NC} ${W}${_new_ep_ip}${NC}  ${DIM2}(router LAN IP — split-horizon DNS)${NC}"
                    _ext_ip="$(resolve_hostname_via "$_new_ep" 1.1.1.1 2>/dev/null || true)"
                    if [ -n "$_ext_ip" ]; then
                        _wan_now="$(detect_wan_ip 2>/dev/null || true)"
                        if [ -n "$_wan_now" ] && [ "$_ext_ip" = "$_wan_now" ]; then
                            echo -e "  ${DIM2}External (1.1.1.1) → ${_ext_ip}  (matches router WAN)${NC}"
                        else
                            echo -e "  ${DIM2}External (1.1.1.1) → ${_ext_ip}${NC}"
                        fi
                    else
                        echo -e "  ${DIM2}Couldn't verify public answer via 1.1.1.1.${NC}"
                    fi
                    ;;
                private)
                    echo -e "  ${ICO_WARN} ${WARN_C}Resolves to private IP${NC} ${W}${_new_ep_ip}${NC}"
                    echo -e "  ${DIM2}External clients won't reach an RFC1918 address.${NC}"
                    ;;
                external)
                    echo -e "  ${ICO_OK} ${OK}Resolves to${NC} ${W}${_new_ep_ip}${NC}  ${DIM2}(external — not this router's WAN)${NC}"
                    echo -e "  ${DIM2}OK for CGNAT / upstream-forwarded setups.${NC}"
                    ;;
                *)
                    echo -e "  ${ICO_OK} ${OK}Resolves to${NC} ${W}${_new_ep_ip}${NC}"
                    ;;
            esac
        else
            case "$_new_ep" in
                *[!0-9.]*)
                    echo -e "  ${ICO_WARN} ${WARN_C}Could not resolve ${_new_ep} from router${NC}"
                    echo -e "  ${DIM2}Clients will resolve it themselves; OK if transient.${NC}"
                    ;;
            esac
        fi
        echo ""
        confirm "Apply?" "y" || { cancelled; PAUSE; return 0; }
        iface_set "$_iface" endpoint_host "$_new_ep"
        uci commit network
        echo -e "  ${ICO_OK} ${OK}Endpoint set to ${_new_ep}${NC}"
        echo -e "  ${WARN_C}Re-download client configs to apply${NC}"
    else
        echo -e "  ${DIM2}No change${NC}"
    fi
    PAUSE
    return 0
}

# _mi_configure IFACE ZONE — Settings submenu for an interface.
_mi_configure() {
    _iface="$1"; _zone="$2"
    crumb_push "Configure"
    while true; do
        clear
        crumb_show
        uci_network_exists "$_iface" || { crumb_pop; return; }

        _c_dns="$(iface_get "$_iface" dns "-")"
        _c_mtu="$(iface_get "$_iface" mtu "-")"
        _c_dns_search="$(uci -q get "dhcp.@dnsmasq[0].domain" 2>/dev/null || true)"
        _c_port="$(iface_get "$_iface" listen_port "-")"
        _c_ep="$(iface_get "$_iface" endpoint_host)"
        _c_fwmark="$(iface_get "$_iface" fwmark)"
        _c_tab="$(iface_get "$_iface" ip4table)"
        _c_jc="$(iface_get "$_iface" awg_jc)"

        _c_lan_zone="$(iface_lan_zone "$_iface")"
        _c_wan_zone="$(iface_wan_zone "$_iface")"
        _c_fwd_lan_on=0; _c_fwd_wan_on=0
        forwarding_exists "$_zone" "$_c_lan_zone" && _c_fwd_lan_on=1
        forwarding_exists "$_zone" "$_c_wan_zone" && _c_fwd_wan_on=1

        echo -e "${W}Configure ${_iface}${NC}"
        echo ""
        echo -e "${DIM2}──────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${DIM2}Network${NC}"
        if [ -n "$_c_dns_search" ]; then
            _c_dns_shown="${_c_dns}, ${_c_dns_search}"
        else
            _c_dns_shown="$_c_dns"
        fi
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${W}DNS${NC}              ${DIM2}${_c_dns_shown}${NC}"
        echo -e "  ${B}m${NC} ${DIM2}›${NC} ${W}MTU${NC}              ${DIM2}${_c_mtu}${NC}"
        echo -e "  ${B}p${NC} ${DIM2}›${NC} ${W}Listen Port${NC}      ${DIM2}${_c_port}${NC}"
        echo -e "  ${B}n${NC} ${DIM2}›${NC} ${W}Endpoint${NC}         ${DIM2}${_c_ep:-auto-detect}${NC}"
        echo ""
        echo -e "  ${DIM2}Routing${NC}"
        if [ "$_c_fwd_lan_on" -eq 1 ]; then
            echo -e "  ${B}l${NC} ${DIM2}›${NC} ${ERR}Disable${NC} LAN Forwarding"
        else
            echo -e "  ${B}l${NC} ${DIM2}›${NC} ${OK}Enable${NC} LAN Forwarding"
        fi
        if [ "$_c_fwd_wan_on" -eq 1 ]; then
            echo -e "  ${B}w${NC} ${DIM2}›${NC} ${ERR}Disable${NC} WAN Forwarding"
        else
            echo -e "  ${B}w${NC} ${DIM2}›${NC} ${OK}Enable${NC} WAN Forwarding"
        fi
        if podkop_present; then
            if podkop_has_interface "$_iface" 2>/dev/null; then
                echo -e "  ${B}k${NC} ${DIM2}›${NC} ${ERR}Unlink${NC} Podkop"
            else
                echo -e "  ${B}k${NC} ${DIM2}›${NC} ${OK}Link${NC} Podkop"
            fi
        fi
        echo -e "  ${B}f${NC} ${DIM2}›${NC} ${W}fwmark${NC}           ${DIM2}${_c_fwmark:-off}${NC}"
        echo -e "  ${B}t${NC} ${DIM2}›${NC} ${W}Route Table${NC}      ${DIM2}${_c_tab:-main}${NC}"
        _c_tunlink="$(iface_get "$_iface" tunlink)"
        _c_nohost="$(iface_get "$_iface" nohostroute)"
        case "$_c_nohost" in 1|on|true) _c_nohost_label="on" ;; *) _c_nohost_label="off" ;; esac
        echo -e "  ${B}u${NC} ${DIM2}›${NC} ${W}tunlink${NC}          ${DIM2}${_c_tunlink:-auto}${NC}"
        echo -e "  ${B}x${NC} ${DIM2}›${NC} ${W}nohostroute${NC}      ${DIM2}${_c_nohost_label}${NC}"
        echo ""
        echo -e "  ${DIM2}AmneziaWG${NC}"
        if [ -n "$_c_jc" ]; then
            _c_jmin="$(iface_get "$_iface" awg_jmin "?")"
            _c_jmax="$(iface_get "$_iface" awg_jmax "?")"
            echo -e "  ${B}o${NC} ${DIM2}›${NC} ${W}Obfuscation${NC}      ${DIM2}Jc=${_c_jc} Jmin=${_c_jmin} Jmax=${_c_jmax}${NC}"
        else
            echo -e "  ${B}o${NC} ${DIM2}›${NC} ${OK}Setup${NC} Obfuscation"
        fi
        echo ""
        echo -e "  ${DIM2}Info${NC}"
        echo -e "  ${B}i${NC} ${DIM2}›${NC} ${W}Show${NC} Public Key"
        echo -e "  ${B}v${NC} ${DIM2}›${NC} ${W}Show${NC} Live Config  ${DIM2}(kernel state)${NC}"
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${W}Monitor${NC} Throughput  ${DIM2}(live rate)${NC}"
        echo -e "  ${B}g${NC} ${DIM2}›${NC} ${W}Test${NC} DNS & Network"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} " && read_choice _c_choice
        sigint_caught && { crumb_pop; return; }
        case "${_c_choice:-}" in
            "")  crumb_pop; return ;;
            d|D) _mi_edit_dns          "$_iface" ;;
            m|M) _mi_edit_mtu          "$_iface" ;;
            p|P) _mi_change_port      "$_iface" ;;
            n|N) _mi_edit_endpoint    "$_iface" ;;
            f|F) _mi_edit_fwmark      "$_iface" ;;
            t|T) _mi_edit_route_table "$_iface" ;;
            o|O) _mi_obfuscation      "$_iface" ;;
            l|L) _mi_toggle_forwarding "$_iface" "$_zone" "$_c_lan_zone" "$_c_fwd_lan_on" ;;
            w|W) _mi_toggle_forwarding "$_iface" "$_zone" "$_c_wan_zone" "$_c_fwd_wan_on" ;;
            k|K) _mi_toggle_podkop "$_iface" ;;
            u|U) _mi_edit_tunlink     "$_iface" ;;
            x|X) _mi_edit_nohostroute "$_iface" ;;
            i|I) _mi_show_pubkey "$_iface" ;;
            v|V) _mi_show_live_conf "$_iface" ;;
            r|R) _mi_monitor_throughput "$_iface" ;;
            g|G) do_dns_network_test "$_iface"; PAUSE ;;
            *)   warn "Unknown option"; PAUSE ;;
        esac
    done
}

# _mi_edit_dns IFACE — change the DNS the client's .conf will carry. No
# kernel side effects; clients must re-download their config to pick it up.
_mi_edit_dns() {
    _iface="$1"
    section "Edit DNS"
    _cur_dns="$(iface_get "$_iface" "dns")"
    _new_dns=""
    if ! select_dns _new_dns "$_cur_dns"; then
        return 0
    fi
    if [ -z "$_new_dns" ] || [ "$_new_dns" = "$_cur_dns" ]; then
        echo -e "  ${DIM2}No change${NC}"; PAUSE; return 0
    fi
    _TC="\033[36G"
    echo ""
    _ed_test="$(_dns_test "$_new_dns")"
    if [ "$_ed_test" = "fail" ]; then
        echo -e "  ${ICO_ERR} ${ERR}${_new_dns} is not a DNS server or is not responding${NC}"
        confirm "Use anyway?" "n" || { PAUSE; return 0; }
    else
        echo -e "  ${ICO_OK} ${OK}DNS responds${NC}  $(_dns_fmt_latency "$_ed_test")"
    fi
    check_dns_poisoning "facebook.com" "$_new_dns"
    _ed_pr=$?
    if [ "$_ed_pr" -eq 0 ]; then
        echo -e "  ${ICO_OK} ${OK}DNS clean${NC}"
    elif [ "$_ed_pr" -eq 1 ]; then
        echo -e "  ${ICO_ERR} ${ERR}DNS poisoning detected (127.x.x.x)${NC}"
    else
        echo -e "  ${ICO_WARN} ${WARN_C}DNS poisoning check unavailable${NC}"
    fi
    echo ""
    confirm "Apply?" "y" || { cancelled; PAUSE; return 0; }
    iface_set "$_iface" "dns" "$_new_dns"
    uci commit network
    echo -e "  ${ICO_OK} ${OK}DNS set to ${_new_dns}${NC}"
    echo -e "  ${WARN_C}Existing peer configs contain the old value — re-download to apply${NC}"
    PAUSE
    return 0
}

# _mi_edit_mtu IFACE — change tunnel MTU. Live-applied via `ip link set mtu`,
# no ifdown needed. Client .conf also carries the MTU so clients must
# re-download or adjust manually.
_mi_edit_mtu() {
    _iface="$1"
    section "Edit MTU"
    _cur_mtu="$(iface_get "$_iface" "mtu" "$CFG_DEFAULT_MTU")"
    # Recommended MTU from `ip route get <endpoint>`.
    _ep_for_mtu="$(iface_get "$_iface" endpoint_host)"
    [ -z "$_ep_for_mtu" ] && _ep_for_mtu="1.1.1.1"
    _rec_mtu="$(recommend_mtu "$_ep_for_mtu")"
    echo -e "  ${A}Current:${NC}     ${W}${_cur_mtu}${NC}"
    echo -e "  ${A}Recommended:${NC} ${W}${_rec_mtu}${NC}  ${DIM2}(upstream − 80)${NC}"
    echo ""
    prompt _new_mtu "MTU" "$_cur_mtu" || return 0
    sigint_caught && return 0
    [ "$_new_mtu" = "$_cur_mtu" ] && { echo -e "  ${DIM2}No change${NC}"; PAUSE; return 0; }
    case "$_new_mtu" in *[!0-9]*) warn "MTU must be numeric"; PAUSE; return 0 ;; esac
    [ "$_new_mtu" -ge 1200 ] 2>/dev/null || warn "MTU below 1200 is unusual"
    [ "$_new_mtu" -le 1500 ] 2>/dev/null || { warn "MTU above 1500 is invalid"; PAUSE; return 0; }
    iface_set "$_iface" "mtu" "$_new_mtu"
    uci commit network
    live_iface_set_mtu "$_iface" "$_new_mtu" || true
    echo -e "  ${ICO_OK} ${OK}MTU set to ${_new_mtu}${NC}"
    echo -e "  ${WARN_C}Existing peer configs contain the old value — re-download to apply${NC}"
    PAUSE
    return 0
}

do_manage_interface() {
    _iface="$1"
    crumb_push "Interfaces"; crumb_push "$_iface"
    while true; do
        clear
        crumb_show
        uci_network_exists "$_iface" || { crumb_pop; crumb_pop; return; }

        _addr="$(iface_get "$_iface" addresses "n/a")"
        _port="$(iface_get "$_iface" listen_port "n/a")"
        _dns="$(uci  -q get "network.${_iface}.dns" || echo "n/a")"
        _mtu="$(iface_get "$_iface" mtu "n/a")"
        _zone="$(find_zone_for_interface "$_iface" 2>/dev/null || echo "none")"
        _peer_count="$(count_peers "$_iface")"
        _disabled="$(iface_get "$_iface" disabled "0")"

        _lan_zone="$(iface_lan_zone "$_iface")"
        _wan_zone="$(iface_wan_zone "$_iface")"
        _fwd_lan_on=0; _fwd_wan_on=0
        _fwd_lan="${ICO_ERR}"; forwarding_exists "$_zone" "$_lan_zone" && { _fwd_lan="${ICO_OK}"; _fwd_lan_on=1; }
        _fwd_wan="${ICO_ERR}"; forwarding_exists "$_zone" "$_wan_zone" && { _fwd_wan="${ICO_OK}"; _fwd_wan_on=1; }

        # Public key (truncated)
        _srv_priv="$(iface_get "$_iface" private_key)"
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

        # Total Rx/Tx across all peers — sum raw bytes from `awg show dump`.
        # Packet counts come from kernel netdev stats (awg dump has no pkts).
        _rx_sum=""; _tx_sum=""; _rx_pkts=""; _tx_pkts=""
        if [ "$_disabled" != "1" ] && interface_device_exists "$_iface" && have_cmd awg; then
            _sums="$(awg show "$_iface" dump 2>/dev/null | awk -F'\t' '
                NR>1 { rx+=$6; tx+=$7 } END { printf "%d %d\n", rx+0, tx+0 }')"
            if [ -n "$_sums" ]; then
                _rx_sum="$(fmt_bytes "${_sums%% *}")"
                _tx_sum="$(fmt_bytes "${_sums##* }")"
            fi
            if [ -r "/sys/class/net/${_iface}/statistics/rx_packets" ]; then
                _rx_pkts="$(cat "/sys/class/net/${_iface}/statistics/rx_packets" 2>/dev/null || true)"
                _tx_pkts="$(cat "/sys/class/net/${_iface}/statistics/tx_packets" 2>/dev/null || true)"
            fi
            _rx_err=0; _rx_drp=0; _tx_err=0; _tx_drp=0
            for _k in rx_errors rx_dropped tx_errors tx_dropped; do
                _f="/sys/class/net/${_iface}/statistics/${_k}"
                [ -r "$_f" ] || continue
                _val="$(cat "$_f" 2>/dev/null || echo 0)"
                case "$_k" in
                    rx_errors)  _rx_err="${_val:-0}" ;;
                    rx_dropped) _rx_drp="${_val:-0}" ;;
                    tx_errors)  _tx_err="${_val:-0}" ;;
                    tx_dropped) _tx_drp="${_val:-0}" ;;
                esac
            done
        fi

        # Podkop status
        # Detect podkop state (sets PK_* globals)
        detect_podkop_state "$_iface"

        _ep_override="$(iface_get "$_iface" endpoint_host)"
        _ep_resolved=""
        if [ -n "$_ep_override" ]; then
            _ep_display="$_ep_override"
            # Show resolved IP when the override is a DNS name, so the box
            # reflects what the tunnel will actually connect to.
            _ep_resolved="$(resolve_hostname "$_ep_override" 2>/dev/null || true)"
        else
            _ep_display="$(detect_wan_ip 2>/dev/null || true)"
            [ -z "$_ep_display" ] && _ep_display="auto"
        fi
        _dns_chain="$(dns_chain_label "$_iface")"
        if [ -n "$_dns_chain" ]; then _dns_chain="  ${_dns_chain}"; fi
        # Client-emitted DNS line: the LAN domain is appended as search
        # suffix in reconstruct_peer_config, so display the full literal
        # here too (what you see is what the .conf gets).
        _dns_search="$(uci -q get "dhcp.@dnsmasq[0].domain" 2>/dev/null || true)"
        if [ -n "$_dns_search" ]; then
            _dns_shown="${_dns}, ${_dns_search}"
        else
            _dns_shown="$_dns"
        fi

        box_buf_reset
        box_buf_line "  ${_st_ico} ${W}${_iface}${NC}  ${_st_txt}"

        # Identity
        box_buf_sep
        box_buf_line "  ${A}Address${NC}      ${W}${_addr}${NC}"
        if [ -n "$_srv_pub_short" ]; then
            box_buf_line "  ${A}Public${NC}       ${DIM2}${_srv_pub_short}${NC}"
        fi

        # Client Config — what lands in emitted .conf
        box_buf_sep
        box_buf_line "  ${A}Endpoint${NC}     ${W}${_ep_display}:${_port}${NC}"
        if [ -n "$_ep_resolved" ] && [ "$_ep_resolved" != "$_ep_display" ]; then
            _ep_cat="$(classify_endpoint_ip "$_ep_resolved" 2>/dev/null || echo "")"
            case "$_ep_cat" in
                wan)      _ep_cat_lbl=" ${OK}(matches WAN)${NC}" ;;
                hairpin)  _ep_cat_lbl=" ${WARN_C}(split-horizon DNS)${NC}" ;;
                private)  _ep_cat_lbl=" ${ERR}(private — unreachable from WAN)${NC}" ;;
                external) _ep_cat_lbl=" ${DIM2}(external, ≠ router WAN)${NC}" ;;
                *)        _ep_cat_lbl="" ;;
            esac
            box_buf_line "               ${DIM2}↳ ${_ep_resolved}${NC}${_ep_cat_lbl}"
            box_buf_line ""
        fi
        box_buf_line "  ${A}DNS${NC}          ${W}${_dns_shown}${NC}${_dns_chain}"
        box_buf_line "  ${A}MTU${NC}          ${W}${_mtu}${NC}"
        _ifc_jc="$(iface_get "$_iface" awg_jc)"
        if [ -n "$_ifc_jc" ]; then
            _ifc_jmin="$(iface_get "$_iface" awg_jmin "?")"
            _ifc_jmax="$(iface_get "$_iface" awg_jmax "?")"
            box_buf_line "  ${A}Obfuscation${NC}  ${OK}AmneziaWG${NC}  ${DIM2}Jc=${_ifc_jc} Jmin=${_ifc_jmin} Jmax=${_ifc_jmax}${NC}"
        else
            box_buf_line "  ${A}Obfuscation${NC}  ${DIM2}plain WireGuard${NC}"
        fi

        # Firewall
        box_buf_sep
        box_buf_line "  ${A}Zone${NC}         ${W}${_zone}${NC}"
        if [ -n "$_port" ]; then
            _wan_zone_now="$(detect_wan_zone 2>/dev/null || true)"
            if [ -n "$_wan_zone_now" ] \
               && port_allowed_in_zone "$_port" "$_wan_zone_now" udp; then
                box_buf_line "  ${A}Port${NC}         ${ICO_OK} ${_port}"
            else
                box_buf_line "  ${A}Port${NC}         ${ICO_ERR} Unreachable"
            fi
        fi
        box_buf_line "  ${A}Routing${NC}      ${_fwd_lan} LAN  ${_fwd_wan} WAN"
        if [ "${PK_INSTALLED:-0}" -eq 1 ]; then
            if [ "$PK_LINKED" -eq 0 ]; then
                box_buf_line "  ${A}Podkop${NC}       ${DIM2}Not linked${NC}"
            elif [ "$SB_RUNNING" -eq 1 ] && [ "$SB_DNS" -eq 1 ] && [ "$DM_OK" -eq 1 ]; then
                box_buf_line "  ${A}Podkop${NC}       ${OK}Active${NC}  ${DIM2}Sing-Box ✓  dns ✓${NC}"
            elif [ "$SB_RUNNING" -eq 1 ] && [ "$SB_DNS" -eq 1 ]; then
                box_buf_line "  ${A}Podkop${NC}       ${OK}Active${NC}  ${WARN_C}dnsmasq misconfigured${NC}"
            elif [ "$SB_RUNNING" -eq 1 ]; then
                box_buf_line "  ${A}Podkop${NC}       ${WARN_C}Sing-Box running, DNS not listening${NC}"
            else
                box_buf_line "  ${A}Podkop${NC}       ${ERR}Linked but Sing-Box stopped${NC}"
            fi
        elif [ "${SB_DNS:-0}" -eq 1 ] && [ "${DM_FWD:-0}" -eq 1 ]; then
            box_buf_line "  ${A}Sing-Box${NC}     ${OK}Active${NC}  ${DIM2}dnsmasq → ${CFG_SB_DNS_IP}${NC}"
        elif [ "${SB_RUNNING:-0}" -eq 1 ]; then
            box_buf_line "  ${A}Sing-Box${NC}     ${WARN_C}Running${NC}  ${DIM2}DNS not configured${NC}"
        fi

        # Runtime — only when iface is up
        if [ -n "$_uptime_str" ] || [ -n "$_rx_sum" ]; then
            box_buf_sep
            if [ -n "$_uptime_str" ]; then
                box_buf_line "  ${A}Uptime${NC}       ${W}${_uptime_str}${NC}"
            fi
            if [ -n "$_rx_sum" ]; then
                # Pad rx/tx to the same width so pkts counts column-align.
                _pk_w="${#_rx_sum}"
                [ "${#_tx_sum}" -gt "$_pk_w" ] && _pk_w="${#_tx_sum}"
                _rx_pad="$(printf "%-${_pk_w}s" "$_rx_sum")"
                _tx_pad="$(printf "%-${_pk_w}s" "$_tx_sum")"
                _rx_pkts_s=""; _tx_pkts_s=""
                [ -n "$_rx_pkts" ] && _rx_pkts_s=" ${DIM2}(${_rx_pkts} pkts)${NC}"
                [ -n "$_tx_pkts" ] && _tx_pkts_s=" ${DIM2}(${_tx_pkts} pkts)${NC}"
                box_buf_line "  ${A}Packets${NC}      ${DIM2}↓${NC} ${W}${_rx_pad}${NC}${_rx_pkts_s}"
                box_buf_line "               ${DIM2}↑${NC} ${W}${_tx_pad}${NC}${_tx_pkts_s}"
                if [ "${_rx_err:-0}" -gt 0 ] || [ "${_rx_drp:-0}" -gt 0 ] \
                   || [ "${_tx_err:-0}" -gt 0 ] || [ "${_tx_drp:-0}" -gt 0 ]; then
                    _rx_err_s=""; _tx_err_s=""
                    _sep_rx=""; _sep_tx=""
                    if [ "${_rx_err:-0}" -gt 0 ]; then
                        _rx_e_n="error"; [ "$_rx_err" -gt 1 ] && _rx_e_n="errors"
                        _rx_err_s=" ${ERR}${_rx_err} ${_rx_e_n}${NC}"
                        _sep_rx=","
                    fi
                    if [ "${_rx_drp:-0}" -gt 0 ]; then
                        _rx_err_s="${_rx_err_s}${_sep_rx} ${WARN_C}${_rx_drp} dropped${NC}"
                    fi
                    if [ "${_tx_err:-0}" -gt 0 ]; then
                        _tx_e_n="error"; [ "$_tx_err" -gt 1 ] && _tx_e_n="errors"
                        _tx_err_s=" ${ERR}${_tx_err} ${_tx_e_n}${NC}"
                        _sep_tx=","
                    fi
                    if [ "${_tx_drp:-0}" -gt 0 ]; then
                        _tx_err_s="${_tx_err_s}${_sep_tx} ${WARN_C}${_tx_drp} dropped${NC}"
                    fi
                    if [ -n "$_rx_err_s" ] && [ -n "$_tx_err_s" ]; then
                        box_buf_line "  ${A}Errors${NC}       ${DIM2}↓${NC}${_rx_err_s}"
                        box_buf_line "               ${DIM2}↑${NC}${_tx_err_s}"
                    elif [ -n "$_rx_err_s" ]; then
                        box_buf_line "  ${A}Errors${NC}       ${DIM2}↓${NC}${_rx_err_s}"
                    elif [ -n "$_tx_err_s" ]; then
                        box_buf_line "  ${A}Errors${NC}       ${DIM2}↑${NC}${_tx_err_s}"
                    fi
                fi
            fi
        fi
        box_buf_flush 44

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
        _is_l="$(iface_get "$_iface" _liminal_iface)"
        [ -n "$_is_l" ] && _is_l="1" || _is_l="0"

        # ── Inline peer list ──
        _pt="amneziawg_${_iface}"
        _PC="\\033[10G"  # Name column
        _PS="\\033[28G"  # Status/info column
        echo -e "  ${DIM2}Peers${NC}"
        _pi=0; _peer_found=0
        while peer_exists "$_pt" "$_pi"; do
            _peer_found=1; _pn=$((_pi + 1))
            _pdesc="$(peer_get "$_pt" "$_pi" description "(unnamed)")"
            _paip="$(peer_get "$_pt" "$_pi" allowed_ips "?")"
            _ppub="$(peer_get "$_pt" "$_pi" public_key)"
            _pdis="$(peer_get "$_pt" "$_pi" disabled "0")"
            _phost="${_paip%%/*}"; _phost="${_phost##*.}"

            if [ "$_pdis" = "1" ]; then
                echo -e "  ${B}${_pn}${NC} ${DIM2}›${NC} ${ICO_DIS}${_PC}${DIM2}${_pdesc}${NC}${_PS}${DIM2}#${_phost}${NC}"
            elif [ "$_disabled" != "1" ] && interface_device_exists "$_iface"; then
                _hs="$(get_peer_handshake "$_iface" "$_ppub")"
                _hs_sec=9999
                if [ -n "$_hs" ] && [ "$_hs" != "-" ] && [ "$_hs" != "never" ]; then
                    _hs_sec="$(awg_peer_handshake_age "$_iface" "$_ppub")"
                    if [ "${_hs_sec:-9999}" -le "120" ] 2>/dev/null; then
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

        # ── Interface ──
        echo -e "  ${DIM2}Interface${NC}"
        echo -e "  ${B}c${NC} ${DIM2}›${NC} ${W}Configure${NC} Interface"
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

            c|C) _mi_configure "$_iface" "$_zone" ;;

            r|R) restart_iface "$_iface"
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
                _sel_desc="$(peer_get "$_pt" "$_sel_idx" description)"
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
        _is_l="$(iface_get "$iface" _liminal_iface)"
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
    echo -e "${DIM2}──────────────────────────────────────${NC}"
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
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${W}${iface}${NC}  ${DIM2}·${NC}  Active: ${OK}${_active_count}${NC} of ${_peer_count}"
            else
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${W}${iface}${NC}  ${DIM2}·${NC}  Peers: ${_peer_count}  ${DIM2}·${NC}  ${ERR}Down${NC}"
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
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${DIM2}${iface}${NC}  ${DIM2}·${NC}  Active: ${OK}${_active_count}${NC} of ${_peer_count}"
            else
                echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${DIM2}${iface}${NC}  ${DIM2}·${NC}  Peers: ${_peer_count}  ${DIM2}·${NC}  ${ERR}Down${NC}"
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

    section "New name"

    while true; do
        prompt _new "New interface name" "" || return 1
        sigint_caught && return 1
        [ -z "$_new" ] && { cancelled; return 1; }
        [ "$_new" = "$_old" ] && { warn "Same as current name"; continue; }
        validate_ifname "$_new" || continue
        uci_network_exists "$_new"     && { warn "Interface '$_new' already exists"; continue; }
        interface_device_exists "$_new" && { warn "Device '$_new' already exists"; continue; }
        break
    done

    _old_zone="$(find_zone_for_interface "$_old" 2>/dev/null || true)"
    _old_port="$(iface_get "$_old" listen_port)"
    _has_podkop=0
    podkop_present && podkop_has_interface "$_old" 2>/dev/null && _has_podkop=1

    _new_zone="$(generate_zone_name "$_new")"
    _new_rule="Allow-AWG-${_new}"
    rule_exists_by_name "$_new_rule" && _new_rule="$(generate_rule_name "$_new")"

    section "Changes"

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

    confirm "Proceed with rename?" "n" || { cancelled; return 1; }

    init_backup "Pre-Interface Rename"

    spinner_start "Stopping ${_old}..."
    ifdown "$_old" >/dev/null 2>&1 || true
    spinner_stop

    # ── 1. Copy network interface (schema-driven — new fields auto-propagate) ──
    echo -e "  ${B}Creating${NC} new interface ${W}${_new}${NC}"
    uci set "network.${_new}=interface"
    iface_copy_fields "$_old" "$_new"
    uci set "network.${_new}._liminal_iface=${_new}"

    # ── 2. Copy all peers (schema-driven) ──
    _old_pt="amneziawg_${_old}"
    _new_pt="amneziawg_${_new}"
    _pi=0
    while peer_exists "$_old_pt" "$_pi"; do
        _sec="$(uci add network "$_new_pt")"
        peer_copy_fields "$_old_pt" "$_pi" "$_sec"
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
    if podkop_present && [ "$_has_podkop" -eq 1 ]; then
        apply_all podkop
    else
        apply_all
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

    DEL_PORT="$(iface_get "$DEL_IFACE" listen_port)"
    DEL_ZONE="$(find_zone_for_interface "$DEL_IFACE" 2>/dev/null || true)"

    section "Will be removed"

    echo -e "  ${ERR}-${NC} Interface        ${W}$DEL_IFACE${NC}"
    echo -e "  ${ERR}-${NC} All peers        ${W}$DEL_IFACE${NC}"
    [ -n "$DEL_ZONE" ] && \
    echo -e "  ${ERR}-${NC} FW Zone          ${W}$DEL_ZONE${NC}  (+ forwarding)"
    [ -n "$DEL_PORT" ] && \
    echo -e "  ${ERR}-${NC} FW Rules         port ${W}$DEL_PORT${NC}/udp"
    if podkop_present && podkop_has_interface "$DEL_IFACE" 2>/dev/null; then
        echo -e "  ${ERR}-${NC} Podkop           ${W}$DEL_IFACE${NC}"
    fi
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
    if podkop_present; then apply_all podkop; else apply_all; fi

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
    echo -e "${DIM2}──────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${WARN_C}NOTE: A static public IP address (or a DDNS hostname) and${NC}"
    echo -e "  ${WARN_C}NAT port forwarding (UDP) on your upstream router are${NC}"
    echo -e "  ${WARN_C}required for external clients to connect to this tunnel.${NC}"
    echo -e "  ${DIM2}(Ctrl+C = cancel)${NC}"

    # ── Network ──────────────────────────────────────────────────────
    section "Network"

    while true; do
        prompt IFNAME "Interface name" "awg0" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        validate_ifname "$IFNAME" || continue
        uci_network_exists "$IFNAME"      && { warn "Interface '$IFNAME' already exists"; continue; }
        interface_device_exists "$IFNAME"  && { warn "Device '$IFNAME' already exists"; continue; }
        break
    done

    _auto_addr="$(find_free_subnet || true)"
    if [ -n "$_auto_addr" ]; then
        IFADDR="$_auto_addr"
        echo -e "  ${ICO_OK} ${OK}Subnet:${NC} ${W}$IFADDR${NC}"
        if ! confirm "Use this address?" "y"; then
            while true; do
                prompt IFADDR "Interface address with CIDR" "$_auto_addr" || { trap_restore; return; }
                is_cancelled && { trap_restore; return; }
                [ -z "$IFADDR" ] && { warn "Required field"; continue; }
                validate_cidr_ipv4 "$IFADDR" || continue
                _addr_conflict=""
                _new_subnet="$(network_base_from_cidr "$IFADDR")"
                _new_ip="${IFADDR%/*}"
                _all_ifaces="$(uci show network 2>/dev/null \
                    | sed -n "s/^network\.\([^.]*\)\.addresses=.*/\1/p" \
                    | sort -u)"
                for _eif in $_all_ifaces; do
                    for _ev in $(iface_get "$_eif" addresses); do
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
        fi
    else
        while true; do
            prompt IFADDR "Interface address with CIDR (e.g. 10.10.10.1/24)" "" || { trap_restore; return; }
            is_cancelled && { trap_restore; return; }
            [ -z "$IFADDR" ] && { warn "Required field"; continue; }
            validate_cidr_ipv4 "$IFADDR" || continue
            _addr_conflict=""
            _new_subnet="$(network_base_from_cidr "$IFADDR")"
            _new_ip="${IFADDR%/*}"
            _all_ifaces="$(uci show network 2>/dev/null \
                | sed -n "s/^network\.\([^.]*\)\.addresses=.*/\1/p" \
                | sort -u)"
            for _eif in $_all_ifaces; do
                for _ev in $(iface_get "$_eif" addresses); do
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
    fi
    IF_IP="${IFADDR%/*}"
    IF_SUBNET="$(network_base_from_cidr "$IFADDR")"

    while true; do
        prompt PORT "Listen port" "$CFG_DEFAULT_PORT" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        validate_port "$PORT" || continue
        port_in_use "$PORT" && { warn "Port $PORT is already in use"; continue; }
        FW_MATCH="$(firewall_port_in_use "$PORT" || true)"
        [ -n "$FW_MATCH" ] && { warn "Port $PORT is used by FW rule '$FW_MATCH'"; continue; }
        break
    done

    # MTU default: detect upstream MTU and subtract 80 (AWG/WG overhead).
    # Fall back to the static suggestion from liminal.settings if detection fails.
    _mtu_hint="$(recommend_mtu 1.1.1.1 2>/dev/null || echo "$CFG_MTU_SUGGESTION")"
    [ "$_mtu_hint" -lt 1200 ] 2>/dev/null && _mtu_hint="$CFG_MTU_SUGGESTION"
    echo -e "  ${DIM2}Recommended: ${W}${_mtu_hint}${DIM2} (upstream MTU − 80)${NC}"
    while true; do
        prompt MTU_VALUE "MTU" "$_mtu_hint" || { trap_restore; return; }
        is_cancelled && { trap_restore; return; }
        case "$MTU_VALUE" in *[!0-9]*) warn "MTU must be numeric"; continue ;; esac
        [ "$MTU_VALUE" -ge 1200 ] 2>/dev/null || warn "MTU below 1200 is unusual"
        [ "$MTU_VALUE" -le 1500 ] 2>/dev/null || { warn "MTU above 1500 is invalid"; continue; }
        break
    done

    # ── Firewall ─────────────────────────────────────────────────────
    section "Firewall"

    ROUTER_LAN_IP="$(detect_router_lan_ip || true)"
    if [ -z "$ROUTER_LAN_IP" ]; then
        while true; do
            prompt ROUTER_LAN_IP "Could not detect router LAN IP — enter manually" "" || { trap_restore; return; }
            is_cancelled && { trap_restore; return; }
            [ -z "$ROUTER_LAN_IP" ] && { warn "Required field"; continue; }
            validate_ipv4 "$ROUTER_LAN_IP" && break
        done
    else
        echo -e "  ${ICO_OK} ${OK}LAN IP:${NC}   ${W}$ROUTER_LAN_IP${NC}"
    fi

    if cidr_contains_ip "$IF_SUBNET" "$ROUTER_LAN_IP"; then
        warn "AWG subnet '$IF_SUBNET' overlaps with router LAN IP '$ROUTER_LAN_IP'"
        PAUSE; return
    fi

    ZONE_NAME="$(generate_zone_name "$IFNAME")"
    INCOMING_RULE_NAME="$(generate_rule_name "$IFNAME")"
    echo -e "  ${ICO_OK} ${OK}FW zone:${NC}  ${W}$ZONE_NAME${NC}"
    echo -e "  ${ICO_OK} ${OK}FW rule:${NC}  ${W}$INCOMING_RULE_NAME${NC}"

    # Auto-detect LAN/WAN zones
    _zones="$(list_zones)"
    if zone_exists "lan"; then
        LAN_ZONE="lan"
    else
        echo ""
        echo -e "  ${A}Available firewall zones:${NC}"
        _zi=0
        for _z in $_zones; do
            _zi=$((_zi + 1))
            echo -e "    ${B}${_zi}${NC} ${DIM2}›${NC} ${W}${_z}${NC}"
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
    fi
    echo -e "  ${ICO_OK} ${OK}LAN zone:${NC} ${W}$LAN_ZONE${NC}"

    if zone_exists "wan"; then
        WAN_ZONE="wan"
    else
        _remaining=""
        for _z in $_zones; do
            [ "$_z" = "$LAN_ZONE" ] && continue
            _remaining="${_remaining} ${_z}"
        done
        echo ""
        echo -e "  ${A}Available WAN zones:${NC}"
        _zi=0
        for _z in $_remaining; do
            _zi=$((_zi + 1))
            echo -e "    ${B}${_zi}${NC} ${DIM2}›${NC} ${W}${_z}${NC}"
        done
        echo ""
        while true; do
            prompt _wan_pick "Select WAN zone number" "" || { trap_restore; return; }
            is_cancelled && { trap_restore; return; }
            [ -z "$_wan_pick" ] && { warn "Required field"; continue; }
            _zn=0; WAN_ZONE=""
            for _z in $_remaining; do
                _zn=$((_zn + 1))
                [ "$_zn" = "$_wan_pick" ] && { WAN_ZONE="$_z"; break; }
            done
            [ -z "$WAN_ZONE" ] && { warn "Invalid selection"; continue; }
            break
        done
    fi
    echo -e "  ${ICO_OK} ${OK}WAN zone:${NC} ${W}$WAN_ZONE${NC}"

    # ── Routing ──────────────────────────────────────────────────────
    section "Routing"

    ALLOW_LAN_FORWARD="0"; ALLOW_WAN_FORWARD="0"
    confirm "Allow routing to LAN?" "y" && ALLOW_LAN_FORWARD="1"
    confirm "Allow routing to WAN?" "y" && ALLOW_WAN_FORWARD="1"
    if [ "$ALLOW_LAN_FORWARD" = "0" ] && [ "$ALLOW_WAN_FORWARD" = "0" ]; then
        warn "At least one routing direction (LAN or WAN) required"
        PAUSE; return
    fi

    # ── DNS ──────────────────────────────────────────────────────────
    section "DNS"

    USE_PODKOP="0"; DNS_IP=""
    if podkop_present; then
        echo -e "  ${ICO_OK} ${OK}Podkop found${NC}"
        if [ "$SB_RUNNING" -eq 1 ] && [ "$SB_DNS" -eq 1 ]; then
            echo -e "  ${DIM2}  Sing-Box listening on ${CFG_SB_DNS_IP}:53${NC}"
            if [ "$DM_FWD" -eq 1 ]; then
                echo -e "  ${DIM2}  DNS chain: peer → dnsmasq → Sing-Box → internet${NC}"
            else
                echo -e "  ${WARN_C}  dnsmasq is not forwarding to Sing-Box (missing server ${CFG_SB_DNS_IP})${NC}"
            fi
        elif [ "$SB_RUNNING" -eq 0 ]; then
            echo -e "  ${WARN_C}  Sing-Box is not running${NC}"
        fi
        echo ""
        if confirm "Configure Podkop-aware routing?" "y"; then
            USE_PODKOP="1"
            DNS_IP="$ROUTER_LAN_IP"
            if [ "$SB_DNS" -eq 1 ] && [ "$DM_FWD" -eq 1 ]; then
                echo -e "  ${ICO_OK} ${OK}Client DNS:${NC} ${W}$DNS_IP${NC} ${DIM2}→ dnsmasq → Sing-Box${NC}"
            else
                echo -e "  ${ICO_OK} ${OK}Client DNS:${NC} ${W}$DNS_IP${NC} ${DIM2}(router LAN)${NC}"
            fi
        fi
    fi
    if [ "$USE_PODKOP" != "1" ]; then
        while true; do
            select_dns DNS_IP && [ -n "$DNS_IP" ] || continue
            _TC="\033[36G"
            echo ""
            _cd_test="$(_dns_test "$DNS_IP")"
            if [ "$_cd_test" = "fail" ]; then
                echo -e "  ${ICO_ERR} ${ERR}${DNS_IP} is not a DNS server or is not responding${NC}"
                confirm "Use anyway?" "n" || continue
            else
                echo -e "  ${ICO_OK} ${OK}DNS responds${NC}  $(_dns_fmt_latency "$_cd_test")"
            fi
            check_dns_poisoning "facebook.com" "$DNS_IP"
            _cd_pr=$?
            if [ "$_cd_pr" -eq 0 ]; then
                echo -e "  ${ICO_OK} ${OK}DNS clean${NC}"
            elif [ "$_cd_pr" -eq 1 ]; then
                echo -e "  ${ICO_ERR} ${ERR}DNS poisoning detected (127.x.x.x)${NC}"
            else
                echo -e "  ${ICO_WARN} ${WARN_C}DNS poisoning check unavailable${NC}"
            fi
            break
        done
    fi

    check_dangerous_forwarding "$ZONE_NAME"

    # ── Summary ──────────────────────────────────────────────────────
    section "Summary"

    echo -e "  ${B}Generating${NC} keys..."
    KEYS="$(generate_awg_keys)"
    SERVER_PRIVKEY="$(printf '%s\n' "$KEYS" | sed -n '1p')"
    SERVER_PUBKEY="$(printf  '%s\n' "$KEYS" | sed -n '2p')"

    echo -e "  ${B}Generating${NC} obfuscation params..."
    OBF="$(generate_awg_obfuscation)"
    AWG_JC="$(printf   '%s\n' "$OBF" | sed -n '1p')"
    AWG_JMIN="$(printf '%s\n' "$OBF" | sed -n '2p')"
    AWG_JMAX="$(printf '%s\n' "$OBF" | sed -n '3p')"
    AWG_S1="$(printf   '%s\n' "$OBF" | sed -n '4p')"
    AWG_S2="$(printf   '%s\n' "$OBF" | sed -n '5p')"
    AWG_S3="$(printf   '%s\n' "$OBF" | sed -n '6p')"
    AWG_S4="$(printf   '%s\n' "$OBF" | sed -n '7p')"
    AWG_H1="$(printf   '%s\n' "$OBF" | sed -n '8p')"
    AWG_H2="$(printf   '%s\n' "$OBF" | sed -n '9p')"
    AWG_H3="$(printf   '%s\n' "$OBF" | sed -n '10p')"
    AWG_H4="$(printf   '%s\n' "$OBF" | sed -n '11p')"
    AWG_I1="$(printf   '%s\n' "$OBF" | sed -n '12p')"
    echo ""

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
    echo -e "  ${A}Obfuscation${NC}  ${DIM2}Jc=${NC}${W}$AWG_JC${NC} ${DIM2}Jmin=${NC}${W}$AWG_JMIN${NC} ${DIM2}Jmax=${NC}${W}$AWG_JMAX${NC} ${DIM2}S1=${NC}${W}$AWG_S1${NC} ${DIM2}S2=${NC}${W}$AWG_S2${NC}"
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
    uci set "network.${IFNAME}.awg_jc=${AWG_JC}"
    uci set "network.${IFNAME}.awg_jmin=${AWG_JMIN}"
    uci set "network.${IFNAME}.awg_jmax=${AWG_JMAX}"
    uci set "network.${IFNAME}.awg_s1=${AWG_S1}"
    uci set "network.${IFNAME}.awg_s2=${AWG_S2}"
    uci set "network.${IFNAME}.awg_s3=${AWG_S3}"
    uci set "network.${IFNAME}.awg_s4=${AWG_S4}"
    uci set "network.${IFNAME}.awg_h1=${AWG_H1}"
    uci set "network.${IFNAME}.awg_h2=${AWG_H2}"
    uci set "network.${IFNAME}.awg_h3=${AWG_H3}"
    uci set "network.${IFNAME}.awg_h4=${AWG_H4}"

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
    apply_all

    # ── Podkop integration ──
    if [ "$USE_PODKOP" = "1" ]; then
        if confirm "Add '$IFNAME' to Podkop source interfaces?" "y"; then
            add_podkop_interface "$IFNAME"
            svc_restart podkop
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
        echo -e "${W}Backup${NC} ${DIM2}·${NC} ${W}${_bname}${NC}"
        echo ""
        echo -e "${DIM2}──────────────────────────────────────${NC}"
        echo ""
        _bsize="$(du -sh "$_bdir" 2>/dev/null | cut -f1 || echo "?")"
        echo -e "  ${A}Date${NC}         ${W}${_date}${NC}"
        echo -e "  ${A}Reason${NC}       ${W}${_reason}${NC}"
        echo -e "  ${A}Size${NC}         ${W}${_bsize}${NC}"
        echo -e "  ${A}Path${NC}         ${DIM2}${_bdir}${NC}"
        echo ""

        _has_net=""; _has_fw=""; _has_pk=""; _has_lim=""
        [ -f "$_bdir/network.bak" ] && _has_net="${OK}yes${NC}" || _has_net="${DIM2}no${NC}"
        [ -f "$_bdir/firewall.bak" ] && _has_fw="${OK}yes${NC}" || _has_fw="${DIM2}no${NC}"
        [ -f "$_bdir/podkop.bak" ] && _has_pk="${OK}yes${NC}" || _has_pk="${DIM2}no${NC}"
        [ -f "$_bdir/liminal.bak" ] && _has_lim="${OK}yes${NC}" || _has_lim="${DIM2}no${NC}"
        echo -e "  ${A}Network${NC}      ${_has_net}"
        echo -e "  ${A}Firewall${NC}     ${_has_fw}"
        echo -e "  ${A}Podkop${NC}       ${_has_pk}"
        echo -e "  ${A}Liminal${NC}      ${_has_lim}"
        echo ""
        echo -e "${DIM2}──────────────────────────────────────${NC}"
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
        echo -e "${DIM2}──────────────────────────────────────${NC}"
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
            echo -e "  ${B}${_n}${NC} ${DIM2}›${NC} ${W}${_date}${NC} ${DIM2}·${NC} ${A}${_reason}${NC} ${DIM2}${_bsize}${NC}"
        done

        [ "$_n" -eq 0 ] && echo -e "${DIM2}No backups found${NC}"

        echo ""
        echo -e "${DIM2}──────────────────────────────────────${NC}"
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
                if autobackup_enabled; then
                    uci set liminal.settings.auto_backup='0'
                    uci commit liminal
                    CFG_AUTO_BACKUP="0"
                    echo -e "  ${OK}Auto-backup disabled${NC}"
                else
                    uci set liminal.settings.auto_backup='1'
                    uci commit liminal
                    CFG_AUTO_BACKUP="1"
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
    echo -e "${DIM2}──────────────────────────────────────${NC}"
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

    echo -e "${DIM2}──────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${ERR}This action cannot be undone.${NC}"
    echo ""
    confirm "Confirm full reset?" "n" || return

    # Delete each interface with full cleanup
    for iface in $interfaces; do
        _port="$(iface_get "$iface" listen_port)"
        _zone="$(find_zone_for_interface "$iface" 2>/dev/null || true)"

        remove_iface_hostrecords "$iface"

        while uci -q get "network.@amneziawg_${iface}[0]" >/dev/null 2>&1; do
            uci delete "network.@amneziawg_${iface}[0]"
        done

        echo -e "  ${B}Removing${NC} ${W}${iface}${NC}..."
        uci delete "network.${iface}" 2>/dev/null || true

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

        if [ -n "$_zone" ]; then
            _zi="$(find_zone_index "$_zone" || true)"
            if [ -n "$_zi" ]; then
                _zl="$(uci -q get "firewall.@zone[$_zi]._liminal_iface" || true)"
                [ "$_zl" = "$iface" ] && uci delete "firewall.@zone[$_zi]"
            fi
        fi

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
    svc_reload network
    svc_restart firewall
    if podkop_present && [ -x /etc/init.d/podkop ]; then
        echo -e "  ${B}Restarting${NC} Podkop..."
        svc_restart podkop
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

    # Check GitHub API rate limit before fetching raw file
    if have_cmd curl; then
        _fv_resp="$(curl -s "https://api.github.com/repos/${LIMINAL_REPO}/releases/latest" 2>/dev/null || true)"
        if echo "$_fv_resp" | grep -q 'API rate limit '; then
            echo ""; return
        fi
    fi

    wget -qO- "$LIMINAL_RAW_URL" 2>/dev/null \
        | sed -n 's/^LIMINAL_VERSION="\([^"]*\)"/\1/p' | head -n1
}

do_self_update() {
    echo ""
    echo -e "  ${B}Checking for updates...${NC}"

    if ! check_dns; then
        warn "DNS is not working — cannot check for updates"
        PAUSE; return
    fi

    _remote_ver="$(fetch_remote_version)"
    if [ -z "$_remote_ver" ]; then
        warn "Could not fetch remote version (rate limit, no internet, or wget missing)"
        PAUSE; return
    fi
    if [ "$_remote_ver" = "$LIMINAL_VERSION" ]; then
        echo -e "  ${OK}Already up to date${NC} (v${LIMINAL_VERSION})"
        PAUSE; return
    fi
    if ! version_newer "$_remote_ver" "$LIMINAL_VERSION"; then
        echo -e "  ${OK}Local version (v${LIMINAL_VERSION}) is newer than remote (v${_remote_ver})${NC}"
        PAUSE; return
    fi
    echo -e "  ${A}Current:${NC} v${LIMINAL_VERSION}"
    echo -e "  ${A}Remote:${NC}  v${_remote_ver}"
    echo ""
    confirm "Update to v${_remote_ver}?" "y" || return

    # Backup before major version change
    _cur_major="$(version_major "$LIMINAL_VERSION")"
    _rem_major="$(version_major "$_remote_ver")"
    if [ "$_cur_major" != "$_rem_major" ]; then
        echo -e "  ${WARN_C}Major version change detected (v${_cur_major}.x → v${_rem_major}.x)${NC}"
        autobackup_enabled && init_backup "Pre-Update v${LIMINAL_VERSION}→v${_remote_ver}"
        echo -e "  ${ICO_OK} ${OK}Backup created:${NC} ${DIM2}${BACKUP_DIR}${NC}"
    fi

    _tmp="$(mktemp /tmp/liminal-update.XXXXXX)" || { warn "mktemp failed"; PAUSE; return; }
    echo -e "  ${B}Downloading...${NC}"
    if ! wget_retry "$LIMINAL_RAW_URL" "$_tmp"; then
        rm -f "$_tmp"
        warn "Download failed after ${DOWNLOAD_RETRIES} attempts"
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

# EXPORT_DIR set by liminal_config_load()

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
        _iface_json="$(iface_to_json "$iface")"
        _pt="amneziawg_${iface}"
        _pi=0
        while peer_exists "$_pt" "$_pi"; do
            _peer_json="$(peer_to_json "$_pt" "$_pi")"
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

    section "Import"

    prompt _import_file "Path to export JSON file" "" || return
    [ -z "${_import_file:-}" ] && { cancelled; PAUSE; return; }
    [ -f "$_import_file" ] || { warn "File not found: $_import_file"; PAUSE; return; }

    _ver="$(jq -r '.liminal_version // empty' "$_import_file" 2>/dev/null || true)"
    [ -z "$_ver" ] && { warn "Invalid export file (missing liminal_version)"; PAUSE; return; }

    _exported="$(jq -r '.exported // "unknown"' "$_import_file")"
    _icount="$(jq '.interfaces | length' "$_import_file")"
    _pcount="$(jq '[.interfaces[].peers | length] | add // 0' "$_import_file")"

    section "Summary"

    echo -e "  ${A}Export version${NC}  ${W}${_ver}${NC}"
    echo -e "  ${A}Exported at${NC}    ${W}${_exported}${NC}"
    echo -e "  ${A}Interfaces${NC}     ${W}${_icount}${NC}"
    echo -e "  ${A}Peers${NC}          ${W}${_pcount}${NC}"
    echo ""

    confirm "Import this configuration?" "n" || return

    autobackup_enabled && init_backup "Pre-Import"

    _idx=0
    while [ "$_idx" -lt "$_icount" ]; do
        _iobj="$(jq -c ".interfaces[$_idx]" "$_import_file")"
        _iname="$(printf '%s' "$_iobj" | jq -r '.name')"

        if uci_network_exists "$_iname"; then
            warn "Interface '$_iname' already exists — skipping"
            _idx=$((_idx + 1)); continue
        fi

        echo -e "  ${B}Creating${NC} interface ${W}${_iname}${NC}..."
        uci set "network.${_iname}=interface"
        iface_apply_json_fields "$_iname" "$_iobj"
        uci set "network.${_iname}._liminal_iface=${_iname}"

        _pt="amneziawg_${_iname}"
        _pcnt="$(printf '%s' "$_iobj" | jq '.peers | length')"
        _pidx=0
        while [ "$_pidx" -lt "$_pcnt" ]; do
            _pobj="$(printf '%s' "$_iobj" | jq -c ".peers[$_pidx]")"
            _pdesc="$(printf '%s' "$_pobj" | jq -r '.description // ""')"
            echo -e "    ${B}Adding${NC} peer ${W}${_pdesc}${NC}..."
            _sec="$(uci add network "$_pt")"
            peer_apply_json_fields "$_sec" "$_pobj"
            # Always set route_allowed_ips=1 (not in schema — it's a UCI default for liminal peers)
            uci set "network.${_sec}.route_allowed_ips=1"
            _pidx=$((_pidx + 1))
        done

        _idx=$((_idx + 1))
    done

    uci commit network

    echo -e "  ${B}Reloading${NC} network..."
    svc_reload network
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
        echo -e "${DIM2}──────────────────────────────────────${NC}"
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
                _addr="$(iface_get "$iface" addresses "n/a")"
                _port="$(iface_get "$iface" listen_port "n/a")"
                _disabled="$(iface_get "$iface" disabled "0")"

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
                while peer_exists "$_pt" "$_pi"; do
                    _pdesc="$(peer_get "$_pt" "$_pi" description "peer$((_pi+1))")"
                    _ppub="$(peer_get "$_pt" "$_pi" public_key)"
                    _paip="$(peer_get "$_pt" "$_pi" allowed_ips "?")"
                    _pdis="$(peer_get "$_pt" "$_pi" disabled "0")"

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
                        _hs_sec="$(awg_peer_handshake_age "$iface" "$_ppub")"
                        if [ "${_hs_sec:-9999}" -le "120" ] 2>/dev/null; then
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
    echo -e "${DIM2}──────────────────────────────────────${NC}"

    for iface in $_interfaces; do
        _disabled="$(iface_get "$iface" disabled "0")"
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
        _port="$(iface_get "$iface" listen_port)"
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
        while peer_exists "$_pt" "$_pi"; do
            _pdesc="$(peer_get "$_pt" "$_pi" description "peer$((_pi+1))")"
            _ppub="$(peer_get "$_pt" "$_pi" public_key)"
            _paip="$(peer_get "$_pt" "$_pi" allowed_ips)"
            _pdis="$(peer_get "$_pt" "$_pi" disabled "0")"
            _pip="${_paip%/*}"

            # Skip disabled and offline peers
            if [ "$_pdis" = "1" ]; then
                _pi=$((_pi + 1)); continue
            fi
            _is_online=0
            if [ -n "$_ppub" ]; then
                _hs_sec="$(awg_peer_handshake_age "$iface" "$_ppub")"
                [ "${_hs_sec:-9999}" -le "120" ] 2>/dev/null && _is_online=1
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
    echo -e "${DIM2}──────────────────────────────────────${NC}"
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
            _awg_ver="$(pkg_version amneziawg-tools 2>/dev/null)"
            _awg_s="${ICO_OK} ${OK}${_awg_ver:-ok}${NC}"
        else
            _awg_s="${ICO_ERR} ${DIM2}n/a${NC}"
        fi
        if podkop_present; then
            _pk_ver="$(pkg_version podkop 2>/dev/null)"
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
        echo -e "${DIM2}⠀⠀⠀⣇⢿⢿⢿⢿⣶⣕⣤⢿⢿⣇⣀⣀⣤⠒⠓⠋⠋⠀⢿⢿⢿⢿⡟${NC}"
        echo -e "${DIM2}⠀⠀⢠⣏⢿⢿⢿⠀⠀⠀⣼⢿⢿⡟⣾⢿⠟⠉⣦⠀⠀⠘⠋⠈⢿⢿⠃${NC}"
        echo -e "${DIM2}⠀⢀⢿⢿⠋⠉⠀⠀⡞⠉⠉⢻⣛⢋⣶⠏⠀⣰⠁⠀⠀⠀⠀⠀⢻⢿⣧${NC}"
        echo ""

        _has_awg=0; have_cmd awg && _has_awg=1
        _has_podkop=0; podkop_present && have_cmd podkop && _has_podkop=1
        _has_qr=0; have_cmd qrencode && _has_qr=1
        _has_jq=0; have_cmd jq && _has_jq=1
        _has_b64=0; have_cmd base64 && _has_b64=1

        _qr_s="${ICO_ERR}"; [ "$_has_qr"  -eq 1 ] && { _qr_v="$(pkg_version qrencode 2>/dev/null)"; _qr_s="${ICO_OK} ${DIM2}${_qr_v}${NC}"; }
        _jq_s="${ICO_ERR}"; [ "$_has_jq"  -eq 1 ] && { _jq_v="$(pkg_version jq 2>/dev/null)"; _jq_s="${ICO_OK} ${DIM2}${_jq_v}${NC}"; }
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
                _dis="$(iface_get "$iface" disabled "0")"
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
                _is_l="$(iface_get "$iface" _liminal_iface)"
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
                    if ! check_dns; then
                        warn "DNS is not working — cannot install packages"
                        PAUSE; continue
                    fi
                    if [ "$_has_awg" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} AmneziaWG..."
                        sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) 2>&1
                    fi
                    _need_opkg=0
                    if [ "$_has_qr" -eq 0 ] || [ "$_has_jq" -eq 0 ] || [ "$_has_b64" -eq 0 ]; then
                        _need_opkg=1
                        echo -e "  ${B}Updating${NC} package list..."
                        pkg_update >/dev/null 2>&1 || true
                    fi
                    if [ "$_has_podkop" -eq 0 ]; then
                        echo -e "  ${B}Installing${NC} Podkop..."
                        sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) 2>&1
                    fi
                    if [ "$_has_qr" -eq 0 ] && ! pkg_is_installed qrencode; then
                        echo -e "  ${B}Installing${NC} qrencode..."
                        pkg_install qrencode 2>/dev/null || true
                    fi
                    if [ "$_has_jq" -eq 0 ] && ! pkg_is_installed jq; then
                        echo -e "  ${B}Installing${NC} jq..."
                        pkg_install jq 2>/dev/null || true
                    fi
                    if [ "$_has_b64" -eq 0 ]; then
                        if [ "$PKG_IS_APK" -eq 1 ]; then
                            if ! pkg_is_installed coreutils; then
                                echo -e "  ${B}Installing${NC} base64..."
                                pkg_install coreutils 2>/dev/null || true
                            fi
                        else
                            if ! pkg_is_installed coreutils-base64; then
                                echo -e "  ${B}Installing${NC} base64..."
                                pkg_install coreutils-base64 2>/dev/null || true
                            fi
                        fi
                    fi
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"
                    PAUSE
                fi ;;
            a|A)
                if [ "$_has_awg" -eq 0 ]; then
                    confirm "Install AmneziaWG?" "y" || continue
                    if ! check_dns; then warn "DNS is not working"; PAUSE; continue; fi
                    echo -e "  ${B}Installing${NC} AmneziaWG..."
                    sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) 2>&1
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"
                    PAUSE
                fi ;;
            p|P)
                if [ "$_has_podkop" -eq 0 ]; then
                    confirm "Install Podkop?" "y" || continue
                    if ! check_dns; then warn "DNS is not working"; PAUSE; continue; fi
                    spinner_start "Installing Podkop..."
                    sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) 2>&1
                    spinner_stop
                    PAUSE
                fi ;;
            q|Q)
                if [ "$_has_qr" -eq 0 ]; then
                    if pkg_is_installed qrencode; then
                        echo -e "  ${DIM2}qrencode already installed (binary not in PATH)${NC}"; PAUSE; continue
                    fi
                    if ! check_dns; then warn "DNS is not working"; PAUSE; continue; fi
                    spinner_start "Installing qrencode..."
                    pkg_update >/dev/null 2>&1; pkg_install qrencode 2>/dev/null
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"; PAUSE
                fi ;;
            j|J)
                if [ "$_has_jq" -eq 0 ]; then
                    if pkg_is_installed jq; then
                        echo -e "  ${DIM2}jq already installed (binary not in PATH)${NC}"; PAUSE; continue
                    fi
                    if ! check_dns; then warn "DNS is not working"; PAUSE; continue; fi
                    spinner_start "Installing jq..."
                    pkg_update >/dev/null 2>&1; pkg_install jq 2>/dev/null
                    spinner_stop
                    echo -e "  ${ICO_OK} ${OK}Done${NC}"; PAUSE
                fi ;;
            x|X)
                if [ "$_has_b64" -eq 0 ]; then
                    if [ "$PKG_IS_APK" -eq 1 ] && pkg_is_installed coreutils; then
                        echo -e "  ${DIM2}coreutils already installed (binary not in PATH)${NC}"; PAUSE; continue
                    elif [ "$PKG_IS_APK" -eq 0 ] && pkg_is_installed coreutils-base64; then
                        echo -e "  ${DIM2}coreutils-base64 already installed (binary not in PATH)${NC}"; PAUSE; continue
                    fi
                    if ! check_dns; then warn "DNS is not working"; PAUSE; continue; fi
                    spinner_start "Installing coreutils-base64..."
                    pkg_update >/dev/null 2>&1
                    if [ "$PKG_IS_APK" -eq 1 ]; then
                        pkg_install coreutils 2>/dev/null
                    else
                        pkg_install coreutils-base64 2>/dev/null
                    fi
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

# ═══ Entry point ═════════════════════════════════════════════════════

ensure_required_tools
ensure_base_firewall
podkop_refresh
show_menu