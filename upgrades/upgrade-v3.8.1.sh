#!/usr/bin/env bash
# v3.8.1 targeted upgrade: include local Pi + explicit modem IP support
set -Eeuo pipefail
IFS=$'\n\t'
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
STATE_DIR=/var/lib/pi4-network-stack
HOMEPAGE_DIR=/opt/home-network/homepage
DEFAULTS=/etc/default/pi-network-status-api
[[ -f "$DEFAULTS" ]] || { echo "Missing $DEFAULTS; install v3.6+ first." >&2; exit 1; }
[[ -f /usr/local/lib/pi-network-status/kuma_normalizer.py ]] || { echo "Missing Kuma normalizer; install v3.6+ first." >&2; exit 1; }
mkdir -p "$STATE_DIR" /usr/local/lib/pi-network-status /usr/local/share/pi-network-manager "$HOMEPAGE_DIR/config"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/pi-network-v37-backup-$STAMP
mkdir -p "$BACKUP"
for f in /usr/local/sbin/pi-network-discover /usr/local/sbin/pi-network-status-api.py /usr/local/lib/pi-network-status/device_manager.py /usr/local/share/pi-network-manager/devices.html "$HOMEPAGE_DIR/config/custom.js" "$HOMEPAGE_DIR/config/custom.css" /etc/systemd/system/pi-network-status-api.service; do
  [[ -e "$f" ]] && cp -a "$f" "$BACKUP/$(echo "$f" | tr '/' '_')"
done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y arp-scan avahi-utils nmap python3
DEST=/usr/local/sbin/pi-network-discover
cat >"$DEST" <<'V37_DISCOVER'
#!/usr/bin/env python3
"""Automatic, conservative LAN discovery for the Pi home-network dashboard.

Discovery never creates or changes Uptime Kuma monitors. Automatic suggestions are
based only on observed network evidence. Persistent manual overrides remain
authoritative and are never overwritten by later scans.
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

STATE_FILE = Path(os.environ.get("DISCOVERY_STATE_FILE", "/var/lib/pi4-network-stack/network-discovery.json"))
DEFAULTS_FILE = Path("/etc/default/pi-network-status-api")
INVENTORY_CMD = Path("/usr/local/sbin/pi-device-inventory")

GROUPS = {
    "infrastructure": "Infrastructure",
    "storage": "Storage & Servers",
    "smart-home": "Smart Home & IoT",
    "security": "Cameras & Security",
    "services": "Services",
    "websites": "Websites",
    "other": "Other Devices",
    "unclassified": "Unclassified",
}

TYPE_TO_GROUP = {
    "access-point": "infrastructure",
    "router": "infrastructure",
    "switch": "infrastructure",
    "network-device": "infrastructure",
    "modem": "infrastructure",
    "nas": "storage",
    "storage": "storage",
    "server": "storage",
    "raspberry-pi": "infrastructure",
    "smart-home": "smart-home",
    "iot": "smart-home",
    "sensor": "smart-home",
    "bridge": "smart-home",
    "tv": "smart-home",
    "speaker": "smart-home",
    "camera": "security",
    "nvr": "security",
    "security": "security",
    "dns": "services",
    "service": "services",
    "website": "websites",
    "printer": "other",
    "other": "other",
}

SCAN_PORTS = [22, 53, 80, 443, 445, 548, 554, 631, 1883, 3000, 3001, 5000, 5001, 8000, 8080, 8123, 8443, 8883, 8899, 9100, 32400]
NETWORK_VENDOR_HINTS = (
    "ubiquiti", "cisco", "aruba", "mikrotik", "juniper", "ruckus",
    "netgear", "tp-link", "tplink", "zyxel", "extreme networks",
)
STORAGE_VENDOR_HINTS = ("synology", "qnap", "asustor", "western digital", "wdc")
PRINTER_MDNS = {"_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"}
STORAGE_MDNS = {"_adisk._tcp", "_afpovertcp._tcp"}
CAMERA_MDNS = {"_onvif._tcp"}
SMART_MDNS = {
    "_hap._tcp", "_home-assistant._tcp", "_googlecast._tcp", "_spotify-connect._tcp",
    "_sonos._tcp", "_matter._tcp", "_matterc._udp", "_hue._tcp",
}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def read_defaults() -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for raw in DEFAULTS_FILE.read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            key, value = raw.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return values


def default_state() -> dict:
    return {"version": 1, "last_scan": None, "last_interface": None, "last_network": None, "devices": {}}


def load_state() -> dict:
    try:
        data = json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        data = default_state()
    if not isinstance(data, dict):
        data = default_state()
    data.setdefault("version", 1)
    data.setdefault("devices", {})
    return data


def save_state(data: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(STATE_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE_FILE)


def run(cmd: list[str], timeout: int = 30, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=check)


def detect_interface_network() -> tuple[str, str, str, str]:
    defaults = read_defaults()
    target_ip = defaults.get("TARGET_IP", "")
    gateway = defaults.get("GATEWAY", "")

    route = run(["ip", "-4", "route", "show", "default"], timeout=5).stdout.splitlines()
    interface = ""
    if route:
        parts = route[0].split()
        if "dev" in parts:
            interface = parts[parts.index("dev") + 1]
        if not gateway and "via" in parts:
            gateway = parts[parts.index("via") + 1]
    if not interface:
        raise SystemExit("Could not determine the active IPv4 interface.")

    addr_lines = run(["ip", "-4", "-o", "addr", "show", "dev", interface, "scope", "global"], timeout=5).stdout.splitlines()
    if not addr_lines:
        raise SystemExit(f"No IPv4 address found on {interface}.")
    cidr = addr_lines[0].split()[3]
    iface = ipaddress.ip_interface(cidr)
    network = str(iface.network)
    own_ip = target_ip or str(iface.ip)
    return interface, network, gateway, own_ip


def normalize_mac(value: str) -> str | None:
    value = value.lower().strip()
    if re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", value):
        return value
    return None


def local_host_record(interface: str, own_ip: str, stamp: str) -> dict:
    """Build a deterministic record for the Raspberry Pi running the scanner."""
    try:
        mac = normalize_mac(Path(f"/sys/class/net/{interface}/address").read_text().strip()) or ""
    except Exception:
        mac = ""
    try:
        model = Path("/proc/device-tree/model").read_bytes().replace(b"\x00", b"").decode(errors="replace").strip()
    except Exception:
        model = "Raspberry Pi"
    return {
        "ip": own_ip,
        "mac": mac,
        "vendor": "Raspberry Pi",
        "hostname": socket.gethostname(),
        "model": model,
        "mdns": [],
        "open_ports": [],
        "suggested_type": "raspberry-pi",
        "suggested_group": "infrastructure",
        "confidence": 1.0,
        "evidence": [f"Local host running on {interface}: {model}"],
        "last_seen": stamp,
        "present": True,
        "local_host": True,
    }


def modem_ip_from_state(state: dict) -> str:
    """Return an explicitly classified modem IPv4 address; never infer one."""
    candidates = []
    for record in (state.get("devices") or {}).values():
        if not isinstance(record, dict):
            continue
        dtype = record.get("manual_type") or record.get("approved_type")
        if not dtype and float(record.get("confidence") or 0.0) >= 0.85:
            dtype = record.get("suggested_type")
        if dtype != "modem":
            continue
        ip = str(record.get("ip") or "").strip()
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if addr.version == 4:
            candidates.append((0 if record.get("present") else 1, int(addr), ip))
    return sorted(candidates)[0][2] if candidates else ""


def arp_discover(interface: str) -> dict[str, dict]:
    if shutil.which("arp-scan") is None:
        raise SystemExit("arp-scan is not installed.")
    proc = run(["arp-scan", "--interface", interface, "--localnet", "--plain", "--ignoredups"], timeout=90)
    if proc.returncode not in (0, 1):
        raise SystemExit(f"arp-scan failed: {proc.stderr.strip()}")
    found: dict[str, dict] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            parts = re.split(r"\s+", line.strip(), maxsplit=2)
        if len(parts) < 2:
            continue
        ip = parts[0].strip()
        mac = normalize_mac(parts[1])
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            continue
        if not mac:
            continue
        vendor = parts[2].strip() if len(parts) >= 3 else ""
        found[ip] = {"ip": ip, "mac": mac, "vendor": vendor}
    return found


def neighbor_fallback(interface: str) -> dict[str, dict]:
    found: dict[str, dict] = {}
    proc = run(["ip", "neigh", "show", "dev", interface], timeout=5)
    for line in proc.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        ip = parts[0]
        mac = None
        if "lladdr" in parts:
            idx = parts.index("lladdr")
            if idx + 1 < len(parts):
                mac = normalize_mac(parts[idx + 1])
        if mac:
            found[ip] = {"ip": ip, "mac": mac, "vendor": ""}
    return found


def reverse_hostname(ip: str) -> str:
    try:
        proc = run(["getent", "hosts", ip], timeout=2)
        if proc.returncode == 0 and proc.stdout.strip():
            parts = proc.stdout.split()
            if len(parts) >= 2:
                return parts[1].rstrip(".")
    except Exception:
        pass
    return ""


def avahi_services() -> dict[str, list[dict]]:
    result: dict[str, list[dict]] = {}
    if shutil.which("avahi-browse") is None:
        return result
    try:
        proc = run(["avahi-browse", "-artp", "--terminate"], timeout=20)
    except Exception:
        return result
    for line in proc.stdout.splitlines():
        if not line.startswith("="):
            continue
        fields = line.split(";")
        # =;iface;proto;name;type;domain;host;address;port;txt
        if len(fields) < 9:
            continue
        address = fields[7].strip()
        service_type = fields[4].strip()
        name = fields[3].replace("\\032", " ").strip()
        host = fields[6].replace("\\032", " ").rstrip(".").strip()
        try:
            port = int(fields[8])
        except ValueError:
            port = 0
        try:
            ipaddress.ip_address(address)
        except ValueError:
            continue
        result.setdefault(address, []).append({"type": service_type, "name": name, "host": host, "port": port})
    return result


def nmap_ports(ips: list[str]) -> dict[str, list[int]]:
    result: dict[str, list[int]] = {ip: [] for ip in ips}
    if not ips or shutil.which("nmap") is None:
        return result
    cmd = [
        "nmap", "-Pn", "-n", "-T4", "--max-retries", "1", "--host-timeout", "8s",
        "-p", ",".join(str(x) for x in SCAN_PORTS), "-oX", "-",
    ] + ips
    try:
        proc = run(cmd, timeout=max(60, min(240, 10 * len(ips))))
        root = ET.fromstring(proc.stdout)
    except Exception:
        return result
    for host in root.findall("host"):
        addr = host.find("address[@addrtype='ipv4']")
        if addr is None:
            continue
        ip = addr.attrib.get("addr", "")
        ports = []
        for port in host.findall("./ports/port"):
            state = port.find("state")
            if state is not None and state.attrib.get("state") == "open":
                try:
                    ports.append(int(port.attrib["portid"]))
                except Exception:
                    pass
        result[ip] = sorted(ports)
    return result


def classify(device: dict, gateway: str) -> tuple[str | None, str | None, float, list[str]]:
    ip = device.get("ip", "")
    vendor = device.get("vendor", "").lower()
    ports = set(device.get("open_ports") or [])
    mdns = {x.get("type", "") for x in device.get("mdns") or []}

    if gateway and ip == gateway:
        return "router", "infrastructure", 1.0, ["IP is the active default gateway"]

    printer_matches = sorted(mdns & PRINTER_MDNS)
    if printer_matches:
        return "printer", "other", 0.99, [f"mDNS advertises {printer_matches[0]}"]
    if 631 in ports and 9100 in ports:
        return "printer", "other", 0.96, ["IPP (631) and JetDirect (9100) are both open"]

    camera_matches = sorted(mdns & CAMERA_MDNS)
    if camera_matches:
        return "camera", "security", 0.99, [f"mDNS advertises {camera_matches[0]}"]
    if 554 in ports and ({8000, 8899} & ports):
        return "camera", "security", 0.94, ["RTSP plus a common camera-management port are open"]

    storage_matches = sorted(mdns & STORAGE_MDNS)
    if storage_matches:
        return "nas", "storage", 0.97, [f"mDNS advertises {storage_matches[0]}"]
    if any(v in vendor for v in STORAGE_VENDOR_HINTS) and 445 in ports:
        return "nas", "storage", 0.94, ["storage-appliance vendor plus SMB (445) detected"]

    smart_matches = sorted(mdns & SMART_MDNS)
    if smart_matches:
        return "iot", "smart-home", 0.94, [f"mDNS advertises {smart_matches[0]}"]

    if any(v in vendor for v in NETWORK_VENDOR_HINTS):
        return "network-device", "infrastructure", 0.85, ["MAC vendor is a network-equipment manufacturer"]

    return None, None, 0.0, []


def key_for(device: dict) -> str:
    mac = normalize_mac(device.get("mac", ""))
    return mac or f"ip:{device.get('ip', '')}"


def selector_match(selector: str, devices: dict[str, dict]) -> tuple[str, dict]:
    s = selector.lower().strip()
    exact = []
    for key, d in devices.items():
        fields = [key, d.get("mac", ""), d.get("ip", ""), d.get("hostname", "")]
        if any(str(x).lower() == s for x in fields if x):
            exact.append((key, d))
    if not exact:
        raise SystemExit(f"No discovered device exactly matches: {selector}")
    if len(exact) > 1:
        raise SystemExit(f"Selector is ambiguous: {selector}. Use the MAC address.")
    return exact[0]


def scan(_args) -> None:
    if os.geteuid() != 0:
        raise SystemExit("Run scan with sudo/root; arp-scan requires raw-socket access.")
    interface, network, gateway, own_ip = detect_interface_network()
    state = load_state()
    stamp = now_iso()

    try:
        found = arp_discover(interface)
    except SystemExit:
        found = neighbor_fallback(interface)
    if gateway and gateway not in found:
        try:
            run(["ping", "-c", "1", "-W", "1", gateway], timeout=3)
        except Exception:
            pass
        found.update(neighbor_fallback(interface))

    mdns = avahi_services()
    ports = nmap_ports(sorted(found))

    for old in state["devices"].values():
        old["present"] = False

    # The scanner cannot ARP-discover itself. Add the Pi explicitly from local OS
    # facts so it is always represented in Device Manager and dashboard groups.
    local = local_host_record(interface, own_ip, stamp)
    local_key = key_for(local)
    old_local = state["devices"].get(local_key, {})
    local["first_seen"] = old_local.get("first_seen", stamp)
    local["seen_count"] = int(old_local.get("seen_count", 0)) + 1
    local["state"] = old_local.get("state", "known")
    for field in (
        "approved_type", "approved_group", "kuma_monitor", "approved_at", "ignored_at",
        "manual_type", "manual_group", "manual_hidden", "manual_name", "manual_at",
    ):
        if field in old_local:
            local[field] = old_local[field]
    state["devices"][local_key] = local

    for ip, base in sorted(found.items(), key=lambda kv: ipaddress.ip_address(kv[0])):
        if ip == own_ip:
            continue
        device = dict(base)
        device["hostname"] = reverse_hostname(ip)
        device["mdns"] = mdns.get(ip, [])
        if not device["hostname"] and device["mdns"]:
            device["hostname"] = next((x.get("host") for x in device["mdns"] if x.get("host")), "")
        device["open_ports"] = ports.get(ip, [])
        dtype, group, confidence, evidence = classify(device, gateway)
        device.update({
            "suggested_type": dtype,
            "suggested_group": group,
            "confidence": confidence,
            "evidence": evidence,
            "last_seen": stamp,
            "present": True,
        })
        key = key_for(device)
        old = state["devices"].get(key, {})
        device["first_seen"] = old.get("first_seen", stamp)
        device["seen_count"] = int(old.get("seen_count", 0)) + 1
        device["state"] = old.get("state", "new")
        for field in (
            "approved_type", "approved_group", "kuma_monitor", "approved_at", "ignored_at",
            "manual_type", "manual_group", "manual_hidden", "manual_name", "manual_at",
        ):
            if field in old:
                device[field] = old[field]
        state["devices"][key] = device

    state["last_scan"] = stamp
    state["last_interface"] = interface
    state["last_network"] = network
    save_state(state)
    summary = compute_summary(state)
    print(
        f"Scan complete: {summary['total']} present, "
        f"{summary['classified']} automatically/manual classified, "
        f"{summary['unclassified']} unclassified."
    )


def compute_summary(state: dict) -> dict:
    devices = [d for d in state.get("devices", {}).values() if d.get("present")]
    classified = 0
    unclassified = 0
    manual = 0
    for d in devices:
        if d.get("manual_hidden"):
            continue
        if d.get("manual_type") or d.get("manual_group") or d.get("approved_type") or d.get("approved_group"):
            classified += 1
            manual += 1
        elif d.get("suggested_type") and d.get("suggested_group") and float(d.get("confidence") or 0) >= 0.85:
            classified += 1
        else:
            unclassified += 1
    new = sum(d.get("state") == "new" for d in devices)
    ignored = sum(d.get("state") == "ignored" for d in devices)
    return {
        "total": len(devices), "new": new, "review": unclassified,
        "approved": manual, "ignored": ignored, "suggested": classified - manual,
        "classified": classified, "unclassified": unclassified, "manual": manual,
    }


def list_devices(args) -> None:
    state = load_state()
    rows = []
    for key, d in state.get("devices", {}).items():
        if not args.all and not d.get("present"):
            continue
        rows.append((d.get("ip", ""), key, d))
    rows.sort(key=lambda x: ipaddress.ip_address(x[0]) if x[0] else ipaddress.ip_address("255.255.255.255"))
    print(f"{'IP':15} {'MAC':17} {'STATE':10} {'SUGGESTION':18} {'CONF':>5}  HOST/VENDOR")
    for _ip, key, d in rows:
        suggestion = d.get("approved_type") or d.get("suggested_type") or "-"
        conf = d.get("confidence", 0.0)
        label = d.get("hostname") or d.get("vendor") or "-"
        print(f"{d.get('ip','')[:15]:15} {d.get('mac','')[:17]:17} {d.get('state','')[:10]:10} {suggestion[:18]:18} {conf:>5.2f}  {label}")


def review(_args) -> None:
    state = load_state()
    pending = [(key, d) for key, d in state.get("devices", {}).items() if d.get("present") and d.get("state") in ("new", "review")]
    if not pending:
        print("No present devices need review.")
        return
    for key, d in sorted(pending, key=lambda x: ipaddress.ip_address(x[1].get("ip", "255.255.255.255"))):
        d["state"] = "review"
        print(f"\n{d.get('ip')}  {d.get('mac')}  {d.get('hostname') or '(no hostname)'}")
        print(f"  Vendor: {d.get('vendor') or '(unknown)'}")
        print(f"  Open ports: {', '.join(map(str,d.get('open_ports') or [])) or '(none detected)'}")
        services = sorted({x.get('type','') for x in d.get('mdns') or [] if x.get('type')})
        print(f"  mDNS: {', '.join(services) or '(none detected)'}")
        if d.get("suggested_type"):
            print(f"  Suggestion: {d['suggested_type']} / {d['suggested_group']}  confidence={d.get('confidence',0):.2f}")
            for ev in d.get("evidence") or []:
                print(f"    - {ev}")
        else:
            print("  Suggestion: none; explicit classification required")
        print(f"  Approve: sudo pi-network-discover approve {d.get('mac') or key} <device-type> [--monitor 'Exact Kuma monitor']")
    save_state(state)


def validate_type(device_type: str, group: str | None) -> str:
    if device_type not in TYPE_TO_GROUP:
        raise SystemExit(f"Unsupported device type: {device_type}. Run 'pi-network-discover types'.")
    group = group or TYPE_TO_GROUP[device_type]
    if group not in GROUPS or group == "unclassified":
        raise SystemExit(f"Unsupported approval group: {group}")
    return group


def inventory_set(monitor: str, device_type: str, group: str) -> None:
    if not INVENTORY_CMD.exists():
        raise SystemExit("pi-device-inventory is not installed; cannot classify a Kuma monitor.")
    proc = subprocess.run([str(INVENTORY_CMD), "set", monitor, device_type, group], text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def approve(args) -> None:
    state = load_state()
    key, d = selector_match(args.selector, state.get("devices", {}))
    group = validate_type(args.device_type, args.group)
    d["state"] = "approved"
    d["approved_type"] = args.device_type
    d["approved_group"] = group
    d["approved_at"] = now_iso()
    if args.monitor:
        inventory_set(args.monitor, args.device_type, group)
        d["kuma_monitor"] = args.monitor
    save_state(state)
    print(f"Approved {d.get('ip')} ({d.get('mac')}) -> {args.device_type} / {group}")
    if args.monitor:
        print(f"Kuma dashboard classification applied to exact monitor: {args.monitor}")
    else:
        print("No Kuma monitor was changed. Add --monitor 'Exact Kuma monitor' to classify an existing monitor.")


def approve_suggested(args) -> None:
    state = load_state()
    key, d = selector_match(args.selector, state.get("devices", {}))
    dtype = d.get("suggested_type")
    group = d.get("suggested_group")
    confidence = float(d.get("confidence") or 0)
    if not dtype or not group:
        raise SystemExit("This device has no deterministic suggestion. Use explicit 'approve <selector> <device-type>'.")
    if confidence < 0.90:
        raise SystemExit(f"Suggestion confidence {confidence:.2f} is below the 0.90 safe-approval threshold. Use explicit approve instead.")
    ns = argparse.Namespace(selector=args.selector, device_type=dtype, group=group, monitor=args.monitor)
    approve(ns)


def ignore(args) -> None:
    state = load_state()
    _key, d = selector_match(args.selector, state.get("devices", {}))
    d["state"] = "ignored"
    d["ignored_at"] = now_iso()
    save_state(state)
    print(f"Ignored {d.get('ip')} ({d.get('mac')})")


def summary(args) -> None:
    state = load_state()
    payload = {"last_scan": state.get("last_scan"), **compute_summary(state)}
    if args.json:
        print(json.dumps(payload, separators=(",", ":")))
    else:
        for k, v in payload.items():
            print(f"{k}: {v}")


def types(_args) -> None:
    print("DEVICE TYPES -> DEFAULT GROUP")
    for key in sorted(TYPE_TO_GROUP):
        print(f"  {key:18} {TYPE_TO_GROUP[key]:14} {GROUPS[TYPE_TO_GROUP[key]]}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Automatic conservative LAN discovery with persistent manual overrides")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("scan", help="scan the active Ethernet LAN; does not modify Kuma").set_defaults(func=scan)
    ls = sub.add_parser("list", help="list discovered devices")
    ls.add_argument("--all", action="store_true", help="include devices not seen in the most recent scan")
    ls.set_defaults(func=list_devices)
    sub.add_parser("review", help="show devices needing explicit review").set_defaults(func=review)
    sub.add_parser("types", help="show supported device types and default groups").set_defaults(func=types)
    sm = sub.add_parser("summary", help="show discovery counts")
    sm.add_argument("--json", action="store_true")
    sm.set_defaults(func=summary)

    ap = sub.add_parser("approve", help="explicitly approve a discovered device classification")
    ap.add_argument("selector", help="exact MAC, IP, state key, or hostname")
    ap.add_argument("device_type", choices=sorted(TYPE_TO_GROUP))
    ap.add_argument("--group", choices=[g for g in GROUPS if g != "unclassified"])
    ap.add_argument("--monitor", help="exact existing Kuma monitor name or ID to classify in the dashboard inventory")
    ap.set_defaults(func=approve)

    aps = sub.add_parser("approve-suggested", help="accept a deterministic suggestion with confidence >= 0.90")
    aps.add_argument("selector", help="exact MAC, IP, state key, or hostname")
    aps.add_argument("--monitor", help="exact existing Kuma monitor name or ID to classify in the dashboard inventory")
    aps.set_defaults(func=approve_suggested)

    ig = sub.add_parser("ignore", help="mark a discovered device as intentionally ignored")
    ig.add_argument("selector")
    ig.set_defaults(func=ignore)
    return p


def main() -> None:
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
V37_DISCOVER
chmod 0755 "$DEST"
DEST=/usr/local/lib/pi-network-status/device_manager.py
cat >"$DEST" <<'V37_MANAGER'
#!/usr/bin/env python3
"""Shared classification and grouping helpers for network discovery + Kuma.

Classification never uses a device/monitor name. Automatic assignment is based only
on scanner-produced evidence fields. Manual overrides always win until cleared.
"""
from __future__ import annotations

import ipaddress
from typing import Any

AUTO_CONFIDENCE_THRESHOLD = 0.85

GROUPS = {
    "infrastructure": "Infrastructure",
    "storage": "Storage & Servers",
    "smart-home": "Smart Home & IoT",
    "security": "Cameras & Security",
    "services": "Services",
    "websites": "Websites",
    "other": "Other Devices",
    "unclassified": "Unclassified",
}

GROUP_ORDER = [
    "infrastructure", "storage", "smart-home", "security",
    "services", "websites", "other", "unclassified",
]

TYPE_TO_GROUP = {
    "access-point": "infrastructure",
    "router": "infrastructure",
    "switch": "infrastructure",
    "network-device": "infrastructure",
    "modem": "infrastructure",
    "nas": "storage",
    "storage": "storage",
    "server": "storage",
    "raspberry-pi": "infrastructure",
    "smart-home": "smart-home",
    "iot": "smart-home",
    "sensor": "smart-home",
    "bridge": "smart-home",
    "tv": "smart-home",
    "speaker": "smart-home",
    "camera": "security",
    "nvr": "security",
    "security": "security",
    "dns": "services",
    "service": "services",
    "website": "websites",
    "printer": "other",
    "other": "other",
}


def ipv4_sort_key(record: dict[str, Any]) -> tuple[int, int, str]:
    """Sort IPv4 addresses numerically; missing/non-IPv4 addresses sort last.

    Names are used only as a stable tie-breaker and never for classification.
    """
    value = str(record.get("ip") or "").strip()
    label = str(record.get("name") or record.get("hostname") or record.get("id") or "").lower()
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return (2, 0, label)
    if address.version == 4:
        return (0, int(address), label)
    return (1, int(address), label)


def effective_classification(record: dict[str, Any]) -> dict[str, Any]:
    """Return effective type/group while preserving the underlying evidence.

    Manual fields have precedence. Legacy approved_* fields are treated as manual
    for backward compatibility. Automatic suggestions are accepted only at or above
    AUTO_CONFIDENCE_THRESHOLD. No hostname/name field participates in this logic.
    """
    manual_type = record.get("manual_type") or record.get("approved_type")
    manual_group = record.get("manual_group") or record.get("approved_group")

    if manual_type or manual_group:
        device_type = manual_type or record.get("suggested_type") or "other"
        group = manual_group or TYPE_TO_GROUP.get(str(device_type), "unclassified")
        if group not in GROUPS:
            group = "unclassified"
        return {"type": str(device_type), "group": group, "source": "manual", "confidence": 1.0}

    confidence = float(record.get("confidence") or 0.0)
    suggested_type = record.get("suggested_type")
    suggested_group = record.get("suggested_group")
    if (
        suggested_type
        and suggested_group in GROUPS
        and confidence >= AUTO_CONFIDENCE_THRESHOLD
    ):
        return {
            "type": str(suggested_type),
            "group": str(suggested_group),
            "source": "automatic",
            "confidence": confidence,
        }

    return {"type": "other", "group": "unclassified", "source": "unclassified", "confidence": confidence}


def modem_ip_from_state(state: dict[str, Any]) -> str:
    """Return the IPv4 address of a device explicitly/effectively classified as modem."""
    candidates = []
    for record in (state.get("devices") or {}).values():
        if not isinstance(record, dict):
            continue
        if effective_classification(record)["type"] != "modem":
            continue
        value = str(record.get("ip") or "").strip()
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            continue
        if address.version == 4:
            candidates.append((0 if record.get("present") else 1, int(address), value))
    return sorted(candidates)[0][2] if candidates else ""


def device_label(record: dict[str, Any]) -> str:
    """Choose a display label only. This function is never used for classification."""
    return (
        record.get("manual_name")
        or record.get("hostname")
        or record.get("vendor")
        or record.get("ip")
        or record.get("mac")
        or "Unknown device"
    )


def _row(key: str, record: dict[str, Any]) -> dict[str, Any]:
    effective = effective_classification(record)
    present = bool(record.get("present"))
    ip = record.get("ip") or ""
    return {
        "id": f"discovery:{key}",
        "source": "discovery",
        "discovery_key": key,
        "name": device_label(record),
        "ip": ip,
        "mac": record.get("mac") or "",
        "vendor": record.get("vendor") or "",
        "hostname": record.get("hostname") or "",
        "device_type": effective["type"],
        "group": effective["group"],
        "classification_source": effective["source"],
        "classification_confidence": effective["confidence"],
        "status": 1 if present else 0,
        "status_label": "Online" if present else "Offline",
        "latency_ms": None,
        "uptime_24": None,
        "href": f"/devices#{key}",
        "classified": effective["group"] != "unclassified",
        "last_seen": record.get("last_seen"),
        "first_seen": record.get("first_seen"),
        "open_ports": list(record.get("open_ports") or []),
        "evidence": list(record.get("evidence") or []),
        "auto_type": record.get("suggested_type"),
        "auto_group": record.get("suggested_group"),
        "auto_confidence": float(record.get("confidence") or 0.0),
        "manual_type": record.get("manual_type") or record.get("approved_type"),
        "manual_group": record.get("manual_group") or record.get("approved_group"),
        "hidden": bool(record.get("manual_hidden", False)),
        "kuma_monitor": record.get("kuma_monitor"),
        "local_host": bool(record.get("local_host", False)),
        "model": record.get("model") or "",
    }


def build_discovered_groups(state: dict[str, Any]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {key: [] for key in GROUP_ORDER}
    hidden = 0
    total = 0
    for key, record in (state.get("devices") or {}).items():
        if not isinstance(record, dict):
            continue
        total += 1
        row = _row(str(key), record)
        if row["hidden"]:
            hidden += 1
            continue
        grouped[row["group"]].append(row)

    groups = []
    for group_key in GROUP_ORDER:
        rows = grouped[group_key]
        if not rows:
            continue
        rows.sort(key=ipv4_sort_key)
        groups.append({"key": group_key, "title": GROUPS[group_key], "monitors": rows})

    return {
        "configured": True,
        "groups": groups,
        "total": total,
        "hidden": hidden,
        "last_scan": state.get("last_scan"),
    }


def merge_with_kuma(discovery_state: dict[str, Any], kuma_payload: dict[str, Any] | None) -> dict[str, Any]:
    """Merge discovered LAN devices with Kuma-only monitors without name guessing.

    A discovered device is merged with Kuma only when an explicit `kuma_monitor`
    mapping matches the Kuma monitor ID or exact monitor name. Otherwise both remain
    independent records.
    """
    base = build_discovered_groups(discovery_state)
    rows_by_group: dict[str, list[dict[str, Any]]] = {key: [] for key in GROUP_ORDER}
    discovery_rows: list[dict[str, Any]] = []
    for group in base["groups"]:
        discovery_rows.extend(group["monitors"])

    kuma_rows: list[dict[str, Any]] = []
    for group in (kuma_payload or {}).get("groups") or []:
        for monitor in group.get("monitors") or []:
            m = dict(monitor)
            m.setdefault("group", group.get("key") or "unclassified")
            kuma_rows.append(m)

    matched_kuma_ids: set[str] = set()
    by_name = {str(m.get("name")): m for m in kuma_rows if m.get("name")}
    by_id = {str(m.get("id")): m for m in kuma_rows if m.get("id") is not None}

    for row in discovery_rows:
        mapping = row.get("kuma_monitor")
        match = None
        if mapping is not None:
            match = by_id.get(str(mapping)) or by_name.get(str(mapping))
        if match:
            for field in ("status", "status_label", "latency_ms", "uptime_24", "href"):
                if match.get(field) is not None:
                    row[field] = match[field]
            matched_kuma_ids.add(str(match.get("id")))
        rows_by_group[row["group"]].append(row)

    for monitor in kuma_rows:
        if str(monitor.get("id")) in matched_kuma_ids:
            continue
        group_key = monitor.get("group") or "unclassified"
        if group_key not in GROUPS:
            group_key = "unclassified"
        monitor = dict(monitor)
        monitor["source"] = "kuma"
        rows_by_group[group_key].append(monitor)

    groups = []
    for key in GROUP_ORDER:
        rows = rows_by_group[key]
        if not rows:
            continue
        rows.sort(key=ipv4_sort_key)
        groups.append({"key": key, "title": GROUPS[key], "monitors": rows})

    summary = {"total": 0, "up": 0, "down": 0, "pending": 0, "maintenance": 0, "unknown": 0}
    for group in groups:
        for item in group["monitors"]:
            summary["total"] += 1
            status = item.get("status")
            if status == 1:
                summary["up"] += 1
            elif status == 0:
                summary["down"] += 1
            elif status == 2:
                summary["pending"] += 1
            elif status == 3:
                summary["maintenance"] += 1
            else:
                summary["unknown"] += 1

    return {
        "configured": True,
        "groups": groups,
        "summary": summary,
        "kuma_summary": (kuma_payload or {}).get("summary", {}),
        "last_scan": base.get("last_scan"),
        "hidden": base.get("hidden", 0),
    }
V37_MANAGER
chmod 0644 "$DEST"
DEST=/usr/local/sbin/pi-network-status-api.py
cat >"$DEST" <<'V37_STATUS'
#!/usr/bin/env python3

import datetime as dt
import http.server
import ipaddress
import json
import os
import shutil
import socketserver
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, "/usr/local/lib/pi-network-status")
from kuma_normalizer import normalize_kuma_status
from device_manager import GROUPS, TYPE_TO_GROUP, device_label, effective_classification, ipv4_sort_key, merge_with_kuma, modem_ip_from_state

TOKEN = os.environ["STATUS_API_TOKEN"]
PORT = int(os.environ.get("STATUS_API_PORT", "9108"))
TARGET_IP = os.environ.get("TARGET_IP", "192.168.0.10")
GATEWAY = os.environ.get("GATEWAY", "192.168.0.1")
LAN_CIDR = os.environ.get("LAN_CIDR", "192.168.0.0/24")
DASHBOARD_PORT = int(os.environ.get("DASHBOARD_PORT", "3000"))
UNBOUND_PORT = os.environ.get("UNBOUND_PORT", "5335")
KUMA_LOCAL_URL = os.environ.get("KUMA_LOCAL_URL", "http://127.0.0.1:3001").rstrip("/")
KUMA_PUBLIC_URL = os.environ.get("KUMA_PUBLIC_URL", f"http://{TARGET_IP}:3001").rstrip("/")
KUMA_STATUS_SLUG = os.environ.get("KUMA_STATUS_SLUG", "home-network")
KUMA_CACHE_SECONDS = max(2, int(os.environ.get("KUMA_CACHE_SECONDS", "8")))
DEVICE_INVENTORY_FILE = Path(os.environ.get("DEVICE_INVENTORY_FILE", "/var/lib/pi4-network-stack/device-inventory.json"))
DISCOVERY_STATE_FILE = Path(os.environ.get("DISCOVERY_STATE_FILE", "/var/lib/pi4-network-stack/network-discovery.json"))
DEVICE_MANAGER_HTML = Path(os.environ.get("DEVICE_MANAGER_HTML", "/usr/local/share/pi-network-manager/devices.html"))
MODE_FILE = Path("/var/lib/pi4-network-stack/dns-upstream-mode")

_KUMA_CACHE = {"at": 0.0, "payload": None}


def run(cmd, timeout=3):
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode, result.stdout.strip()
    except Exception:
        return 1, ""


def active(service):
    rc, _ = run(["systemctl", "is-active", "--quiet", service])
    return rc == 0


def cpu_percent():
    def snapshot():
        parts = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        vals = [int(x) for x in parts]
        idle = vals[3] + vals[4]
        total = sum(vals)
        return idle, total

    i1, t1 = snapshot()
    time.sleep(0.12)
    i2, t2 = snapshot()
    delta_t = max(t2 - t1, 1)
    delta_i = i2 - i1
    return round((1 - delta_i / delta_t) * 100, 1)


def memory_percent():
    data = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, v = line.split(":", 1)
        data[k] = int(v.strip().split()[0])
    total = data["MemTotal"]
    available = data.get("MemAvailable", data.get("MemFree", 0))
    return round((total - available) * 100 / total, 1)


def temp_c():
    try:
        return round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000, 1)
    except Exception:
        return None


def uptime_seconds():
    return int(float(Path("/proc/uptime").read_text().split()[0]))


def dns_test(server, port=None):
    cmd = ["dig", f"@{server}"]
    if port:
        cmd += ["-p", str(port)]
    cmd += ["example.com", "A", "+time=2", "+tries=1", "+stats"]
    start = time.monotonic()
    rc, out = run(cmd, timeout=4)
    ms = round((time.monotonic() - start) * 1000)
    return rc == 0 and "status: NOERROR" in out, ms


def tail_ip():
    rc, out = run(["tailscale", "ip", "-4"])
    return out.splitlines()[0] if rc == 0 and out else "Not connected"


def docker_containers():
    rc, out = run(["docker", "ps", "--format", "{{.Names}}"], timeout=4)
    if rc != 0:
        return []
    return [x for x in out.splitlines() if x]


def mode():
    try:
        return MODE_FILE.read_text().strip().capitalize()
    except Exception:
        return "Unknown"


def _get_json(url, timeout=4):
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "pi-network-status/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _load_json(path: Path, fallback):
    try:
        payload = json.loads(path.read_text())
        return payload if isinstance(payload, dict) else fallback
    except Exception:
        return fallback


def _load_inventory():
    return _load_json(DEVICE_INVENTORY_FILE, {"devices": {}})


def _load_discovery():
    return _load_json(DISCOVERY_STATE_FILE, {"version": 1, "last_scan": None, "devices": {}})


def _save_discovery(payload):
    DISCOVERY_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = DISCOVERY_STATE_FILE.with_suffix(DISCOVERY_STATE_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, DISCOVERY_STATE_FILE)


def _unconfigured_payload(error=None):
    payload = {
        "configured": False,
        "published": False,
        "slug": KUMA_STATUS_SLUG,
        "status_page_url": f"{KUMA_PUBLIC_URL}/status/{KUMA_STATUS_SLUG}",
        "groups": [],
        "summary": {"total": 0, "up": 0, "down": 0, "pending": 0, "maintenance": 0, "unknown": 0},
    }
    if error:
        payload["error"] = error
    return payload


def kuma_payload(force=False):
    now = time.monotonic()
    if not force and _KUMA_CACHE["payload"] is not None and now - _KUMA_CACHE["at"] < KUMA_CACHE_SECONDS:
        return _KUMA_CACHE["payload"]

    status_url = f"{KUMA_LOCAL_URL}/api/status-page/{KUMA_STATUS_SLUG}"
    heartbeat_url = f"{KUMA_LOCAL_URL}/api/status-page/heartbeat/{KUMA_STATUS_SLUG}"
    try:
        status_page = _get_json(status_url)
    except urllib.error.HTTPError as exc:
        payload = _unconfigured_payload("status page is not published" if exc.code == 404 else f"Kuma status page HTTP {exc.code}")
        _KUMA_CACHE.update(at=now, payload=payload)
        return payload
    except Exception as exc:
        payload = _unconfigured_payload(f"Kuma status page unavailable: {type(exc).__name__}")
        _KUMA_CACHE.update(at=now, payload=payload)
        return payload

    heartbeat_error = None
    try:
        heartbeat_page = _get_json(heartbeat_url)
    except Exception as exc:
        heartbeat_page = {"heartbeatList": {}, "uptimeList": {}}
        heartbeat_error = f"Kuma heartbeat data unavailable: {type(exc).__name__}"

    payload = normalize_kuma_status(status_page, heartbeat_page, KUMA_PUBLIC_URL, KUMA_STATUS_SLUG, _load_inventory())
    if heartbeat_error:
        payload["warning"] = heartbeat_error
    _KUMA_CACHE.update(at=now, payload=payload)
    return payload


def unified_devices_payload():
    return merge_with_kuma(_load_discovery(), kuma_payload())


def discovery_summary():
    state = _load_discovery()
    present = [d for d in (state.get("devices") or {}).values() if isinstance(d, dict) and d.get("present")]
    classified = 0
    manual = 0
    hidden = 0
    for d in present:
        if d.get("manual_hidden"):
            hidden += 1
        eff = effective_classification(d)
        if eff["group"] != "unclassified":
            classified += 1
        if eff["source"] == "manual":
            manual += 1
    return {
        "last_scan": state.get("last_scan"),
        "total": len(present),
        "classified": classified,
        "unclassified": len(present) - classified,
        "manual": manual,
        "hidden": hidden,
        "scanning": active("pi-network-discovery.service"),
    }


def discovery_manager_payload():
    state = _load_discovery()
    monitors = []
    seen = set()
    for group in (kuma_payload() or {}).get("groups") or []:
        for monitor in group.get("monitors") or []:
            key = str(monitor.get("id") if monitor.get("id") is not None else monitor.get("name"))
            if key in seen:
                continue
            seen.add(key)
            monitors.append({"id": monitor.get("id"), "name": monitor.get("name") or key})
    monitors.sort(key=lambda m: (m.get("name") or "").lower())

    devices = []
    for key, record in (state.get("devices") or {}).items():
        if not isinstance(record, dict):
            continue
        eff = effective_classification(record)
        devices.append({
            "key": str(key),
            "name": device_label(record),
            "manual_name": record.get("manual_name") or "",
            "detected_name": (record.get("hostname") or record.get("vendor") or record.get("ip") or record.get("mac") or "Unknown device"),
            "ip": record.get("ip") or "",
            "mac": record.get("mac") or "",
            "hostname": record.get("hostname") or "",
            "vendor": record.get("vendor") or "",
            "present": bool(record.get("present")),
            "last_seen": record.get("last_seen"),
            "first_seen": record.get("first_seen"),
            "open_ports": list(record.get("open_ports") or []),
            "evidence": list(record.get("evidence") or []),
            "auto_type": record.get("suggested_type"),
            "auto_group": record.get("suggested_group"),
            "auto_confidence": float(record.get("confidence") or 0.0),
            "manual_type": record.get("manual_type") or record.get("approved_type"),
            "manual_group": record.get("manual_group") or record.get("approved_group"),
            "effective_type": eff["type"],
            "effective_group": eff["group"],
            "classification_source": eff["source"],
            "hidden": bool(record.get("manual_hidden", False)),
            "kuma_monitor": record.get("kuma_monitor") or "",
            "local_host": bool(record.get("local_host", False)),
            "model": record.get("model") or "",
        })
    devices.sort(key=ipv4_sort_key)
    summary = discovery_summary()
    return {
        **summary,
        "devices": devices,
        "groups": GROUPS,
        "types": TYPE_TO_GROUP,
        "kuma_monitors": monitors,
    }


def _validate_update(payload):
    key = str(payload.get("key") or "").strip()
    if not key:
        raise ValueError("device key is required")
    device_type = str(payload.get("type") or "auto").strip()
    group = str(payload.get("group") or "auto").strip()
    manual_name = str(payload.get("manual_name") or "").strip()
    if len(manual_name) > 120:
        raise ValueError("device name must be 120 characters or fewer")
    if device_type != "auto" and device_type not in TYPE_TO_GROUP:
        raise ValueError(f"unsupported device type: {device_type}")
    if group != "auto" and group not in GROUPS:
        raise ValueError(f"unsupported dashboard section: {group}")
    return key, device_type, group, manual_name


def update_device(payload, reset=False):
    state = _load_discovery()
    devices = state.setdefault("devices", {})
    key = str(payload.get("key") or "").strip()
    if key not in devices:
        raise KeyError("device not found")
    record = devices[key]
    if reset:
        for field in ("manual_type", "manual_group", "manual_hidden", "manual_at", "approved_type", "approved_group", "approved_at"):
            record.pop(field, None)
    else:
        key, device_type, group, manual_name = _validate_update(payload)
        if manual_name:
            record["manual_name"] = manual_name
        else:
            record.pop("manual_name", None)
        if device_type == "auto":
            record.pop("manual_type", None)
            record.pop("approved_type", None)
        else:
            record["manual_type"] = device_type
            record.pop("approved_type", None)
        if group == "auto":
            record.pop("manual_group", None)
            record.pop("approved_group", None)
        else:
            record["manual_group"] = group
            record.pop("approved_group", None)
        record["manual_hidden"] = bool(payload.get("hidden", False))
        mapping = str(payload.get("kuma_monitor") or "").strip()
        if mapping:
            record["kuma_monitor"] = mapping
        else:
            record.pop("kuma_monitor", None)
        record["manual_at"] = dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")
    _save_discovery(state)
    return record


class Handler(http.server.BaseHTTPRequestHandler):
    def _client_allowed(self):
        try:
            address = ipaddress.ip_address(self.client_address[0])
            return address.is_loopback or address in ipaddress.ip_network(LAN_CIDR, strict=False) or address in ipaddress.ip_network("100.64.0.0/10")
        except Exception:
            return False

    def _cors_origin(self):
        origin = self.headers.get("Origin", "")
        if origin and self._client_allowed():
            return origin
        return "*"

    def _json(self, payload, status=200, public=False, writable=False):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        if public or writable:
            self.send_header("Access-Control-Allow-Origin", self._cors_origin() if writable else "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS" if writable else "GET")
            if writable:
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Vary", "Origin")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, text, status=200):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return self.headers.get("X-API-Token", "") == TOKEN

    def _read_json(self):
        try:
            length = min(int(self.headers.get("Content-Length", "0") or 0), 65536)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:
            raise ValueError("invalid JSON request") from exc

    def do_OPTIONS(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/manage/") and self._client_allowed():
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", self._cors_origin())
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Max-Age", "600")
            self.send_header("Vary", "Origin")
            self.end_headers()
            return
        self.send_response(403)
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/devices":
            if not self._client_allowed():
                self._html("<h1>Forbidden</h1>", 403)
                return
            try:
                text = DEVICE_MANAGER_HTML.read_text().replace("__TARGET_IP__", TARGET_IP)
            except Exception:
                self._html("<h1>Device manager unavailable</h1>", 503)
                return
            self._html(text)
            return

        if path in ("/public/devices/groups", "/public/discovery/devices", "/public/discovery/summary") and not self._client_allowed():
            self._json({"error": "LAN/Tailscale access required"}, 403, public=True)
            return
        if path == "/public/devices/groups":
            self._json(unified_devices_payload(), public=True)
            return
        if path == "/public/discovery/devices":
            self._json(discovery_manager_payload(), public=True)
            return
        if path == "/public/discovery/summary":
            self._json(discovery_summary(), public=True)
            return

        if path == "/public/kuma/groups":
            self._json(kuma_payload(), public=True)
            return
        if path == "/public/kuma/summary":
            payload = kuma_payload()
            self._json({
                "configured": payload.get("configured", False),
                "inventory_count": payload.get("inventory_count", 0),
                "summary": payload.get("summary", {}),
                "status_page_url": payload.get("status_page_url"),
            }, public=True)
            return
        if path == "/public/kuma/config":
            payload = kuma_payload()
            self._json({
                "configured": payload.get("configured", False),
                "published": payload.get("published", False),
                "inventory_count": payload.get("inventory_count", 0),
                "slug": KUMA_STATUS_SLUG,
                "status_page_url": payload.get("status_page_url"),
            }, public=True)
            return

        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return

        if path == "/api/system":
            disk = shutil.disk_usage("/")
            self._json({"status": "Online", "cpu": cpu_percent(), "memory": memory_percent(), "temperature": temp_c(), "disk": round(disk.used * 100 / disk.total, 1), "uptime": uptime_seconds()})
            return
        if path == "/api/unbound":
            ok, latency = dns_test("127.0.0.1", UNBOUND_PORT)
            self._json({"status": "Active" if active("unbound") and ok else "Degraded", "resolver": "Recursive", "dnssec": "Enabled", "latency": latency, "mode": mode()})
            return
        if path == "/api/pihole":
            ok, latency = dns_test(TARGET_IP)
            self._json({"status": "Active" if active("pihole-FTL") and ok else "Degraded", "filtering": "Enabled" if active("pihole-FTL") else "Unknown", "dhcp": "Disabled", "upstream": mode(), "latency": latency})
            return
        if path == "/api/tailscale":
            self._json({"status": "Active" if active("tailscaled") else "Inactive", "address": tail_ip(), "subnet": "Advertised", "ssh": "Enabled"})
            return
        if path == "/api/docker":
            containers = docker_containers()
            self._json({"status": "Active" if active("docker") else "Inactive", "running": len(containers), "containers": ", ".join(containers) if containers else "None"})
            return
        if path == "/api/network":
            gateway_ok = run(["ping", "-c", "1", "-W", "1", GATEWAY])[0] == 0
            internet_ok = run(["ping", "-c", "1", "-W", "1", "1.1.1.1"])[0] == 0
            self._json({"gateway": "Online" if gateway_ok else "Down", "internet": "Online" if internet_ok else "Down", "address": TARGET_IP, "modem_ip": modem_ip_from_state(_load_discovery()) or "Not set", "dns_path": f"Pi-hole -> {mode()}"})
            return
        if path == "/api/ssh":
            self._json({"status": "Active" if active("ssh") else "Inactive", "watchdog": "Active" if active("ssh-watchdog.timer") else "Inactive", "port": 22})
            return
        if path == "/api/discovery":
            s = discovery_summary()
            self._json({
                "status": "Scanning" if s["scanning"] else ("Ready" if s["last_scan"] else "Never"),
                "total": s["total"],
                "classified": s["classified"],
                "unclassified": s["unclassified"],
                "manual": s["manual"],
                "last_scan": s["last_scan"] or "Never",
            })
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith("/manage/"):
            self._json({"error": "not found"}, 404, writable=True)
            return
        if not self._client_allowed():
            self._json({"error": "management is restricted to LAN/Tailscale clients"}, 403, writable=True)
            return
        try:
            payload = self._read_json()
            if path == "/manage/scan":
                if active("pi-network-discovery.service"):
                    self._json({"started": False, "scanning": True, **discovery_summary()}, 202, writable=True)
                    return
                rc = subprocess.run(["systemctl", "start", "--no-block", "pi-network-discovery.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
                if rc != 0:
                    self._json({"error": "could not start network discovery"}, 500, writable=True)
                    return
                self._json({"started": True, "scanning": True}, 202, writable=True)
                return
            if path == "/manage/device":
                record = update_device(payload, reset=False)
                self._json({"saved": True, "effective": effective_classification(record)}, writable=True)
                return
            if path == "/manage/device/reset":
                record = update_device(payload, reset=True)
                self._json({"saved": True, "effective": effective_classification(record)}, writable=True)
                return
            self._json({"error": "not found"}, 404, writable=True)
        except KeyError as exc:
            self._json({"error": str(exc)}, 404, writable=True)
        except ValueError as exc:
            self._json({"error": str(exc)}, 400, writable=True)
        except Exception as exc:
            self._json({"error": f"management error: {type(exc).__name__}"}, 500, writable=True)

    def log_message(self, fmt, *args):
        return


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("0.0.0.0", PORT), Handler) as server:
        server.serve_forever()
V37_STATUS
chmod 0755 "$DEST"
DEST=/usr/local/share/pi-network-manager/devices.html
cat >"$DEST" <<'V37_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network Device Manager</title>
<style>
:root{color-scheme:dark;--bg:#111c2f;--panel:#142238;--panel2:#0f1b2e;--line:rgba(148,163,184,.16);--text:#dbe5f2;--muted:#8190a6;--teal:#2dd4bf;--blue:#38bdf8;--amber:#f59e0b;--red:#f87171;--green:#10b981}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% 5%,rgba(30,64,175,.10),transparent 32%),var(--bg);font:14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:var(--text)}
a{color:inherit}.wrap{max-width:1500px;margin:0 auto;padding:24px 30px 60px}.top{display:flex;align-items:center;gap:14px;flex-wrap:wrap}.top h1{font-size:22px;font-weight:500;margin:0;flex:1}.actions{display:flex;gap:8px}.btn{border:1px solid rgba(148,163,184,.22);background:#1b2a42;color:var(--text);border-radius:9px;padding:9px 13px;cursor:pointer;text-decoration:none}.btn:hover{border-color:rgba(45,212,191,.55)}.btn.primary{border-color:rgba(45,212,191,.55);background:rgba(13,148,136,.16)}.btn:disabled{opacity:.55;cursor:wait}
.summary{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin:22px 0}.metric{background:linear-gradient(145deg,rgba(20,34,56,.96),rgba(15,27,46,.9));border:1px solid var(--line);border-radius:13px;padding:13px 15px}.metric b{display:block;font-size:22px;font-weight:500}.metric small{color:var(--muted);text-transform:uppercase;font-size:10px;letter-spacing:.06em}
.toolbar{display:flex;gap:10px;align-items:center;margin-bottom:12px}.toolbar input,.toolbar select{background:#0f1b2e;border:1px solid var(--line);color:var(--text);border-radius:8px;padding:9px 10px}.toolbar input{min-width:260px}.status{margin-left:auto;color:var(--muted)}
.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:15px;background:rgba(15,27,46,.64)}table{width:100%;border-collapse:collapse;min-width:1180px}th,td{padding:10px 12px;border-bottom:1px solid rgba(148,163,184,.09);vertical-align:middle;text-align:left}th{position:sticky;top:0;background:#17253b;color:#9fb0c8;font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.04em}tr:last-child td{border-bottom:0}tr:hover td{background:rgba(51,65,85,.20)}
.device{display:flex;align-items:center;gap:9px}.dot{width:9px;height:9px;border-radius:50%;background:var(--muted);box-shadow:0 0 0 3px rgba(129,144,166,.10)}.dot.up{background:var(--green)}.dot.down{background:var(--red)}.name{font-weight:500}.device-name{width:220px;max-width:100%;background:#101d31;border:1px solid rgba(148,163,184,.18);color:var(--text);border-radius:7px;padding:7px 9px;font:inherit}.device-name::placeholder{color:#7890ae}.sub{font-size:11px;color:var(--muted)}.auto{font-size:12px}.conf{color:var(--muted);font-size:11px}.select{width:170px;background:#101d31;border:1px solid rgba(148,163,184,.18);color:var(--text);border-radius:7px;padding:7px}.select.group{width:190px}.select.kuma{width:190px}.hide{display:flex;align-items:center;gap:6px}.reset{font-size:11px;padding:6px 8px}.evidence{max-width:260px;color:var(--muted);font-size:11px}.badge{display:inline-block;padding:2px 6px;border:1px solid rgba(148,163,184,.16);border-radius:999px;font-size:10px;color:#a9bad0}.badge.manual{border-color:rgba(45,212,191,.35);color:#5eead4}.badge.auto{border-color:rgba(56,189,248,.30);color:#7dd3fc}.badge.unclassified{border-color:rgba(245,158,11,.28);color:#fbbf24}
@media(max-width:800px){.wrap{padding:18px 14px}.summary{grid-template-columns:repeat(2,minmax(0,1fr))}.toolbar{align-items:stretch;flex-direction:column}.toolbar input{min-width:0;width:100%}.status{margin-left:0}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top"><h1>Network Device Manager</h1><div class="actions"><a class="btn" href="http://__TARGET_IP__:3000/">← Dashboard</a><button id="scan" class="btn primary">↻ Refresh Network</button></div></div>
  <div class="summary"><div class="metric"><b id="total">0</b><small>Devices</small></div><div class="metric"><b id="online">0</b><small>Online</small></div><div class="metric"><b id="classified">0</b><small>Classified</small></div><div class="metric"><b id="unclassified">0</b><small>Unclassified</small></div><div class="metric"><b id="hidden">0</b><small>Hidden</small></div></div>
  <div class="toolbar"><input id="search" placeholder="Filter by name, IP, MAC or vendor"><select id="filter"><option value="all">All devices</option><option value="online">Online</option><option value="offline">Offline</option><option value="unclassified">Unclassified</option><option value="manual">Manual overrides</option><option value="hidden">Hidden</option></select><span id="status" class="status"></span></div>
  <div class="table-wrap"><table><thead><tr><th>Device</th><th>IP / MAC</th><th>Observed evidence</th><th>Detected as</th><th>Device type</th><th>Dashboard section</th><th>Kuma monitor</th><th>Visible</th><th></th></tr></thead><tbody id="rows"></tbody></table></div>
</div>
<script>
(() => {
'use strict';
const $ = (s) => document.querySelector(s);
let payload = {devices:[], groups:{}, types:{}, kuma_monitors:[]};
const esc = (v) => String(v ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;');
function ipKey(ip){const p=String(ip||'').split('.');if(p.length!==4||p.some(x=>!/^\d+$/.test(x)||Number(x)>255))return [1,0];return [0,p.reduce((n,x)=>(n*256)+Number(x),0)]}
function compareIp(a,b){const ka=ipKey(a.ip),kb=ipKey(b.ip);return ka[0]-kb[0]||ka[1]-kb[1]||String(a.name||'').localeCompare(String(b.name||''))}
async function api(path, options={}) { const r=await fetch(path,{cache:'no-store',...options,headers:{'Content-Type':'application/json',...(options.headers||{})}}); const body=await r.json(); if(!r.ok) throw new Error(body.error||`HTTP ${r.status}`); return body; }
function option(value,label,selected){return `<option value="${esc(value)}"${selected?' selected':''}>${esc(label)}</option>`}
function typeOptions(d){let out=option('auto','Auto',!d.manual_type); for(const t of Object.keys(payload.types).sort()) out+=option(t,t,d.manual_type===t); return out}
function groupOptions(d){let out=option('auto','Auto',!d.manual_group); for(const [k,v] of Object.entries(payload.groups)) out+=option(k,v,d.manual_group===k); return out}
function kumaOptions(d){let out=option('','None',!d.kuma_monitor); for(const m of payload.kuma_monitors) out+=option(String(m.id??m.name),m.name,String(d.kuma_monitor||'')===String(m.id??m.name)||String(d.kuma_monitor||'')===String(m.name)); return out}
function keep(d){const q=$('#search').value.trim().toLowerCase(); const f=$('#filter').value; const hay=[d.name,d.ip,d.mac,d.vendor,d.hostname].join(' ').toLowerCase(); if(q&&!hay.includes(q)) return false; if(f==='online'&&!d.present)return false;if(f==='offline'&&d.present)return false;if(f==='unclassified'&&d.effective_group!=='unclassified')return false;if(f==='manual'&&d.classification_source!=='manual')return false;if(f==='hidden'&&!d.hidden)return false;return true}
function render(){const ds=payload.devices.filter(keep).sort(compareIp); $('#rows').innerHTML=ds.map(d=>{const ev=(d.evidence||[]).join('; ')||((d.open_ports||[]).length?`Ports: ${d.open_ports.join(', ')}`:'No deterministic signature');const badge=d.classification_source==='manual'?'manual':d.classification_source==='automatic'?'auto':'unclassified';return `<tr id="${esc(d.key)}"><td><div class="device"><span class="dot ${d.present?'up':'down'}"></span><div><input class="device-name" data-key="${esc(d.key)}" value="${esc(d.manual_name||'')}" placeholder="${esc(d.detected_name||d.name||'Device name')}" aria-label="Custom device name"><div class="sub">${d.local_host?'Local Host · ':''}${d.manual_name?'Custom name':'Detected: '+esc(d.detected_name||d.name||'Unknown')} · ${d.present?'Online':'Not seen in latest scan'} · last ${esc(d.last_seen||'never')}</div></div></div></td><td><div>${esc(d.ip)}</div><div class="sub">${esc(d.mac)}</div><div class="sub">${esc(d.vendor)}</div></td><td class="evidence">${esc(ev)}</td><td class="auto">${esc(d.auto_type||'Unclassified')}<div class="conf">${esc(d.auto_group||'')} ${d.auto_confidence?Math.round(d.auto_confidence*100)+'%':''}</div><span class="badge ${badge}">${esc(d.classification_source)}</span></td><td><select class="select device-type" data-key="${esc(d.key)}">${typeOptions(d)}</select></td><td><select class="select group" data-key="${esc(d.key)}">${groupOptions(d)}</select></td><td><select class="select kuma" data-key="${esc(d.key)}">${kumaOptions(d)}</select></td><td><label class="hide"><input type="checkbox" class="visible" data-key="${esc(d.key)}" ${d.hidden?'':'checked'}> Show</label></td><td><button class="btn reset" data-reset="${esc(d.key)}">Reset Auto</button></td></tr>`}).join('');
  const all=payload.devices; $('#total').textContent=all.length; $('#online').textContent=all.filter(x=>x.present).length; $('#classified').textContent=all.filter(x=>x.effective_group!=='unclassified'&&!x.hidden).length; $('#unclassified').textContent=all.filter(x=>x.effective_group==='unclassified'&&!x.hidden).length; $('#hidden').textContent=all.filter(x=>x.hidden).length;
  document.querySelectorAll('.device-name,.device-type,.group,.kuma,.visible').forEach(el=>el.addEventListener('change',saveRow)); document.querySelectorAll('[data-reset]').forEach(el=>el.addEventListener('click',resetRow));
}
function rowValues(key){const q=(c)=>document.querySelector(`${c}[data-key="${CSS.escape(key)}"]`);return {key,manual_name:q('.device-name')?.value||'',type:q('.device-type')?.value||'auto',group:q('.group')?.value||'auto',kuma_monitor:q('.kuma')?.value||'',hidden:!(q('.visible')?.checked??true)}}
async function saveRow(e){const key=e.target.dataset.key; $('#status').textContent='Saving…'; try{await api('/manage/device',{method:'POST',body:JSON.stringify(rowValues(key))});await load();$('#status').textContent='Saved';setTimeout(()=>$('#status').textContent='',1500)}catch(err){$('#status').textContent=`Save failed: ${err.message}`}}
async function resetRow(e){const key=e.currentTarget.dataset.reset;$('#status').textContent='Resetting…';try{await api('/manage/device/reset',{method:'POST',body:JSON.stringify({key})});await load();$('#status').textContent='Returned to automatic classification'}catch(err){$('#status').textContent=`Reset failed: ${err.message}`}}
async function load(){payload=await api('/public/discovery/devices');render()}
async function scan(){const b=$('#scan');b.disabled=true;b.textContent='↻ Scanning…';$('#status').textContent='Network scan started';try{const before=payload.last_scan;await api('/manage/scan',{method:'POST',body:'{}'});for(let i=0;i<90;i++){await new Promise(r=>setTimeout(r,2000));const s=await api('/public/discovery/summary');$('#status').textContent=s.scanning?'Scanning network…':`Found ${s.total} devices`;if(!s.scanning&&s.last_scan&&s.last_scan!==before)break}await load()}catch(err){$('#status').textContent=`Scan failed: ${err.message}`}finally{b.disabled=false;b.textContent='↻ Refresh Network'}}
$('#scan').addEventListener('click',scan);$('#search').addEventListener('input',render);$('#filter').addEventListener('change',render);load().catch(e=>$('#status').textContent=e.message);setInterval(()=>load().catch(()=>{}),15000);
})();
</script>
</body></html>
V37_HTML
chmod 0644 "$DEST"
DEST="$HOMEPAGE_DIR/config/custom.css"
cat >"$DEST" <<'V37_CSS'
/* Professional dark network-operations theme */

body {
  background:
    radial-gradient(circle at 15% 5%, rgba(20, 184, 166, 0.10), transparent 30%),
    radial-gradient(circle at 88% 12%, rgba(99, 102, 241, 0.11), transparent 32%),
    linear-gradient(145deg, #07111f 0%, #0b1220 45%, #090d17 100%) !important;
  background-attachment: fixed !important;
}

#page_container {
  max-width: 1680px !important;
  margin: 0 auto !important;
}

#pihole-card,
#unbound-card,
#uptime-card,
#tailscale-card,
#network-card,
#docker-card,
#ssh-card,
#discovery-card,
#system-card {
  border: 1px solid rgba(148, 163, 184, 0.12) !important;
  border-radius: 18px !important;
  background: linear-gradient(
    145deg,
    rgba(15, 23, 42, 0.88),
    rgba(17, 24, 39, 0.76)
  ) !important;
  box-shadow:
    0 18px 40px rgba(0, 0, 0, 0.23),
    inset 0 1px 0 rgba(255, 255, 255, 0.025) !important;
  transition:
    transform 160ms ease,
    border-color 160ms ease,
    box-shadow 160ms ease !important;
}

#pihole-card:hover,
#unbound-card:hover,
#uptime-card:hover,
#tailscale-card:hover,
#network-card:hover,
#docker-card:hover,
#ssh-card:hover,
#discovery-card:hover,
#system-card:hover {
  transform: translateY(-2px);
  border-color: rgba(45, 212, 191, 0.35) !important;
  box-shadow:
    0 22px 50px rgba(0, 0, 0, 0.30),
    0 0 0 1px rgba(45, 212, 191, 0.07) !important;
}

#pihole-card {
  border-top: 2px solid rgba(34, 197, 94, 0.65) !important;
}

#unbound-card {
  border-top: 2px solid rgba(56, 189, 248, 0.65) !important;
}

#uptime-card {
  border-top: 2px solid rgba(99, 102, 241, 0.70) !important;
}

#tailscale-card {
  border-top: 2px solid rgba(168, 85, 247, 0.70) !important;
}

#discovery-card {
  border-top: 2px solid rgba(245, 158, 11, 0.72) !important;
}

#system-card {
  border-top: 2px solid rgba(45, 212, 191, 0.65) !important;
}


.network-action-toolbar {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 0.55rem;
  min-height: 2.5rem;
  margin-top: 0.15rem;
  margin-bottom: 0.55rem;
  box-sizing: border-box;
}
.network-refresh-button,
.network-manage-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 2rem;
  padding: 0.38rem 0.72rem;
  border: 1px solid rgba(148, 163, 184, 0.20);
  border-radius: 9px;
  background: rgba(30, 41, 59, 0.72);
  color: rgb(203, 213, 225);
  font-size: 0.72rem;
  text-decoration: none;
  transition: border-color 140ms ease, background 140ms ease, transform 140ms ease;
}
.network-refresh-button { cursor: pointer; font: inherit; font-size: 0.72rem; }
.network-refresh-button:hover, .network-manage-button:hover { border-color: rgba(45, 212, 191, 0.50); background: rgba(15, 118, 110, 0.15); transform: translateY(-1px); }
.network-refresh-button:disabled { opacity: 0.58; cursor: wait; transform: none; }
.network-scan-message { color: rgb(100, 116, 139); font-size: 0.68rem; min-width: 8rem; }
@media (max-width: 680px) {
  .network-action-toolbar { justify-content: flex-start; flex-wrap: wrap; }
  .network-scan-message { flex-basis: 100%; }
}

#kuma-monitored-devices {
  margin-top: 1.2rem;
  margin-bottom: 1.25rem;
}

.kuma-device-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  align-items: start;
  gap: 0.75rem;
}

.kuma-device-card {
  min-width: 0;
  overflow: hidden;
  border: 1px solid rgba(148, 163, 184, 0.12);
  border-radius: 18px;
  background: linear-gradient(145deg, rgba(15, 23, 42, 0.88), rgba(17, 24, 39, 0.76));
  box-shadow: 0 18px 40px rgba(0, 0, 0, 0.23), inset 0 1px 0 rgba(255, 255, 255, 0.025);
  transition: transform 160ms ease, border-color 160ms ease, box-shadow 160ms ease;
}

.kuma-device-card:hover {
  transform: translateY(-2px);
  border-color: rgba(45, 212, 191, 0.32);
  box-shadow: 0 22px 50px rgba(0, 0, 0, 0.28), 0 0 0 1px rgba(45, 212, 191, 0.05);
}

.kuma-device-card[data-kuma-group="infrastructure"] { border-top: 2px solid rgba(45, 212, 191, 0.72); }
.kuma-device-card[data-kuma-group="storage"]        { border-top: 2px solid rgba(56, 189, 248, 0.72); }
.kuma-device-card[data-kuma-group="smart-home"]     { border-top: 2px solid rgba(168, 85, 247, 0.74); }
.kuma-device-card[data-kuma-group="security"]       { border-top: 2px solid rgba(248, 113, 113, 0.70); }
.kuma-device-card[data-kuma-group="services"]       { border-top: 2px solid rgba(99, 102, 241, 0.76); }
.kuma-device-card[data-kuma-group="websites"]       { border-top: 2px solid rgba(34, 197, 94, 0.70); }
.kuma-device-card[data-kuma-group="other"]          { border-top: 2px solid rgba(251, 191, 36, 0.68); }
.kuma-device-card[data-kuma-group="unclassified"]   { border-top: 2px solid rgba(100, 116, 139, 0.72); }

.kuma-device-card-header {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  min-height: 3rem;
  padding: 0.72rem 0.82rem 0.62rem;
  border-bottom: 1px solid rgba(148, 163, 184, 0.10);
}

.kuma-group-icon,
.kuma-device-type-icon,
.kuma-device-status-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
}

.kuma-group-icon,
.kuma-device-type-icon { color: rgb(203, 213, 225); }
.kuma-group-icon svg { width: 1.15rem; height: 1.15rem; }
.kuma-device-type-icon svg { width: 1rem; height: 1rem; }
.kuma-device-status-icon svg { width: 1rem; height: 1rem; }

.kuma-group-title {
  min-width: 0;
  flex: 1 1 auto;
  color: rgb(226, 232, 240);
  font-size: 0.88rem;
  font-weight: 500;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kuma-group-count { color: rgb(100, 116, 139); font-size: 0.68rem; }
.kuma-device-list { display: flex; flex-direction: column; }

.kuma-device-row {
  display: grid;
  grid-template-columns: 1.2rem minmax(0, 1fr) auto 1.15rem;
  align-items: center;
  gap: 0.5rem;
  min-height: 2.45rem;
  padding: 0.45rem 0.78rem;
  color: inherit;
  text-decoration: none;
  border-bottom: 1px solid rgba(148, 163, 184, 0.08);
  transition: background 140ms ease, transform 140ms ease;
}

.kuma-device-row:last-child { border-bottom: 0; }
.kuma-device-row:hover { background: rgba(51, 65, 85, 0.34); transform: translateX(1px); }
.kuma-device-copy { min-width: 0; }

.kuma-device-name {
  display: block;
  color: rgb(203, 213, 225);
  font-size: 0.79rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kuma-device-uptime { display: block; margin-top: 0.05rem; color: rgb(100, 116, 139); font-size: 0.62rem; }
.kuma-device-latency { min-width: 2.9rem; text-align: right; color: rgb(148, 163, 184); font-size: 0.7rem; font-variant-numeric: tabular-nums; }
.kuma-status-up { color: rgb(16, 185, 129); }
.kuma-status-down { color: rgb(248, 113, 113); }
.kuma-status-pending { color: rgb(251, 191, 36); }
.kuma-status-maintenance { color: rgb(148, 163, 184); }
.kuma-status-unknown { color: rgb(100, 116, 139); }
.kuma-device-unclassified .kuma-device-type-icon { color: rgb(100, 116, 139); }

.kuma-summary-strip { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.35rem; margin-top: 0.5rem; }
.kuma-summary-cell { padding: 0.28rem 0.4rem; border-radius: 6px; background: rgba(15, 23, 42, 0.40); text-align: center; }
.kuma-summary-value { display: block; color: rgb(203, 213, 225); font-size: 0.72rem; }
.kuma-summary-label { display: block; margin-top: 0.08rem; color: rgb(100, 116, 139); font-size: 0.53rem; text-transform: uppercase; letter-spacing: 0.04em; }
.kuma-summary-down .kuma-summary-value,
.kuma-summary-down .kuma-summary-label { color: rgb(248, 113, 113); }

@media (max-width: 1180px) {
  .kuma-device-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 680px) {
  .kuma-device-grid { grid-template-columns: minmax(0, 1fr); }
}
V37_CSS
chmod 0644 "$DEST"
DEST="$HOMEPAGE_DIR/config/custom.js"
cat >"$DEST" <<'V37_JS'
/* Automatic-discovery device dashboard. Generated by pi4_home_network_stack_v3_8_1.sh. */
(() => {
  'use strict';

  const API_PORT = __STATUS_API_PORT__;
  const REFRESH_MS = 10000;
  const SECTION_ID = 'kuma-monitored-devices';
  const ACTION_ROW_ID = 'network-action-row';
  const API_BASE = `${window.location.protocol}//${window.location.hostname}:${API_PORT}`;

  const DEVICE_SVGS = {
    'access-point': '<path d="M4 9a12 12 0 0 1 16 0"/><path d="M7 12a8 8 0 0 1 10 0"/><path d="M10 15a4 4 0 0 1 4 0"/><circle cx="12" cy="18" r="1"/>',
    router: '<rect x="3" y="9" width="18" height="9" rx="2"/><path d="M7 9V5m10 4V5"/><circle cx="8" cy="13.5" r=".8"/><circle cx="11" cy="13.5" r=".8"/><path d="M15 14h3"/>',
    modem: '<rect x="4" y="5" width="16" height="14" rx="2"/><path d="M7 9h10M7 13h4"/><circle cx="16" cy="13" r="1"/>',
    switch: '<rect x="3" y="6" width="18" height="12" rx="2"/><rect x="6" y="10" width="2" height="2"/><rect x="10" y="10" width="2" height="2"/><rect x="14" y="10" width="2" height="2"/><path d="M6 15h12"/>',
    'network-device': '<circle cx="6" cy="12" r="2"/><circle cx="18" cy="7" r="2"/><circle cx="18" cy="17" r="2"/><path d="M8 12h5m1-1l2.5-2.5M14 13l2.5 2.5"/>',
    nas: '<ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/>',
    storage: '<ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/>',
    server: '<rect x="4" y="3" width="16" height="6" rx="1.5"/><rect x="4" y="10" width="16" height="6" rx="1.5"/><rect x="4" y="17" width="16" height="4" rx="1.5"/><circle cx="7" cy="6" r=".7"/><circle cx="7" cy="13" r=".7"/><circle cx="7" cy="19" r=".7"/>',
    'raspberry-pi': '<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 2v3m6-3v3M9 19v3m6-3v3M2 9h3m-3 6h3m14-6h3m-3 6h3"/><circle cx="12" cy="12" r="3"/>',
    printer: '<path d="M7 8V3h10v5"/><rect x="4" y="8" width="16" height="9" rx="2"/><path d="M7 14h10v7H7z"/><circle cx="17" cy="11" r=".7"/>',
    camera: '<rect x="3" y="7" width="18" height="12" rx="2"/><path d="M8 7l1.5-3h5L16 7"/><circle cx="12" cy="13" r="3.5"/>',
    nvr: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8" cy="12" r="2.5"/><path d="M13 9h5m-5 3h5m-5 3h3"/>',
    security: '<path d="M12 3l7 3v5c0 4.5-2.7 8-7 10-4.3-2-7-5.5-7-10V6l7-3z"/><path d="M9 12l2 2 4-5"/>',
    dns: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/>',
    website: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/>',
    service: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
    'smart-home': '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/><circle cx="12" cy="14" r="2"/>',
    iot: '<rect x="6" y="6" width="12" height="12" rx="3"/><path d="M9 2v4m6-4v4M9 18v4m6-4v4M2 9h4m-4 6h4m12-6h4m-4 6h4"/><circle cx="12" cy="12" r="2"/>',
    sensor: '<path d="M12 3v10"/><circle cx="12" cy="17" r="4"/><path d="M8 6a6 6 0 0 0 0 8m8-8a6 6 0 0 1 0 8"/>',
    bridge: '<path d="M3 17h18M5 17V9m14 8V9M5 11h14M8 11V7m8 4V7M8 7h8"/>',
    tv: '<rect x="3" y="5" width="18" height="13" rx="2"/><path d="M8 22h8M12 18v4"/>',
    speaker: '<rect x="6" y="3" width="12" height="18" rx="2"/><circle cx="12" cy="9" r="2"/><circle cx="12" cy="16" r="3"/>',
    other: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M8 12h8M12 8v8"/>',
  };

  const GROUP_ICONS = {
    infrastructure: 'switch',
    storage: 'nas',
    'smart-home': 'smart-home',
    security: 'security',
    services: 'service',
    websites: 'website',
    other: 'other',
    unclassified: 'other',
  };

  const STATUS_SVGS = {
    up: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.5 2.5L16.5 9"/>',
    down: '<circle cx="12" cy="12" r="9"/><path d="M9 9l6 6m0-6l-6 6"/>',
    pending: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    maintenance: '<circle cx="12" cy="12" r="9"/><path d="M10 9v6m4-6v6"/>',
    unknown: '<circle cx="12" cy="12" r="9"/><path d="M9.7 9a2.5 2.5 0 1 1 3.2 2.4c-.8.3-.9.9-.9 1.6"/><circle cx="12" cy="16.5" r=".6"/>',
  };

  function statusIconKey(status) { return ({ 0: 'down', 1: 'up', 2: 'pending', 3: 'maintenance' })[Number(status)] ?? 'unknown'; }
  function deviceIconKey(type) { return Object.hasOwn(DEVICE_SVGS, type) ? type : 'other'; }
  function safeText(value) { return String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;'); }
  function svgIcon(markup) { return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${markup}</svg>`; }

  function formatLatency(monitor) {
    if (monitor.status === 0) return 'DOWN';
    if (monitor.status === 3) return 'MAINT';
    if (monitor.latency_ms === null || monitor.latency_ms === undefined) {
      if (monitor.source === 'discovery' && monitor.ip) return monitor.ip;
      return monitor.status_label || 'Unknown';
    }
    return `${monitor.latency_ms} ms`;
  }

  function ipv4SortKey(value) {
    const parts = String(value || '').split('.');
    if (parts.length !== 4 || parts.some((part) => !/^\d+$/.test(part) || Number(part) > 255)) return [1, 0];
    return [0, parts.reduce((total, part) => (total * 256) + Number(part), 0)];
  }

  function compareByIp(a, b) {
    const left = ipv4SortKey(a?.ip);
    const right = ipv4SortKey(b?.ip);
    return (left[0] - right[0]) || (left[1] - right[1]) || String(a?.name || '').localeCompare(String(b?.name || ''));
  }

  function formatUptime(value) {
    if (value === null || value === undefined) return '';
    const number = Number(value);
    if (!Number.isFinite(number)) return '';
    return `${number.toFixed(number >= 99.995 ? 2 : 1)}% / 24h`;
  }

  function groupCard(group) {
    const groupIcon = GROUP_ICONS[group.key] || 'other';
    const rows = [...(group.monitors || [])].sort(compareByIp).map((monitor) => {
      const deviceKey = deviceIconKey(monitor.device_type);
      const statusKey = statusIconKey(monitor.status);
      const className = monitor.classified ? '' : ' kuma-device-unclassified';
      const uptime = formatUptime(monitor.uptime_24);
      const title = monitor.classified ? `${monitor.device_type} / ${monitor.group}` : 'Unclassified: use pi-device-inventory to assign type/group';
      const href = monitor.source === 'discovery' ? `${API_BASE}/devices#${encodeURIComponent(monitor.discovery_key || '')}` : monitor.href;
      return `
        <a class="kuma-device-row${className}" href="${safeText(href)}" target="_blank" rel="noopener noreferrer" title="${safeText(title)}">
          <span class="kuma-device-type-icon">${svgIcon(DEVICE_SVGS[deviceKey] || DEVICE_SVGS.other)}</span>
          <span class="kuma-device-copy">
            <span class="kuma-device-name">${safeText(monitor.name)}</span>
            ${uptime ? `<span class="kuma-device-uptime">${safeText(uptime)}</span>` : ''}
          </span>
          <span class="kuma-device-latency">${safeText(formatLatency(monitor))}</span>
          <span class="kuma-device-status-icon kuma-status-${statusKey}" title="${safeText(monitor.status_label || 'Unknown')}">${svgIcon(STATUS_SVGS[statusKey])}</span>
        </a>`;
    }).join('');

    return `
      <article class="kuma-device-card" data-kuma-group="${safeText(group.key)}">
        <header class="kuma-device-card-header">
          <span class="kuma-group-icon">${svgIcon(DEVICE_SVGS[groupIcon] || DEVICE_SVGS.other)}</span>
          <span class="kuma-group-title">${safeText(group.title)}</span>
          <span class="kuma-group-count">${Number(group.monitors?.length || 0)}</span>
        </header>
        <div class="kuma-device-list">${rows}</div>
      </article>`;
  }

  function findMountPoint() {
    const bookmarks = document.querySelector('#bookmarks');
    if (bookmarks?.parentElement) return { parent: bookmarks.parentElement, before: bookmarks };
    const services = document.querySelector('#services');
    if (services?.parentElement) return { parent: services.parentElement, before: services.nextSibling };
    const page = document.querySelector('#page_container');
    return page ? { parent: page, before: null } : null;
  }

  // The dynamically inserted Kuma section is a sibling of Homepage's own
  // sections, not one of Homepage's generated service groups. Derive its
  // horizontal inset from an existing Homepage section so it follows the same
  // left/right gutters at every viewport width instead of bleeding to the edge.
  function alignKumaSection(section) {
    if (!section) return;
    const mount = findMountPoint();
    if (!mount?.parent) return;

    const reference = document.querySelector('#bookmarks') || document.querySelector('#services');
    if (!reference) return;

    const parentRect = mount.parent.getBoundingClientRect();
    const referenceRect = reference.getBoundingClientRect();
    const leftInset = Math.max(0, Math.round(referenceRect.left - parentRect.left));
    const rightInset = Math.max(0, Math.round(parentRect.right - referenceRect.right));

    section.style.marginLeft = `${leftInset}px`;
    section.style.marginRight = `${rightInset}px`;
    section.style.width = 'auto';
    section.style.boxSizing = 'border-box';
  }

  function ensureSection() {
    let section = document.getElementById(SECTION_ID);
    if (section) {
      alignKumaSection(section);
      return section;
    }
    const mount = findMountPoint();
    if (!mount) return null;
    section = document.createElement('section');
    section.id = SECTION_ID;
    section.innerHTML = '<div class="kuma-device-grid"></div>';
    mount.parent.insertBefore(section, mount.before);
    alignKumaSection(section);
    window.requestAnimationFrame(() => alignKumaSection(section));
    return section;
  }

  function renderPayload(payload) {
    const section = ensureSection();
    if (!section) return;
    const grid = section.querySelector('.kuma-device-grid');
    if (!payload || payload.configured === false) {
      grid.innerHTML = '<article class="kuma-device-card" data-kuma-group="unclassified"><div class="kuma-device-card-header"><span class="kuma-group-title">Uptime Kuma status page unavailable</span></div></article>';
      return;
    }
    const groups = payload.groups || [];
    grid.innerHTML = groups.length ? groups.map(groupCard).join('') : '';
  }

  function updateKumaSummary(summary) {
    const card = document.getElementById('uptime-card');
    if (!card || !summary) return;
    let strip = card.querySelector('.kuma-summary-strip');
    if (!strip) { strip = document.createElement('div'); strip.className = 'kuma-summary-strip'; card.appendChild(strip); }
    strip.innerHTML = `
      <span class="kuma-summary-cell"><strong class="kuma-summary-value">${Number(summary.up || 0)}</strong><small class="kuma-summary-label">UP</small></span>
      <span class="kuma-summary-cell"><strong class="kuma-summary-value">${Number(summary.total || 0)}</strong><small class="kuma-summary-label">MONITORS</small></span>
      <span class="kuma-summary-cell ${Number(summary.down || 0) ? 'kuma-summary-down' : ''}"><strong class="kuma-summary-value">${Number(summary.down || 0)}</strong><small class="kuma-summary-label">DOWN</small></span>
      <span class="kuma-summary-cell"><strong class="kuma-summary-value">${Number(summary.maintenance || 0)}</strong><small class="kuma-summary-label">MAINT</small></span>`;
  }

  function alignActionRow(row) {
    if (!row) return;
    const mount = findMountPoint();
    const reference = document.querySelector('#services') || document.querySelector('#bookmarks');
    if (!mount?.parent || !reference) return;
    const parentRect = mount.parent.getBoundingClientRect();
    const referenceRect = reference.getBoundingClientRect();
    row.style.marginLeft = `${Math.max(0, Math.round(referenceRect.left - parentRect.left))}px`;
    row.style.marginRight = `${Math.max(0, Math.round(parentRect.right - referenceRect.right))}px`;
  }

  function ensureNetworkToolbar() {
    let row = document.getElementById(ACTION_ROW_ID);
    if (row) { alignActionRow(row); return row; }
    const services = document.querySelector('#services');
    if (!services?.parentElement) return null;
    row = document.createElement('div');
    row.id = ACTION_ROW_ID;
    row.className = 'network-action-toolbar';
    row.innerHTML = `
      <a class="network-manage-button" href="${API_BASE}/devices" target="_blank" rel="noopener noreferrer">Manage Devices</a>
      <button class="network-refresh-button" type="button">↻ Refresh Network</button>
      <span class="network-scan-message" aria-live="polite"></span>`;
    services.parentElement.insertBefore(row, services);
    alignActionRow(row);
    row.querySelector('.network-refresh-button')?.addEventListener('click', refreshNetwork);
    return row;
  }

  async function discoverySummary() {
    const response = await fetch(`${API_BASE}/public/discovery/summary`, { cache: 'no-store' });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
    return payload;
  }

  async function refreshNetwork() {
    const row = ensureNetworkToolbar();
    const button = row?.querySelector('.network-refresh-button');
    const message = row?.querySelector('.network-scan-message');
    if (!button) return;
    button.disabled = true;
    button.textContent = '↻ Scanning…';
    try {
      const before = await discoverySummary().catch(() => ({ last_scan: null }));
      const response = await fetch(`${API_BASE}/manage/scan`, {
        method: 'POST',
        cache: 'no-store',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      });
      const started = await response.json();
      if (!response.ok) throw new Error(started.error || `HTTP ${response.status}`);
      if (message) message.textContent = 'Scanning LAN…';
      for (let i = 0; i < 90; i += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, 2000));
        const summary = await discoverySummary();
        if (message) message.textContent = summary.scanning ? 'Scanning LAN…' : `${summary.total} devices · ${summary.unclassified} unclassified`;
        if (!summary.scanning && summary.last_scan && summary.last_scan !== before.last_scan) break;
      }
      await refresh();
    } catch (error) {
      if (message) message.textContent = `Scan failed: ${error.message}`;
    } finally {
      button.disabled = false;
      button.textContent = '↻ Refresh Network';
      window.setTimeout(() => { if (message) message.textContent = ''; }, 5000);
    }
  }

  async function refresh() {
    const section = ensureSection();
    if (!section) return;
    try {
      const endpoint = `${API_BASE}/public/devices/groups`;
      const response = await fetch(endpoint, { cache: 'no-store' });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
      renderPayload(payload);
      updateKumaSummary(payload.kuma_summary || payload.summary);
    } catch (_error) {
      const grid = section.querySelector('.kuma-device-grid');
      if (grid) grid.innerHTML = '<article class="kuma-device-card" data-kuma-group="unclassified"><div class="kuma-device-card-header"><span class="kuma-group-title">Kuma monitor data unavailable</span></div></article>';
    }
  }

  const observer = new MutationObserver(() => { ensureSection(); ensureNetworkToolbar(); });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('resize', () => { alignKumaSection(document.getElementById(SECTION_ID)); alignActionRow(document.getElementById(ACTION_ROW_ID)); }, { passive: true });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { ensureNetworkToolbar(); refresh(); }, { once: true }); else { ensureNetworkToolbar(); refresh(); }
  window.setInterval(refresh, REFRESH_MS);
})();
V37_JS
STATUS_API_PORT=$(awk -F= '$1=="STATUS_API_PORT" {print $2}' "$DEFAULTS" | tail -1 | tr -d '"' || true)
STATUS_API_PORT=${STATUS_API_PORT:-9108}
sed -i "s|__STATUS_API_PORT__|${STATUS_API_PORT}|g" "$HOMEPAGE_DIR/config/custom.js"
chmod 0644 "$HOMEPAGE_DIR/config/custom.js"

# Update only the Network Discovery card in services.yaml.
python3 - "$HOMEPAGE_DIR/config/services.yaml" <<'PYSVC'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines(); out=[]; active=False
for line in lines:
    if line.startswith('    - Network Discovery:'):
        active=True
    elif active and line.startswith('- System:'):
        active=False
    if active:
        line=line.replace('description: Safe LAN discovery; approval required before classification','description: Automatic conservative discovery with persistent manual overrides')
        if line.strip() == '- field: new': line=line.replace('new','classified')
        elif line.strip() == 'label: New': line=line.replace('New','Grouped')
        elif line.strip() == '- field: review': line=line.replace('review','unclassified')
        elif line.strip() == 'label: Review': line=line.replace('Review','Unclassified')
        elif line.strip() == 'label: Scan': line=line.replace('Scan','Status')
    out.append(line)
p.write_text('
'.join(out)+'
')
PYSVC

# Add Modem IP to the existing Network card. The value is shown only when a
# discovered device is explicitly/effectively classified as type=modem.
python3 - "$HOMEPAGE_DIR/config/services.yaml" <<'PYMODEM'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines(); out=[]; in_network=False; inserted=False
for i,line in enumerate(lines):
    if line.startswith('    - Network:'):
        in_network=True
    elif in_network and line.startswith('    - ') and not line.startswith('    - Network:'):
        in_network=False
    out.append(line)
    if in_network and line.strip() == 'label: Pi IP' and not inserted:
        out.extend(['            - field: modem_ip','              label: Modem IP'])
        inserted=True
p.write_text('\n'.join(out)+'\n')
PYMODEM

# Preserve current secrets/settings and add the v3.8.1 state paths idempotently.
python3 - "$DEFAULTS" <<'PYENV'
import ipaddress, pathlib, subprocess, sys
p=pathlib.Path(sys.argv[1]); data={}; order=[]
for line in p.read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k,v=line.split('=',1); k=k.strip(); data[k]=v; order.append(k)
def cmd(args): return subprocess.check_output(args,text=True).strip()
try:
    route=cmd(['ip','-4','route','show','default']).splitlines()[0].split(); iface=route[route.index('dev')+1]
    addr=cmd(['ip','-4','-o','addr','show','dev',iface,'scope','global']).splitlines()[0].split()[3]
    cidr=str(ipaddress.ip_interface(addr).network)
except Exception: cidr='192.168.0.0/24'
data.setdefault('LAN_CIDR',cidr); data.setdefault('DASHBOARD_PORT','3000')
data['DISCOVERY_STATE_FILE']='/var/lib/pi4-network-stack/network-discovery.json'
data['DEVICE_MANAGER_HTML']='/usr/local/share/pi-network-manager/devices.html'
seen=set(); out=[]
for k in order:
    if k not in seen: seen.add(k); out.append(f'{k}={data[k]}')
for k in ('LAN_CIDR','DASHBOARD_PORT','DISCOVERY_STATE_FILE','DEVICE_MANAGER_HTML'):
    if k not in seen: out.append(f'{k}={data[k]}')
p.write_text('
'.join(out)+'
')
PYENV

cat >/etc/systemd/system/pi-network-discovery.service <<'EOF'
[Unit]
Description=Automatic conservative local-network discovery for the home-network dashboard
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-network-discover scan
Nice=10
IOSchedulingClass=idle
EOF
cat >/etc/systemd/system/pi-network-discovery.timer <<'EOF'
[Unit]
Description=Run automatic LAN discovery daily
[Timer]
OnCalendar=*-*-* 02:20:00
Persistent=true
RandomizedDelaySec=10m
Unit=pi-network-discovery.service
[Install]
WantedBy=timers.target
EOF
cat >/etc/systemd/system/pi-network-status-api.service <<'EOF'
[Unit]
Description=Home-network telemetry and LAN device-management API
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=/etc/default/pi-network-status-api
ExecStart=/usr/local/sbin/pi-network-status-api.py
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run /var/lib/pi4-network-stack
RestrictSUIDSGID=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pi-network-discovery.timer >/dev/null
systemctl enable pi-network-status-api.service >/dev/null
systemctl restart pi-network-status-api.service
for i in $(seq 1 15); do curl -fsS "http://127.0.0.1:${STATUS_API_PORT}/public/discovery/devices" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:${STATUS_API_PORT}/public/discovery/devices" >/dev/null || { journalctl -u pi-network-status-api -n 50 --no-pager; exit 1; }
if docker inspect homepage >/dev/null 2>&1; then docker restart homepage >/dev/null; fi
systemctl start --no-block pi-network-discovery.service || true
TARGET_IP=$(awk -F= '$1=="TARGET_IP" {print $2}' "$DEFAULTS" | tail -1 | tr -d '"' || true); TARGET_IP=${TARGET_IP:-192.168.0.10}
DASHBOARD_PORT=$(awk -F= '$1=="DASHBOARD_PORT" {print $2}' "$DEFAULTS" | tail -1 | tr -d '"' || true); DASHBOARD_PORT=${DASHBOARD_PORT:-3000}
echo
echo "v3.8 numeric IP sorting + persistent device renaming installed."
echo "Dashboard:      http://${TARGET_IP}:${DASHBOARD_PORT}/"
echo "Device manager: http://${TARGET_IP}:${STATUS_API_PORT}/devices"
echo "Backup:         $BACKUP"
echo "Hard-refresh the dashboard in your browser."
