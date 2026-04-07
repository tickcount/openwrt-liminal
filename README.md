# Liminal

A menu-driven AmneziaWG tunnel manager for OpenWrt routers.

Create encrypted tunnels from your devices (phone, laptop, etc.) back to your home router, routing traffic through your LAN and out to the internet — all managed from an interactive SSH terminal UI.

Universal proxy for all your devices through your home router — whether it's a phone on mobile data or another computer needing LAN/WAN access.

```
┌─────────────┐       ┌──────────────────┐       ┌─────────────────┐       ┌──────────────┐       ┌──────────┐
│   Client    │──────>│   Home Router    │──────>│   LAN / WAN     │──────>│   Podkop     │──────>│ Internet │
│             │  AWG  │   (OpenWrt +     │       │   Access        │       │  (optional)  │       │          │
│ Phone (LTE) │ tunnel│    Liminal)      │       │                 │       │              │       │          │
│ Laptop      │       │                  │       │ Local devices,  │       │ Split-tunnel  │       │          │
│ PC          │       │                  │       │ home network    │       │ routing       │       │          │
└─────────────┘       └──────────────────┘       └─────────────────┘       └──────────────┘       └──────────┘
```

| Step | Description |
|------|-------------|
| **Client** | Any device (phone, laptop, PC) connects via AmneziaWG tunnel |
| **Home Router** | OpenWrt router running Liminal — terminates the tunnel |
| **LAN / WAN Access** | Client gets full access to local network and internet through the router |
| **Podkop** (optional) | Split-tunnel routing — selectively route traffic through different paths |
| **Internet** | Final destination — traffic exits from your home IP |

![Shell Script](https://img.shields.io/badge/shell-ash%2Fbusybox-blue)
![Platform](https://img.shields.io/badge/platform-OpenWrt%2024.10-green)
![License](https://img.shields.io/badge/license-MIT-purple)

## Preview
<center>
  <img width="514" height="478" src="https://github.com/user-attachments/assets/d76785b3-b283-4f6c-948a-df3526283f35" />
  <img width="577" height="463" src="https://github.com/user-attachments/assets/7adbf9c5-35ed-45cc-928f-18bdc435e24f" />
</center>

## Features

### Interface Management
- **Create** AmneziaWG interfaces with automatic firewall zone, rules, and forwarding setup
- **Auto-detect** router LAN IP, WAN IP (endpoint), and firewall zones
- **Podkop integration** — optional Podkop-aware routing with one toggle
- **Disable / Enable / Delete** interfaces with full cleanup
- **Non-Liminal interface support** — manage interfaces created outside Liminal (read-only, no delete)

### Peer Management
- **Add peers** with automatic IP allocation from the interface subnet
- **Live status** — Online/Offline detection via latest handshake (≤120s threshold)
- **Per-peer info** — endpoint, handshake time, Rx/Tx transfer, keepalive, public key
- **Export configs** — WireGuard config, QR code, download link, `vpn://` AmneziaVPN key
- **Show All** — config + QR + vpn:// + download in one view
- **Rename / Regenerate keys / Disable / Enable / Delete** peers

### Backup System
- **Automatic backups** before interface creation and deletion (toggleable)
- **Manual backups** on demand
- **Restore** from any backup with one click
- **Manage** — list, inspect, delete individual or all backups
- Backups include `network`, `firewall`, and `podkop` configs

### Installer
- **One-click install** for AmneziaWG, Podkop, and dependencies (`qrencode`, `jq`, `base64`)
- Dependency status shown on the main screen

### Safety
- `_is_liminal` flag on all created UCI objects — Liminal never touches configs it didn't create

## Requirements

- **OpenWrt 24.10+** (BusyBox ash)
- **AmneziaWG** — can be installed from the main menu

### Optional dependencies

| Package | Used for |
|---------|----------|
| `qrencode` | QR code generation |
| `jq` | AmneziaVPN `vpn://` key generation |
| `coreutils-base64` | Config encoding for download links and VPN keys |
| `podkop` | Split-tunnel routing integration |

All packages above can be installed directly from the main menu.

## Installation

```bash
wget -O /usr/bin/liminal https://raw.githubusercontent.com/tickcount/openwrt-liminal/main/liminal.sh
chmod +x /usr/bin/liminal
liminal
```

Or run directly without installing:

```bash
sh <(wget -O - https://raw.githubusercontent.com/tickcount/openwrt-liminal/main/liminal.sh)
```

## Usage

```bash
liminal
```

### Navigation

```
Main Menu
├── 1) Create Interface
├── 2) Manage Interfaces
│   └── Select interface
│       ├── 1) Add Peer
│       ├── 2) List Peers
│       │   └── Select peer
│       │       ├── 1) Show Setup Config
│       │       ├── 2) Show Download Link
│       │       ├── 3) Show vpn:// Key
│       │       ├── 4) Show QR Code
│       │       ├── 5) Show All
│       │       ├── 6) Rename Peer
│       │       ├── 7) Regenerate Keys
│       │       ├── 8) Disable/Enable Peer
│       │       └── 9) Delete Peer
│       ├── 3) Restart Interface
│       ├── 4) Disable/Enable Interface
│       └── 5) Delete Interface
├── 3) Manage Backups
│   ├── c) Create Backup
│   ├── t) Toggle Auto-Backup
│   ├── d) Delete All
│   └── Select backup → Restore / Delete
├── 4) Full Reset
├── a) Install AmneziaWG
├── p) Install Podkop
├── q) Install qrencode
├── j) Install jq
└── b) Install coreutils-base64
```

### Creating a tunnel

1. Run `liminal` and select **Create Interface**
2. Enter interface name, address (e.g. `10.10.10.1/24`), port
3. Router LAN IP and firewall zones are auto-detected
4. Review the planned config and confirm
5. Add peers — each peer gets a config, QR code, and `vpn://` key

### Connecting a client

Use any of the export options from the peer menu:
- **AmneziaVPN** (Android/iOS/Desktop) — scan QR or import `vpn://` key
- **WireGuard-compatible client** — import the `.conf` file or scan QR

## How it works

Liminal creates standard AmneziaWG interfaces via UCI with:
- A firewall zone with LAN/WAN forwarding
- An incoming UDP rule for the listen port
- WAN masquerading for internet access
- Optional Podkop source interface registration

All objects are tagged with `_is_liminal=1` so Liminal can safely manage only what it created.

## Note

> A **static public IP address** (or DDNS hostname) and **NAT port forwarding** (UDP) on your upstream router are required for external clients to connect.

## Credits

- **@immalware** — config download service ([Telegram](https://t.me/immalware))

## License

MIT
