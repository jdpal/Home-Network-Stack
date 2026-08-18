# Device Manager

## URL

```text
http://192.168.0.10:9108/devices
```

The Device Manager controls how discovered LAN devices are presented. It does not use display names to guess device type.

## Data model

Each discovered record can contain two kinds of information.

### Observed

Updated by network scans:

- IP address
- MAC address
- discovered hostname
- vendor
- mDNS/DNS-SD services
- observed ports
- present/offline state
- automatic classification
- confidence and evidence

### Manual

Chosen by the user and retained across scans:

- custom name
- device type
- dashboard group
- show/hide choice
- linked Kuma monitor

Manual values take precedence.

## Custom names

The display-name precedence is:

```text
custom name
    |
discovered hostname
    |
vendor
    |
IP address
    |
MAC address
```

Clearing the custom name returns the device to automatic display-name fallback.

A custom name does not influence device classification.

## Numeric IP sorting

Devices are sorted by the numeric value of the IPv4 address.

Correct:

```text
192.168.0.2
192.168.0.10
192.168.0.100
```

Devices without a valid IPv4 address appear after devices with IPv4 addresses.

## Dashboard groups

Available presentation groups include:

- Infrastructure
- Storage & Servers
- Smart Home & IoT
- Cameras & Security
- Services
- Websites
- Other Devices
- Unclassified

A manual group choice overrides automatic grouping until reset.

## Device types

Examples include:

- `access-point`
- `router`
- `switch`
- `modem`
- `nas`
- `storage`
- `server`
- `raspberry-pi`
- `printer`
- `camera`
- `nvr`
- `dns`
- `service`
- `website`
- `smart-home`
- `iot`
- `other`

The UI is authoritative. The exact supported list is also available from:

```bash
sudo pi-network-discover types
```

## Local Raspberry Pi

The Pi itself appears as a deterministic local-host record.

It is not discovered through ARP because a host does not ARP-scan itself.

The local record:

- uses local OS facts
- may be renamed
- may be moved to another dashboard section
- remains identifiable as the local host on future scans

## Modem

The software does not guess which device is the modem.

To display a modem IP, explicitly set the correct discovered device type to:

```text
modem
```

The Network card can then display the address of that explicitly selected device.

## Kuma monitor linking

A discovered device can be linked to an existing Kuma monitor.

This lets the dashboard combine local identity and classification with Kuma health information.

Creating or deleting Kuma monitors is intentionally separate from LAN discovery.

## Scanning

Manual CLI scan:

```bash
sudo pi-network-discover scan
```

Other useful commands:

```bash
sudo pi-network-discover list
sudo pi-network-discover review
sudo pi-network-discover summary
sudo pi-network-discover types
```

The dashboard exposes a **Scan network** control directly above the device-status cards. It shows the age of the latest scan, disables itself while discovery is running, reports progress or failure, and refreshes the cards when the scan finishes.

The control uses the LAN/Tailscale-restricted management endpoint. Browser management requests must come from the same literal loopback, LAN, or Tailscale IP as the API host, use the configured dashboard or Device Manager port, and send JSON. Other browser origins and non-JSON POSTs are rejected before discovery starts.

Use the IP-based Dashboard and Device Manager URLs printed by the installer for scan and edit actions. Direct JSON clients may omit the browser `Origin` header, but must still be on loopback, the configured LAN, or Tailscale and send `Content-Type: application/json`.

A normal ten-second dashboard refresh reloads the latest stored result; it does not start another network scan.
