# hybrid-hardening-lab

A Windows Server 2025 domain controller built in a Hyper-V home lab, hardened with the Microsoft Security Baseline, and scanned before and after with Greenbone (OpenVAS). Later phases sync it to an Entra ID lab tenant to test IAM automation in a hybrid setup.

## Scope

- **Build:** Server 2025 DC (`hawkode.lab`) on Hyper-V
- **Harden:** Microsoft Security Baseline for Windows Server 2025 (v2602)
- **Measure:** Greenbone Community Edition scans of the clean DC and the hardened DC
- **Hybrid:** Entra Connect sync to a lab tenant, then joiner/mover/leaver tests with [entra-iam-automation](https://github.com/Hawkode/entra-iam-automation)

Only free tools: Hyper-V, Windows Server 2025 evaluation, Kali Linux, Greenbone Community Edition.

## Status

| Phase | Work | Status | Tested in |
|---|---|---|---|
| 1 | DC01 build | Done | Lab |
| 1 | Baseline hardening | Done | Lab |
| 1 | Scanner VM (Kali + GVM) | Done | Lab |
| 1 | Unauthenticated scan, after (hardened) | Done | Lab |
| 1 | Unauthenticated scan, before (clean) | Done | Lab |
| 1 | Authenticated scan, before (clean) | Done | Lab |
| 1 | Authenticated scan, after (hardened) | Done | Lab |
| 1 | Config check (`Get-HardeningState.ps1`), clean vs hardened | Done | Lab |
| 1 | Print Spooler off on DC (GPO) | Done | Lab |
| 1 | Authenticated scan, after v2 (Print Spooler off) | Done | Lab |
| 1 | Scan write-up and comparison | Done | Lab |
| 2 | Entra Connect install, scoped to `Lab Users` | Done | Lab |
| 2 | Password hash sync test sign-in | Done | Lab |
| 2 | AD Recycle Bin enabled | Done | Lab |
| 3 | Prep: what the hybrid scripts need | Done | Lab |
| 3 | Joiner (`New-HybridJoiner.ps1`) | Done | Lab |
| 3 | Mover (`Move-HybridUser.ps1`) | Planned | - |
| 3 | Leaver (`Disable-HybridLeaver.ps1`) | Planned | - |
| 3 | Source of authority: Graph edit on a synced user | Planned | - |
| 3 | AD Recycle Bin restore | Planned | - |

## Lab layout

| VM | Role | OS | vCPU | RAM | Disk | IP |
|---|---|---|---|---|---|---|
| DC01 | Domain controller, DNS, Entra Connect | Windows Server 2025 (evaluation) | 2 | 2 GB fixed (4 GB in phase 2) | 60 GB | 192.0.2.10 |
| KALI01 | Scanner, later attacker | Kali Linux (rolling) | 2 | 3-4 GB fixed | 60 GB | DHCP |

- Both VMs are Generation 2 on a Hyper-V External switch.
- The host has 16 GB. Both VMs only fit together with DC01 on 2 GB and Kali on 3-4 GB. In phase 2 Kali is off and DC01 gets 4 GB for Entra Connect.
- IPs in these docs use the `192.0.2.0/24` documentation range, not the real lab range.

## Docs

1. [Build the DC](docs/01-build-dc.md)
2. [Harden the DC](docs/02-hardening.md)
3. [Build the scanner](docs/03-scanner.md)
4. [Scan results](docs/04-scan-results.md)
5. [Sync to Entra ID](docs/05-entra-connect.md)
6. [Hybrid joiner, mover, leaver tests](docs/06-hybrid-jml.md)

## Scripts

| Script | Runs on | What it does |
|---|---|---|
| [`Get-HardeningState.ps1`](scripts/Get-HardeningState.ps1) | DC01, elevated, Windows PowerShell 5.1 or 7 | Read-only. Shows the settings the baseline changes (SMB, LDAP, NTLM, WDigest, UAC, LSA, logging, audit policy, firewall, Print Spooler) against their targets. Run it on each checkpoint for a before/after table. |

## Checkpoints

| VM | Checkpoint | State |
|---|---|---|
| DC01 | `Clean DC` | Promoted DC, DNS forwarders, no hardening |
| DC01 | `Hardened DC` | Baseline applied, rebooted, verified |
| DC01 | `Clean DC - scan ready` | `Clean DC` plus the `svc-scan` account for authenticated scans |
| DC01 | `Hardened DC - scan ready` | `Hardened DC` plus the `svc-scan` account for authenticated scans |
| DC01 | `Hardened DC v2` | `Hardened DC - scan ready` plus the Print Spooler GPO |
| DC01 | `Pre-sync` | `Hardened DC v2` minus `svc-scan` |
| DC01 | `Pre-Entra Connect` | `Pre-sync` plus `Lab Users` OU, 4 test users, installer copied |
| DC01 | `Post-sync` | Entra Connect installed and syncing `Lab Users`, AD Recycle Bin on |
| DC01 | `Pre-JML` | `Post-sync` before the phase 3 setup (UPN suffix, OUs, Graph modules, PowerShell 7) |
| KALI01 | `Clean Kali` | Installed and updated, before GVM |

The scans compare the clean state (before) with the hardened state (after). Authenticated scans use the `scan ready` checkpoints.

## Lab vs production

- Entra Connect runs on DC01 to save RAM. In production it belongs on a dedicated member server, treated as Tier 0.
- Reverting a DC checkpoint is safe here because there is one DC. In a multi-DC domain it causes USN rollback.
- The evaluation licence lasts 180 days. This lab is built to be rebuilt.
