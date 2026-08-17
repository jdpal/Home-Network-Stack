# Installation

## Before you start

You need:

- Raspberry Pi 4 Model B recommended
- Raspberry Pi OS Lite 64-bit
- wired Ethernet
- `sudo` access
- a target static address reserved or excluded from the router DHCP pool
- a second terminal available for the static-IP transition

The default target address is:

```text
192.168.0.10/24
```

The default gateway is detected from the active Ethernet connection.

## Copy the installer

From your workstation:

```bash
scp install.sh USER@CURRENT-PI-IP:~/
ssh USER@CURRENT-PI-IP
chmod +x ~/install.sh
```

## Phase 1: safe address staging

Run:

```bash
sudo ~/install.sh
```

If the Pi is not yet using `TARGET_IP` as its primary address, the installer stages the target address without deliberately taking the Ethernet interface down.

The installer will stop after phase 1.

Keep the original SSH session open and connect from a second terminal:

```bash
ssh USER@192.168.0.10
```

Verify the new session works.

Make sure the router reserves or excludes `192.168.0.10`.

Then reboot:

```bash
sudo reboot
```

## Phase 2: application stack

Reconnect:

```bash
ssh USER@192.168.0.10
```

Run the same installer again:

```bash
sudo ~/install.sh
```

Phase 2 validates the permanent network configuration and proceeds through:

1. Tailscale
2. Unbound
3. Pi-hole
4. Unbound/Cloudflare failover watchdog
5. Docker
6. telemetry/status API
7. automatic network discovery
8. Uptime Kuma
9. Homepage

## Pi-hole

When the Pi-hole installer asks about a static address, continue because NetworkManager has already been configured.

Pi-hole DHCP is disabled by the automation.

Do not configure the router to use the Pi as LAN DNS until the installer has completed and this succeeds:

```bash
dig @192.168.0.10 example.com
```

Then set the router's DHCP/LAN DNS address to:

```text
192.168.0.10
```

Do not configure a public resolver as a secondary DNS on normal LAN clients if the goal is to force normal DNS through Pi-hole.

## Uptime Kuma

Open:

```text
http://192.168.0.10:3001/
```

Create or use the existing admin account.

The Homepage integration expects a published status page with slug:

```text
home-network
```

Add the monitors that should be visible on the dashboard to that status page.

## Tailscale

The installer enables Tailscale and advertises the configured LAN subnet.

Approve the subnet route in the Tailscale admin console if your tailnet policy does not auto-approve it.

Do not expose SSH or dashboard ports through router port forwarding.

## Custom network values

Example:

```bash
sudo \
  TARGET_IP=10.0.0.10 \
  PREFIX=24 \
  LAN_CIDR=10.0.0.0/24 \
  HOST_DNS_1=1.1.1.1 \
  HOST_DNS_2=9.9.9.9 \
  ./install.sh
```

Run the same overrides on both phases.

## After installation

Check:

```bash
sudo systemctl is-active ssh
sudo systemctl is-active unbound
sudo systemctl is-active pihole-FTL
sudo systemctl is-active docker
sudo systemctl is-active pi-network-status-api
```

Check Docker:

```bash
sudo docker ps
```

Check DNS:

```bash
dig @192.168.0.10 example.com
dig @127.0.0.1 -p 5335 example.com
```

Open:

```text
http://192.168.0.10:3000/
http://192.168.0.10:3001/
http://192.168.0.10:9108/devices
```
