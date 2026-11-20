# 04 - Scan results

Greenbone (OpenVAS) scans of DC01 before and after the Microsoft Security Baseline.

## Method

| Setting | Value |
|---|---|
| Scanner | OSPd OpenVAS 22.10.6 on KALI01 |
| Feed | Greenbone Community Feed, NVT version 20261119T0552 |
| Scan config | Full and fast |
| Port list | All IANA assigned TCP |
| Alive test | Consider Alive (the hardened firewall blocks ping) |
| Credentials | None (unauthenticated) |
| Report filter | Default: Critical, High, Medium, Low; QoD (quality of detection) 70 and above |
| Target | DC01, `192.0.2.10` |

Both scans use the same target and config. Only the DC01 checkpoint changes: `Hardened DC` for "after", `Clean DC` for "before".

## Results

| Scan | Date | Duration | Critical | High | Medium | Low | Log |
|---|---|---|---|---|---|---|---|
| After (hardened) | 20 Nov 2026 | 21 min | 0 | 0 | 1 | 1 | 22 |
| Before (clean) | 20 Nov 2026 | Pending | - | - | - | - | - |

Log entries are information only: open ports, OS and service detection.

## After (hardened): findings

| Finding | CVSS | Port | What it means | Decision |
|---|---|---|---|---|
| DCE/RPC and MSRPC Services Enumeration Reporting | 5.0 Medium | 135/tcp | Anyone on the network can list the DC's RPC services | Accept. A DC needs RPC to work. Greenbone downgrades it to Log if the network type is set to Private LAN. |
| TCP Timestamps Information Disclosure | 2.6 Low | - | The host's uptime can be estimated | Accept. Windows can't fully turn timestamps off. |

## Gap found: Print Spooler on the DC

The RPC enumeration lists `spoolsv.exe` (Print Spooler) listening on the hardened DC. The Microsoft baseline doesn't stop it.

- Risk: Print Spooler on a DC is the PrintNightmare path, and the "PrinterBug" lets any domain user force the DC to authenticate to a host they control (MITRE ATT&CK T1187, Forced Authentication).
- Fix: disable the Print Spooler service on DCs by GPO, then rescan as "after v2".
- The fix waits until both scans are done, so the before/after comparison stays baseline vs no baseline.

The same list shows the `MS NT Directory DRS Interface`. That's normal for a DC: it's how DCs replicate. It's also the interface a DCSync attack abuses, so it goes into the Attack phase.

## Limits of an unauthenticated scan

- It sees DC01 the way any host on the network does: ports, services, protocol settings.
- Most baseline changes live inside Windows (audit policy, user rights, NTLM settings, WDigest). An unauthenticated scan can't see them, so expect a modest drop between before and after.
- An authenticated scan (GVM logs in over SMB with a domain account) comes next, to measure those.

## Next

- Before (clean) scan, then fill in the results table
- Disable Print Spooler by GPO, rescan as after v2
- Authenticated before/after scans
