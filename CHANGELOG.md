# Changelog

## Unreleased

- Anchored the dashboard's Scan network control directly above the device-status cards
- Added the latest scan age and device count to the dashboard control bar
- Kept scan progress, failure reporting, responsive layout, and Device Manager access visible when Homepage has no services section
- Restricted browser management POSTs to matching loopback, LAN, or Tailscale IP origins on the configured dashboard or API port
- Required JSON management requests and stopped reflecting untrusted origins in writable API responses

## Repository licensing update

- Added Apache License 2.0 for this project's original code and documentation
- Added `THIRD_PARTY_NOTICES.md` to distinguish upstream component licences
- Documented that third-party products are not relicensed by this repository

This repository packages the current home-network appliance installer as v3.8.1.

## v3.8.1

- Added deterministic local Raspberry Pi record to network discovery
- Added explicit `modem` device type and modem-IP display
- Preserved custom names and manual classifications across scans
- Kept numeric IPv4 sorting
- Kept automatic conservative device discovery and Device Manager
- Kept manual grouping and custom device naming independent from hostname-based inference

## v3.8

- Added persistent custom device names
- Added numeric IPv4 ascending sort across dashboard and Device Manager
- Preserved manual naming through network rescans

## v3.7

- Added automatic network discovery
- Added Device Manager web page
- Added manual dropdown reclassification and persistent overrides
- Added Refresh Network workflow
- Prohibited device-type inference from hostname/display-name text

## v3.6.x

- Added LAN discovery tooling and discovery dashboard status
- Fixed dynamic Kuma dashboard alignment with Homepage page gutters

## v3.5

- Added explicit local device inventory for deterministic dashboard grouping
- Added Infrastructure, Storage & Servers, Smart Home & IoT, Cameras & Security, Services, Websites, Other Devices, and Unclassified groups

## v3.4

- Improved Kuma grouping and adaptive card layout
- Removed instructional placeholder text from the normal dashboard

## v3.3

- Added grouped Kuma monitor cards to Homepage
- Added independent device icons and status icons

## Earlier releases

Earlier iterations established:

- static-IP two-phase deployment
- Pi-hole
- Unbound
- automatic Unbound-to-Cloudflare failover
- Tailscale
- SSH resilience
- Uptime Kuma
- Homepage
- telemetry API
- scheduled maintenance
