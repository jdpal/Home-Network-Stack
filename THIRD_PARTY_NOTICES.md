# Third-Party Notices

Pi 4 Home Network Stack is licensed separately under the Apache License 2.0.
That licence applies to the original code, scripts, configuration generation,
dashboard integration, discovery logic, and documentation in this repository.

This project installs, configures, invokes, or integrates with third-party
software. Those projects are **not relicensed** by this repository. Each
third-party component remains governed by its own licence, copyright notices,
terms, and trademark rules.

This notice is informational and is not a substitute for the upstream licence
text shipped by each project or package.

## Major integrated projects

| Project | Role in this stack | Upstream licence |
|---|---|---|
| Pi-hole | DNS filtering and FTL integration | EUPL-1.2 |
| Unbound | Recursive DNS resolver | BSD-3-Clause |
| Uptime Kuma | Service and device monitoring | MIT |
| Tailscale open-source client/daemon | Remote access and subnet routing | BSD-3-Clause |
| Homepage | Operations dashboard | GPL-3.0 |
| Moby / Docker Engine components | Container runtime foundation | Apache-2.0 |
| Docker CLI | Container command-line client | Apache-2.0 |
| Docker Compose | Multi-container orchestration | Apache-2.0 |

## Operating-system and package dependencies

The installer also uses packages supplied by Raspberry Pi OS, Debian, Docker's
package repositories, and other upstream package repositories. Examples include
OpenSSH, cron, NetworkManager tooling, Python, curl, Avahi, arp-scan, bind9
utilities, jq, and supporting libraries.

Those packages can contain code under many different licences. Their upstream
or distribution package metadata remains authoritative. This repository does
not redistribute or relicense those packages merely by installing or invoking
them.

## Docker images

The stack can pull and run third-party container images, including:

- `louislam/uptime-kuma`
- `ghcr.io/gethomepage/homepage`

The software inside those images remains subject to the upstream project's
licence and any licences for bundled dependencies.

## Trademarks and project names

Names such as Pi-hole, Uptime Kuma, Tailscale, Homepage, Docker, Raspberry Pi,
Unbound, and related logos or marks belong to their respective owners.

References in this repository are descriptive and identify interoperability or
software installed/configured by the project. No affiliation, sponsorship, or
endorsement is implied.

## Modifications and redistribution

If you modify or redistribute third-party source code itself, rather than merely
installing or configuring an independently distributed package, you are
responsible for complying with the applicable upstream licence.

In particular, copyleft-licensed components such as Pi-hole and Homepage have
redistribution obligations that are distinct from this repository's
Apache-2.0 licence.

## Verification

Licences listed here were checked against the respective upstream project
repositories when this file was prepared. Upstream projects may change their
licensing over time. Before redistributing third-party software, verify the
licence terms of the exact version you are distributing.
