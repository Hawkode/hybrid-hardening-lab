# 04 - Scan results

Greenbone (OpenVAS) scans of DC01 before and after the Microsoft Security Baseline: first unauthenticated, then authenticated over SMB.

## Method

| Setting | Value |
|---|---|
| Scanner | OSPd OpenVAS 22.10.6 on KALI01 |
| Feed | Greenbone Community Feed, NVT version 20261119T0552 |
| Scan config | Full and fast |
| Port list | All IANA assigned TCP |
| Alive test | Consider Alive (the hardened firewall blocks ping) |
| Report filter | Critical, High, Medium, Low; QoD (quality of detection) 70 and above |
| Target | DC01, `192.0.2.10` |

| Scan type | GVM target | Credentials |
|---|---|---|
| Unauthenticated | `DC01` | None |
| Authenticated | `DC01 - auth` | SMB (NTLM): domain account `svc-scan` |

Each pair uses the same target and config. Only the DC01 checkpoint changes.

| Scan | DC01 checkpoint |
|---|---|
| Unauthenticated before | `Clean DC` |
| Unauthenticated after | `Hardened DC` |
| Authenticated before | `Clean DC - scan ready` |
| Authenticated after | `Hardened DC - scan ready` |

## Results

| Scan | Date | Critical | High | Medium | Low |
|---|---|---|---|---|---|
| Unauthenticated after (hardened) | 20 Nov 2026 | 0 | 0 | 1 | 1 |
| Unauthenticated before (clean) | 20 Nov 2026 | 0 | 0 | 1 | 1 |
| Authenticated before (clean) | 21 Nov 2026 | 0 | 1 | 2 | 2 |
| Authenticated after (hardened) | 21 Nov 2026 | Running | - | - | - |

Log-level results (open ports, OS and service detection) are information only and left out.

## Unauthenticated: before vs after

Both scans returned the same two findings.

| Finding | CVSS | Port | Before | After | What it means | Decision |
|---|---|---|---|---|---|---|
| DCE/RPC and MSRPC Services Enumeration Reporting | 5.0 Medium | 135/tcp | Yes | Yes | Anyone on the network can list the DC's RPC services | Accept. A DC needs RPC to work. Greenbone downgrades it to Log if the network type is set to Private LAN. |
| TCP Timestamps Information Disclosure | 2.6 Low | - | Yes | Yes | The host's uptime can be estimated | Accept. Windows can't fully turn timestamps off. |

Small differences in the RPC endpoint list are noise, not hardening:

- RPC ports above 49664 are picked at random on each boot.
- `AppInfo` (the UAC elevation service) starts on demand, so its endpoints come and go. They appear in the hardened scan and in the authenticated clean scan.

### What this shows

- Server 2025 defaults already pass an unauthenticated scan. SMB signing, for example, is required out of the box.
- Most baseline changes live inside Windows (audit policy, user rights, NTLM settings, WDigest). An unauthenticated scan can't see them.
- So the baseline's value doesn't show up as fewer findings here. That needs an authenticated scan or a config check.

## Gap found: Print Spooler on the DC

The RPC enumeration lists `spoolsv.exe` (Print Spooler) listening on DC01, before and after hardening. The Microsoft baseline doesn't stop it.

- Risk: Print Spooler on a DC is the PrintNightmare path, and the "PrinterBug" lets any domain user force the DC to authenticate to a host they control (MITRE ATT&CK T1187, Forced Authentication).
- Fix: disable the Print Spooler service on DCs by GPO, then rescan as "after v2".
- The fix waits until all four scans are done, so the comparison stays baseline vs no baseline.

The same list shows the `MS NT Directory DRS Interface`. That's normal for a DC: it's how DCs replicate. It's also the interface a DCSync attack abuses, so it goes into the Attack phase.

## Authenticated scan setup

GVM logs in over SMB and reads files, registry and installed software directly.

### Scan account

A checkpoint revert also reverts AD, so the account is created in both states with the same password, then each state gets a new checkpoint.

```powershell
# DC01 > PowerShell (admin, elevated) - Windows PowerShell 5.1
$pw = Read-Host -AsSecureString 'svc-scan password'
New-ADUser -Name 'svc-scan' -SamAccountName 'svc-scan' -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true -Description 'GVM auth scan - lab only'
Add-ADGroupMember -Identity 'Administrators' -Members 'svc-scan'
Set-Service RemoteRegistry -StartupType Manual; Start-Service RemoteRegistry
```

- `Administrators` on a DC is the domain's built-in admin group, so this account is Tier 0.
- Remote Registry lets GVM read the registry over SMB.

Verify:

```powershell
Get-ADPrincipalGroupMembership svc-scan | Select-Object Name   # Administrators listed
Get-Service RemoteRegistry                                       # Running
```

`Hyper-V Manager > DC01 > Checkpoint > rename to Clean DC - scan ready` (or `Hardened DC - scan ready`)

### GVM

- `Configuration > Credentials > New > Username + Password > HAWKODE\svc-scan`
- `Configuration > Targets > New > DC01 - auth > 192.0.2.10 > SMB (NTLM): svc-scan`, same port list and alive test as `DC01`
- A new target is needed: GVM won't edit a target that a task already uses.

Proof the login worked: the results include local file checks (`C:\WINDOWS\system32\...`) that only run after a successful SMB login.

## Authenticated before (clean): findings

| Finding | CVSS | What GVM checked | Real risk | Decision |
|---|---|---|---|---|
| Windows IExpress Untrusted Search Path (CVE-2018-0598) | 7.8 High | `iexpress.exe` exists | Low. Only matters if someone runs a self-extracting archive from a folder an attacker can write to. | Accept. No patch, workaround only. Nobody builds or runs installers on the DC. |
| Windows HID Functionality (Over USB) Code Execution (CVE-2011-0638) | 6.9 Medium | `hidserv.dll` exists | Close to none on a VM. Needs a physical USB device plugged in. | Accept on the VM. On physical servers: USB device control. |
| DCE/RPC and MSRPC Services Enumeration Reporting | 5.0 Medium | Port 135 | Same as unauthenticated | Accept |
| Windows Snipping Tool Information Disclosure (CVE-2023-28303) | 3.3 Low | File version | Likely false positive. GVM compares the Windows build number (`10.0.26100.x`) with the Windows 11 Store app version (`11.2302.20.0`). | Investigate, then add a GVM override if confirmed |
| TCP Timestamps Information Disclosure | 2.6 Low | - | Same as unauthenticated | Accept |

The three findings logging in added are all file-presence or version checks. The baseline doesn't remove those files, so expect them in the hardened scan too.

## Gotchas

| Problem | Cause | Fix |
|---|---|---|
| `New-ADUser : Access is denied` on the hardened DC, same command fine on clean | Most likely the baseline turning on UAC Admin Approval Mode for the built-in Administrator, so a non-elevated window gets a filtered token | Run PowerShell as administrator. Check with `whoami /groups`: `High Mandatory Level` = elevated. |
| Wrong report downloaded | Every report from the same task looks alike in the list | Check the `Task Name` column inside the CSV before using it |
| `-AsSecureSting` (typo) stored the password as plain text | `Read-Host` treats unknown words as part of the prompt | Check the prompt shows `*****` while typing |
| Wrong checkpoint branch | `Checkpoint` clicked instead of `Apply`, creating a mislabelled checkpoint | Check `Now` sits under the expected checkpoint before scanning |
| DC01 times 8 hours behind | Server evaluation defaults to Pacific time | `Set-TimeZone -Id 'GMT Standard Time'` in each checkpoint state |

## Lab vs production

- The scan account is in `Administrators` on a DC, which makes it Tier 0. In production: a dedicated account, password in a vault and rotated, logon restricted to the scanner, and the scanner itself treated as Tier 0.
- `svc-scan` is deleted when the scans are done.

## Next

- Authenticated after (hardened) scan, then the before vs after comparison
- Confirm or override the Snipping Tool finding
- Disable Print Spooler by GPO, rescan as after v2
- Remove `svc-scan`
