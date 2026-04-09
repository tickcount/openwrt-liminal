# Liminal

A menu-driven AmneziaWG tunnel manager for OpenWrt routers.

Create encrypted tunnels from your devices (phone, laptop, etc.) back to your home router, routing traffic through your LAN and out to the internet — all managed from an interactive SSH terminal UI.

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
- **Inline peer list** on interface page with direct numeric selection
- **Edit settings** — DNS, MTU, listen port, endpoint host override
- **Toggle LAN/WAN forwarding** directly from the interface menu
- **Podkop integration** — link/unlink with one toggle
- **Inline diagnostics** — warnings for down device, closed port, missing zone/forwarding
- **Interface info** — uptime, total traffic (Rx/Tx), public key, Podkop status
- **Disable / Enable / Delete** interfaces with full cleanup
- **Non-Liminal interface support** — manage interfaces created outside Liminal (read-only, no delete)

### Peer Management
- **Add peers** with automatic IP allocation and subnet validation
- **Routing mode presets** — Full tunnel, LAN only, WAN only, or custom AllowedIPs
- **PreSharedKey** generation for extra security
- **Live status** — Online/Offline detection via latest handshake (≤120s threshold)
- **Handshake color-coding** — green ≤30s, amber ≤120s, red >120s
- **Per-peer info** — endpoint, handshake time, Rx/Tx transfer, keepalive, public key
- **Edit per-peer settings** — AllowedIPs, Keepalive
- **Export configs** — WireGuard config, QR code, download link, `vpn://` AmneziaVPN key
- **Show All** — config + QR + vpn:// + download in one view
- **Rename / Regenerate keys / Disable / Enable / Delete** peers
- **Auto-navigate** to peer menu after creation

### Live Dashboard
- **Real-time monitoring** with auto-refresh (3s interval)
- **Per-peer table** — name, status, address, endpoint, handshake, Rx/Tx
- All interfaces and peers on a single screen

### Connectivity Check
- **Per-interface diagnostics** — device status, AWG, port, firewall zone, forwarding rules
- **Ping test** for online peers

### Export / Import
- **Export** full configuration to JSON (interfaces + peers + keys)
- **Import** from a previously exported JSON file
- Useful for migration between routers or disaster recovery

### Backup System
- **Automatic backups** before interface creation and deletion (toggleable)
- **Manual backups** on demand
- **Restore** from any backup with one click
- **Manage** — list, inspect (with size), delete individual or all backups
- Backups include `network`, `firewall`, and `podkop` configs

### Self-Update
- **Check for updates** from GitHub directly from the main menu
- Version comparison and one-click update with automatic restart

### Installer
- **Install All Missing** — one button to install everything at once
- Individual installers for AmneziaWG, Podkop, qrencode, jq, base64
- Dependency status shown on the main screen with version info

### UI
- **Box-drawing frames** and **status icons** (● ○ ✓ ✗ !) across all menus
- **Breadcrumb navigation** — always know where you are
- **Animated spinner** for long operations
- **Soft color palette** — white-blue-violet theme

### Safety
- `_is_liminal` flag on all created UCI objects — Liminal never touches configs it didn't create
- Input sanitization and name validation
- Subnet validation for generated peer IPs

## Requirements

- **OpenWrt 24.10+** (BusyBox ash)
- **AmneziaWG** — can be installed from the main menu

### Optional dependencies

| Package | Used for |
|---------|----------|
| `qrencode` | QR code generation |
| `jq` | AmneziaVPN `vpn://` key generation, export/import |
| `coreutils-base64` | Config encoding for download links and VPN keys |
| `podkop` | Split-tunnel routing integration |

All packages can be installed directly from the main menu (individually or all at once).

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
├── Interfaces (inline list with status)
│   ├── + ) Create Interface
│   └── 1..N ) Select interface
│       ├── Peers (inline list with status)
│       │   ├── + ) Add Peer
│       │   └── 1..N ) Select peer
│       │       ├── Config: Show Config / Download Link / vpn:// Key / QR Code / Show All
│       │       ├── Settings: AllowedIPs / Keepalive
│       │       └── Actions: Rename / Regenerate Keys / Disable|Enable / Delete
│       ├── Settings: DNS+MTU / Port / Endpoint / LAN Fwd / WAN Fwd / Podkop
│       ├── Info: Public Key
│       └── Interface: Restart / Disable|Enable / Delete
├── m ) Live Dashboard
├── e ) Export / Import
├── b ) Manage Backups
│   ├── c ) Create Backup
│   ├── t ) Toggle Auto-Backup
│   ├── d ) Delete All
│   └── 1..N ) Select backup → Restore / Delete
├── f ) Full Reset
├── u ) Check for Updates
└── Install missing packages (shown only when needed)
```

### Creating a tunnel

1. Run `liminal` and press `+` to **Create Interface**
2. Enter interface name, address (e.g. `10.10.10.1/24`), port
3. Router LAN IP and firewall zones are auto-detected
4. Review the planned config and confirm
5. Add peers — choose routing mode, generate PSK, get config + QR + `vpn://` key

### Connecting a client

Use any of the export options from the peer menu:
- **AmneziaVPN** (Android/iOS/Desktop) — scan QR or import `vpn://` key
- **WireGuard-compatible client** — import the `.conf` file or scan QR

## How it works

Liminal creates standard AmneziaWG interfaces via UCI with:
- A firewall zone with configurable LAN/WAN forwarding
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
