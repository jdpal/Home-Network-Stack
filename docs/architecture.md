# Architecture

## Purpose

The project turns a Raspberry Pi 4B into a small home-network operations appliance. Core DNS and recovery services run natively on Raspberry Pi OS. Monitoring dashboards run in Docker.

The design keeps critical network functions independent from the dashboard layer.

## Components

```text
                         Home LAN
                            |
             +--------------+--------------+
             |                             |
        Router / DHCP                 Tailscale
             |                             |
             +-----------+-----------------+
                         |
                  Raspberry Pi 4B
                  192.168.0.10
                         |
          +--------------+----------------------+
          |              |                      |
       Pi-hole        OpenSSH              Discovery
       :53 / :80      + watchdog           + Device Manager
          |                                      :9108
          v
       Unbound
       127.0.0.1:5335
          |
          v
   Authoritative DNS

Docker
  |
  +-- Uptime Kuma :3001
  |
  +-- Homepage    :3000
```

## DNS

LAN clients receive the Pi-hole address from the router DHCP configuration.

Pi-hole forwards normal allowed queries to Unbound on `127.0.0.1:5335`.

The Pi operating system does not use Pi-hole as its own resolver. This is a deliberate recovery boundary.

### Failover

A systemd timer checks Unbound every minute.

1. Query Unbound.
2. If healthy, ensure Pi-hole is using Unbound.
3. If unhealthy, restart Unbound.
4. Test again.
5. If still unhealthy, switch Pi-hole upstreams to Cloudflare.
6. Continue checking.
7. Switch Pi-hole back to Unbound automatically when healthy.

## DHCP

The router is the sole DHCP server.

Pi-hole DHCP is disabled explicitly.

## SSH resilience

The installer:

- enables SSH at boot
- validates `sshd` configuration before relying on it
- configures service restart on failure
- runs a one-minute watchdog
- tests for an actual SSH protocol banner
- maintains a known-good SSH configuration backup
- exempts trusted LAN addresses from applicable ban/penalty mechanisms when those mechanisms are already present

Tailscale provides an independent remote-access route.

## Network discovery

Discovery is local to the Pi.

Sources can include:

- ARP/L2 discovery
- neighbor information
- MAC vendor information
- reverse DNS
- mDNS/DNS-SD
- selected service probes

Device type is never inferred from a hostname or user-visible device name.

### Persistent state

Discovery state is stored under:

```text
/var/lib/pi4-network-stack/
```

Manual values are retained when a later scan updates observed values.

Examples of persistent values:

- custom name
- manual device type
- manual dashboard group
- show/hide state
- linked Kuma monitor

## Local Pi record

ARP scanning cannot discover the host doing the scan. The Pi therefore creates a deterministic local-host record from its own operating-system state.

That record can be renamed or regrouped by the user, but later network scans do not erase its identity.

## Modem handling

The project does not infer a modem from routing topology, traceroute, hostname, or vendor.

A modem IP is shown only when a device is explicitly classified as `modem`.

## Uptime Kuma integration

Kuma remains responsible for monitor state, response time, and uptime history.

The Homepage integration reads the published Kuma status page and combines it with the local device inventory.

This separates:

```text
Kuma              Local inventory
----              ---------------
monitor status     device identity
latency            user name
uptime             device type
heartbeat          dashboard group
                   show/hide choice
```

## Dashboard

Homepage provides the main operations screen.

The local status API exposes read-only operational metrics and the Device Manager administrative page. Management POSTs are restricted by client network, browser origin/host/port matching, and JSON content type before any scan or device update is performed. Browser management uses the installer-printed loopback, LAN, or Tailscale IP URLs; arbitrary hostnames and cross-site origins fail closed.

Dashboard device cards use:

- explicit device icon
- independent status icon
- custom name if present
- numeric IPv4 ordering
- manually selected group when present
- automatic group only when no manual override exists

## Failure boundaries

A failure in Homepage or Uptime Kuma must not stop DNS.

A failure in Pi-hole or Unbound must not remove DNS resolution from the Pi host itself.

A failure in standard LAN SSH should still leave Tailscale as a recovery path when configured and connected.
