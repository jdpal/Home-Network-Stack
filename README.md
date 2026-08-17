# Pi 4 Home Network Stack

A reproducible Raspberry Pi 4B home-network appliance built around Pi-hole, Unbound, Tailscale, Uptime Kuma, Homepage, resilient SSH access, and automatic LAN discovery.

The current packaged release is **v3.8.1**.

> This project is tuned for a Raspberry Pi 4 Model B running Raspberry Pi OS Lite 64-bit. The reference system uses a Pi 4B with 2 GB RAM, wired Ethernet, and a 64 GB microSD card.

## What it installs

### Core network services

- **Pi-hole** for network-wide DNS filtering
- **Unbound** as a local recursive resolver with DNSSEC validation
- **Strict DNS failover** that temporarily moves Pi-hole to Cloudflare if Unbound remains unhealthy after restart
- **Router-managed DHCP**. Pi-hole DHCP is explicitly disabled
- **Independent host DNS** for the Pi itself, so repair operations do not depend on Pi-hole

### Remote access and resilience

- **OpenSSH** enabled at boot
- **SSH watchdog** that checks service health and an actual SSH banner every minute
- **Tailscale** for remote access, Tailscale SSH, and LAN subnet routing
- Static Ethernet address staged without deliberately dropping the active SSH session

### Monitoring and dashboard

- **Uptime Kuma v2** on port `3001`
- **Homepage** operations dashboard on port `3000`
- **Local telemetry API / Device Manager** on port `9108`
- Automatic LAN discovery with conservative evidence-based classification
- Persistent manual device grouping and custom names
- Numeric IPv4 sorting
- Explicit local Raspberry Pi record
- Optional explicit modem classification and modem-IP display

## Default URLs

| Service | URL |
|---|---|
| Homepage dashboard | `http://192.168.0.10:3000/` |
| Device Manager | `http://192.168.0.10:9108/devices` |
| Uptime Kuma | `http://192.168.0.10:3001/` |
| Pi-hole admin | `http://192.168.0.10/admin/` |
| Kuma status page expected by dashboard | `http://192.168.0.10:3001/status/home-network` |

The defaults can be changed through environment variables documented below.

## Network model

```text
LAN clients
    |
    | DNS supplied by router DHCP
    v
Pi-hole 192.168.0.10:53
    |
    v
Unbound 127.0.0.1:5335
    |
    v
Authoritative Internet DNS
```

If Unbound fails:

```text
Unbound health check fails
    |
    v
Restart Unbound
    |
    +-- healthy --> continue using Unbound
    |
    +-- unhealthy --> temporarily set Pi-hole upstreams to
                      1.1.1.1 and 1.0.0.1
                           |
                           v
                 keep testing Unbound
                           |
                           v
                 return automatically
                 when Unbound recovers
```

The Raspberry Pi host itself deliberately uses independent resolvers by default:

```text
1.1.1.1
9.9.9.9
```

This means the Pi can still resolve package repositories and recovery services if Pi-hole or Unbound is unavailable.

## Device discovery philosophy

The scanner may classify devices only from **observed network evidence**. It does not classify a device from its hostname or display name.

Examples of usable evidence include:

- the active default gateway
- MAC vendor information
- selected open ports
- mDNS/DNS-SD service advertisements
- specific network-service combinations

Automatic classification is conservative. Manual choices in Device Manager are authoritative and persist across future scans.

A user-defined device name also persists across scans.

### Dashboard sections

Devices can be presented in:

- Infrastructure
- Storage & Servers
- Smart Home & IoT
- Cameras & Security
- Services
- Websites
- Other Devices
- Unclassified

The local Raspberry Pi is represented explicitly instead of relying on ARP discovery.

A modem is **not inferred** from topology. If you classify a device explicitly as `modem`, its address can be shown as the modem IP.

## Requirements

- Raspberry Pi 4 Model B recommended
- 64-bit ARM operating system
- Raspberry Pi OS Lite recommended
- Wired Ethernet recommended
- Internet access during initial installation
- `sudo` access
- An address such as `192.168.0.10` reserved for the Pi or excluded from the router DHCP pool
- Router remains the DHCP server

The installer validates `arm64` and warns when it is not running on a Raspberry Pi 4 Model B.

## Quick start

### 1. Copy the installer

```bash
scp install.sh USER@CURRENT_PI_IP:~/
ssh USER@CURRENT_PI_IP
chmod +x ~/install.sh
```

Replace the username and current Pi address as required.

### 2. Run phase 1

```bash
sudo ~/install.sh
```

When the Pi is not yet using the target static address, the installer:

1. verifies the platform and current network
2. establishes independent host DNS
3. installs base prerequisites
4. configures SSH resilience
5. configures scheduled maintenance
6. adds the target address temporarily
7. stages the NetworkManager static profile
8. stops and asks you to test the new address

**Keep the original SSH session open.**

From a second terminal:

```bash
ssh USER@192.168.0.10
```

Only after that succeeds:

```bash
sudo reboot
```

### 3. Run phase 2

Reconnect:

```bash
ssh USER@192.168.0.10
sudo ~/install.sh
```

Phase 2 installs and configures the application stack.

For the full procedure, see [docs/installation.md](docs/installation.md).

## Uptime Kuma status page

The dashboard integration expects a published Kuma status page with the default slug:

```text
home-network
```

The dashboard obtains monitor state and heartbeat data from the published status-page endpoints. Uptime Kuma remains the monitoring engine.

The Device Manager stores presentation metadata separately, including custom names and dashboard classification.

## Device Manager

Open:

```text
http://192.168.0.10:9108/devices
```

The Device Manager provides:

- discovered IP and MAC address
- hostname
- vendor
- observed ports/services
- automatic classification and confidence
- editable custom device name
- device-type selection
- dashboard-section selection
- Kuma-monitor association
- show/hide control
- reset-to-auto classification

Manual overrides survive later network scans.

Devices are sorted by IPv4 **numerically**, not lexically.

See [docs/device-manager.md](docs/device-manager.md).

## Automatic discovery

A scheduled discovery scan runs daily. You can also scan from the command line:

```bash
sudo pi-network-discover scan
```

Useful commands:

```bash
sudo pi-network-discover list
sudo pi-network-discover review
sudo pi-network-discover summary
sudo pi-network-discover types
```

The web dashboard and Device Manager expose the discovery state without requiring you to work directly with the state JSON.

## Common configuration overrides

Run the installer with environment overrides when your LAN differs from the defaults:

```bash
sudo \
  TARGET_IP=192.168.1.10 \
  LAN_CIDR=192.168.1.0/24 \
  HOST_DNS_1=1.1.1.1 \
  HOST_DNS_2=9.9.9.9 \
  KUMA_STATUS_SLUG=home-network \
  ./install.sh
```

Important defaults:

| Variable | Default |
|---|---|
| `TARGET_IP` | `192.168.0.10` |
| `PREFIX` | `24` |
| `LAN_CIDR` | `192.168.0.0/24` |
| `HOST_DNS_1` | `1.1.1.1` |
| `HOST_DNS_2` | `9.9.9.9` |
| `FALLBACK_DNS_1` | `1.1.1.1` |
| `FALLBACK_DNS_2` | `1.0.0.1` |
| `UNBOUND_PORT` | `5335` |
| `DASHBOARD_PORT` | `3000` |
| `UPTIME_KUMA_PORT` | `3001` |
| `STATUS_API_PORT` | `9108` |
| `KUMA_STATUS_SLUG` | `home-network` |

## Maintenance

The stack configures:

- SSH health check every minute
- Unbound/failover health check every minute
- reboot on alternate days at 03:00
- stale `/tmp` cleanup daily at 04:15
- bounded system-journal storage

See [docs/operations.md](docs/operations.md) for checks and recovery commands.

## Upgrading an existing installation

The repository keeps release-specific targeted upgrades under [`upgrades/`](upgrades/).

For v3.8.1:

```bash
scp upgrades/upgrade-v3.8.1.sh USER@192.168.0.10:~/
ssh USER@192.168.0.10
chmod +x ~/upgrade-v3.8.1.sh
sudo ~/upgrade-v3.8.1.sh
```

Targeted upgrades are intended to avoid reinstalling or disturbing healthy core services when only the dashboard/discovery layer needs changing.

## Security notes

- Do **not** expose ports `22`, `53`, `80`, `3000`, `3001`, or `9108` directly to the public Internet.
- Use Tailscale for remote administration.
- Reserve the static Pi address at the router or exclude it from the DHCP pool.
- Keep the Pi operating system on independent DNS resolvers for recoverability.
- The published Kuma status page exposes the monitors you choose to publish. Treat it as LAN/Tailscale-visible operational data.
- The Device Manager is an administrative interface. Keep port `9108` restricted to trusted networks.

## Repository structure

```text
.
├── README.md
├── CHANGELOG.md
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── .gitignore
├── install.sh
├── upgrades/
│   └── upgrade-v3.8.1.sh
├── docs/
│   ├── architecture.md
│   ├── installation.md
│   ├── device-manager.md
│   ├── operations.md
│   └── troubleshooting.md
└── .github/
    └── workflows/
        └── shellcheck.yml
```

## Validation

The GitHub workflow runs:

- `bash -n` against installer and upgrade scripts
- ShellCheck at error severity

The release package also verifies that the GitHub copies of the installer and upgrade script are byte-for-byte identical to the packaged v3.8.1 sources.

## Publishing to GitHub

Create an empty repository on GitHub, then from this folder:

```bash
git init
git add .
git commit -m "Initial release v3.8.1"
git branch -M main
git remote add origin git@github.com:YOUR-USER/YOUR-REPOSITORY.git
git push -u origin main
```

## Licensing

The original code and documentation in this repository are licensed under the
**Apache License 2.0**. See [`LICENSE`](LICENSE).

This project installs, configures, or integrates with third-party software.
Those projects are **not relicensed** under Apache-2.0 and remain subject to
their respective upstream licences.

Major examples include Pi-hole (EUPL-1.2), Unbound (BSD-3-Clause), Uptime Kuma
(MIT), the open-source Tailscale client/daemon (BSD-3-Clause), Homepage
(GPL-3.0), and Docker/Moby components (Apache-2.0).

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for details.

Project and product names are used descriptively. No affiliation, sponsorship,
or endorsement by the referenced third-party projects is implied.
