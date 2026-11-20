# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- README with scope, phase status, lab layout and checkpoints
- `docs/01-build-dc.md`: Server 2025 DC build, static IP, forest promotion, DNS forwarders
- `docs/02-hardening.md`: Microsoft Security Baseline v2602 import, GPO links, what it changes, verification
- `docs/03-scanner.md`: Kali VM build, GVM install, feed timings, gotchas
- `docs/04-scan-results.md`: scan method, unauthenticated "after" results, Print Spooler gap on the DC

### Changed
- README: phase 1 status, VM memory sizing for a 16 GB host
- `docs/03-scanner.md`: more gotchas (feed lock after reboot, password reset, hostname, checkpoint memory), status
