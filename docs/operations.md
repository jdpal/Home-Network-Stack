# Operations

## Service checks

```bash
sudo systemctl status ssh --no-pager
sudo systemctl status ssh-watchdog.timer --no-pager
sudo systemctl status unbound --no-pager
sudo systemctl status unbound-failover.timer --no-pager
sudo systemctl status pihole-FTL --no-pager
sudo systemctl status tailscaled --no-pager
sudo systemctl status docker --no-pager
sudo systemctl status pi-network-status-api --no-pager
```

## DNS checks

Pi-hole:

```bash
dig @192.168.0.10 example.com
```

Unbound directly:

```bash
dig @127.0.0.1 -p 5335 example.com
```

DNSSEC validation can also be checked with the Unbound queries configured by the installer.

## Docker

```bash
sudo docker ps
sudo docker logs --tail 100 uptime-kuma
sudo docker logs --tail 100 homepage
```

Existing Uptime Kuma data is normally mounted persistently and must not be deleted casually.

## Discovery

Run a scan:

```bash
sudo pi-network-discover scan
```

List devices:

```bash
sudo pi-network-discover list
```

Summary:

```bash
sudo pi-network-discover summary
```

Device Manager:

```text
http://192.168.0.10:9108/devices
```

## Tailscale

```bash
tailscale status
tailscale ip -4
```

The subnet route must be approved according to the tailnet configuration.

## Logs

SSH:

```bash
sudo journalctl -u ssh -n 100 --no-pager
sudo journalctl -u ssh-watchdog.service -n 100 --no-pager
```

Unbound:

```bash
sudo journalctl -u unbound -n 100 --no-pager
sudo journalctl -u unbound-failover.service -n 100 --no-pager
```

Status API:

```bash
sudo journalctl -u pi-network-status-api -n 100 --no-pager
```

## Scheduled maintenance

The installer configures:

- SSH watchdog every minute
- Unbound health/failover check every minute
- alternate-day reboot at 03:00
- `/tmp` cleanup at 04:15
- journal limits

Inspect timers:

```bash
systemctl list-timers --all
```

Inspect maintenance cron:

```bash
cat /etc/cron.d/pi4-network-maintenance
```

## Backups before manual changes

Before changing SSH:

```bash
sudo sshd -t
```

Keep an existing SSH session open while testing a new one.

Before manually changing NetworkManager, Pi-hole, Unbound, or Kuma persistence, take a configuration/data backup appropriate to the service.

## Router

The router remains the DHCP authority.

Once Pi-hole is healthy, router DHCP should hand LAN clients the Pi address as DNS.

Avoid advertising a public resolver as an alternative DNS server to ordinary clients when you want Pi-hole filtering to be consistently used.
