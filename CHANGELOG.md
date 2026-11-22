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
- `docs/04-scan-results.md`: unauthenticated before vs after comparison, authenticated scan setup (scan account, GVM credential and target), authenticated "before" findings with decisions, gotchas, lab vs production notes
- `docs/04-scan-results.md`: configuration check clean vs hardened, gaps found (Print Spooler, Kerberos Service Ticket Operations audit, LSA protection not active)
- `docs/02-hardening.md`: lab GPO to disable Print Spooler on DCs
- `scripts/Get-HardeningState.ps1`: read-only config check of the settings the baseline changes, for before/after comparison

### Changed
- `scripts/Get-HardeningState.ps1` 1.1: Server 2025 targets for LDAP signing and WDigest, LSA protection reads `RunAsPPLBoot` and checks LSASS live, audit settings accept "Success and Failure" where the target is "Success"
- README: config check and Print Spooler status, `Hardened DC v2` checkpoint
- README: scripts section, config check status
- `docs/04-scan-results.md`: authenticated "after" results (same as "before"), Snipping Tool finding confirmed as a false positive with a GVM override
- README: authenticated scan status, `scan ready` checkpoints
- `docs/03-scanner.md`: status
- README: phase 1 status, VM memory sizing for a 16 GB host
- `docs/03-scanner.md`: more gotchas (feed lock after reboot, password reset, hostname, checkpoint memory), status
