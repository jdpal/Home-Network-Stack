# Troubleshooting

## SSH: connection reset before authentication

Symptoms:

```text
kex_exchange_identification: read: Connection reset by peer
Connection reset by ... port 22
```

If TCP/22 accepts the connection but the remote SSH banner is never received, investigate the server side rather than deleting client keys.

Check:

```bash
sudo systemctl status ssh --no-pager
sudo sshd -t
sudo journalctl -u ssh -n 100 --no-pager
sudo systemctl status ssh-watchdog.timer --no-pager
```

Tailscale is the preferred independent recovery path.

## DNS resolution fails on the Pi

Test raw connectivity:

```bash
ping -c 3 1.1.1.1
```

Then DNS:

```bash
getent hosts deb.debian.org
```

Inspect NetworkManager DNS:

```bash
nmcli device show eth0 | grep -E 'IP4.DNS|IP4.GATEWAY|IP4.ADDRESS'
```

The Pi host should normally use its independent DNS configuration rather than depend on Pi-hole.

## Pi-hole works but LAN clients do not use it

Check the router DHCP DNS setting.

It should hand clients:

```text
192.168.0.10
```

Pi-hole DHCP should remain disabled unless you intentionally redesign the network.

Renew the client DHCP lease after changing router DNS.

## Unbound fails

```bash
sudo unbound-checkconf
sudo systemctl status unbound --no-pager
dig @127.0.0.1 -p 5335 example.com
```

The failover watchdog may temporarily move Pi-hole to Cloudflare while Unbound is unhealthy.

Check:

```bash
sudo journalctl -u unbound-failover.service -n 100 --no-pager
```

## Uptime Kuma container conflict

Inspect the existing container before deleting anything:

```bash
sudo docker ps -a --filter name='^/uptime-kuma$'
sudo docker inspect uptime-kuma --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

The project is designed to preserve an existing Kuma instance rather than destroy its database.

## Uptime Kuma embedded-MariaDB password reset lock

With embedded MariaDB, starting the reset utility inside the already-running Kuma container can contend for the same MariaDB data files.

A safe pattern is:

1. stop the normal Kuma container
2. back up `/opt/uptime-kuma/data`
3. run the reset utility in a temporary container using that data mount
4. restart the normal Kuma container

Do not run two embedded MariaDB processes against the same data directory.

## Dashboard does not show Kuma monitors

Check the configured Kuma status-page slug.

Default:

```text
home-network
```

Open:

```text
http://192.168.0.10:3001/status/home-network
```

Check the status API:

```bash
curl -s http://127.0.0.1:9108/public/kuma/config
```

Hard-refresh the browser after changing Homepage assets.

## Device appears in the wrong group

Open Device Manager:

```text
http://192.168.0.10:9108/devices
```

Manual choices override automatic grouping.

Reset to Auto only when you want network evidence to control classification again.

The software does not use the device name to infer type.

## Pi missing from discovery

v3.8.1 explicitly creates the Raspberry Pi as a local-host record.

If it is missing after upgrading, run:

```bash
sudo pi-network-discover scan
sudo pi-network-discover list
```

Then inspect:

```bash
sudo systemctl status pi-network-status-api --no-pager
```

## Modem IP says Not set

This is expected until a discovered device has explicitly been classified as:

```text
modem
```

The software intentionally does not infer the modem.

## Port 9108 is unavailable

```bash
sudo systemctl status pi-network-status-api --no-pager -l
sudo journalctl -u pi-network-status-api -n 100 --no-pager
sudo ss -lntp | grep ':9108'
```

## Package installation is very slow

Older Raspberry Pi models can spend substantial time processing APT package indexes.

On a Pi 4, also check:

```bash
free -h
df -h /
uptime
sudo dmesg -T | grep -Ei 'mmc|I/O|error|under-voltage|oom|killed'
```
