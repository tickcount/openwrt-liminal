# Liminal

AmneziaWG tunnel manager for OpenWrt routers. Runs over SSH as an interactive TUI.

Sets up encrypted VPN tunnels so your devices (phone, laptop, etc.) can route traffic through your home router — accessing your LAN and going out to the internet through your home IP.

![Shell Script](https://img.shields.io/badge/shell-ash%2Fbusybox-blue)
![Platform](https://img.shields.io/badge/platform-OpenWrt%2024.10-green)
![License](https://img.shields.io/badge/license-MIT-purple)

## Preview
<center>
<img width="525" height="542" alt="main" src="https://github.com/user-attachments/assets/9c816a9a-5785-43f2-be18-02b58da7ea5e" />
<img width="1090" height="674" alt="Untitled" src="https://github.com/user-attachments/assets/d624a352-d252-431d-9485-639ccb61034a" />
</center>

## What it does

Creates AmneziaWG interfaces and peers on OpenWrt, handling all the UCI/firewall/DNS plumbing.

### Interfaces

- Create with guided wizard — subnet auto-picked from free `10.x.0.1/24` range, firewall zone/rules/forwarding generated automatically
- LAN IP, LAN/WAN zones detected from UCI — manual input only when auto-detect fails
- Rename — propagates to peers, firewall zone, rules, forwardings, DNS records, Podkop
- Edit DNS, MTU, listen port, endpoint override from the interface menu
- Toggle LAN/WAN forwarding, link/unlink Podkop per interface
- Disable, enable, restart, delete with full cleanup
- Supports non-Liminal AWG interfaces (created outside the script) in read-only mode

### Peers

- Add with auto IP allocation from the interface subnet
- AllowedIPs set automatically based on firewall forwarding state (WAN present → `0.0.0.0/0`, LAN only → LAN CIDR, nothing → VPN subnet only)
- PreSharedKey generated for every peer
- Endpoint selection — interface override, WAN IP auto-detect, or manual
- Config export: WireGuard `.conf`, QR code, download link, `vpn://` key for AmneziaVPN
- Optional DNS hostrecord (`peer.interface.lan`) via dnsmasq — auto-name or custom
- Edit AllowedIPs, keepalive, hostname after creation
- Rename, regenerate keys, disable/enable, delete
- Online/offline status via handshake age, per-peer traffic stats

### Monitoring

- Live dashboard — all interfaces and peers on one screen, auto-refresh every 3s
- Connectivity check — device status, port listening, firewall zone, forwarding, ping to online peers
- Inline diagnostics on interface and peer screens — warns about down device, closed port, missing forwarding, DNS chain issues

### Podkop / Sing-Box

- Detect Sing-Box DNS (127.0.0.42:53) and dnsmasq forwarding chain
- Link/unlink interfaces to Podkop source list
- DNS chain status shown on interface and peer screens

### Backup & Export

- Auto-backup before create/delete/rename (toggleable)
- Manual backup, restore from any point, delete individual or all
- Export full config to JSON (interfaces + peers + keys), import on another router

### Other

- Self-update from GitHub with version check
- Install missing packages from the menu (AmneziaWG, Podkop, qrencode, jq, base64)
- CLI mode: `liminal status`, `liminal peers <iface>`, `liminal export`, `liminal check`

## Install

```bash
wget -O /usr/bin/liminal https://raw.githubusercontent.com/tickcount/openwrt-liminal/main/liminal.sh
chmod +x /usr/bin/liminal
liminal
```

Or run once without installing:

```bash
sh <(wget -O - https://raw.githubusercontent.com/tickcount/openwrt-liminal/main/liminal.sh)
```

## Requirements

- OpenWrt 24.10+ (BusyBox ash)
- AmneziaWG (installable from the menu)

Optional: `qrencode`, `jq`, `coreutils-base64`, `podkop` — all installable from the menu.

## Usage

1. Run `liminal`, press `+` to create an interface
2. Enter a name and port — subnet, firewall zone, LAN/WAN detected automatically
3. Add a peer — get QR / vpn:// key / config
4. Connect with AmneziaVPN or any WireGuard-compatible client

> Static public IP (or DDNS) and NAT port forwarding (UDP) on the upstream router are required for external access.

## How it works

All objects created by Liminal (firewall zones, rules, forwardings, DNS records) are tagged with `_liminal_iface` in UCI. This lets the script track what belongs to which interface and clean up safely on delete/rename without touching anything else.

## Credits

- **@immalware** — config download service ([Telegram](https://t.me/immalware))

## License

MIT
