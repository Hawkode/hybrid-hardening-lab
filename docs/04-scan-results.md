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
| Authenticated after v2 | `Hardened DC v2` (Print Spooler GPO added) |

## Results

| Scan | Date | Critical | High | Medium | Low |
|---|---|---|---|---|---|
| Unauthenticated after (hardened) | 20 Nov 2026 | 0 | 0 | 1 | 1 |
| Unauthenticated before (clean) | 20 Nov 2026 | 0 | 0 | 1 | 1 |
| Authenticated before (clean) | 21 Nov 2026 | 0 | 1 | 2 | 2 |
| Authenticated after (hardened) | 21 Nov 2026 | 0 | 1 | 2 | 2 |
| Authenticated after v2 (Print Spooler off) | 22 Nov 2026 | Running | - | - | - |

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

## Authenticated: before vs after

Both states returned the same five findings. The baseline changed none of them.

| Finding | CVSS | What GVM checked | Real risk | Decision |
|---|---|---|---|---|
| Windows IExpress Untrusted Search Path (CVE-2018-0598) | 7.8 High | `iexpress.exe` exists | Low. Only matters if someone runs a self-extracting archive from a folder an attacker can write to. | Accept. No patch, workaround only. Nobody builds or runs installers on the DC. |
| Windows HID Functionality (Over USB) Code Execution (CVE-2011-0638) | 6.9 Medium | `hidserv.dll` exists | Close to none on a VM. Needs a physical USB device plugged in. | Accept on the VM. On physical servers: USB device control. |
| DCE/RPC and MSRPC Services Enumeration Reporting | 5.0 Medium | Port 135 | Same as unauthenticated | Accept |
| Windows Snipping Tool Information Disclosure (CVE-2023-28303) | 3.3 Low | File version | None. False positive: only the legacy `SnippingTool.exe` (`10.0.26100.1`) is present. The CVE affects the Store apps (Snip & Sketch, Windows 11 Snipping Tool), and neither is installed. | GVM override to False Positive |
| TCP Timestamps Information Disclosure | 2.6 Low | - | Same as unauthenticated | Accept |

The three findings logging in added are all file-presence or version checks. The baseline doesn't remove those files.

Snipping Tool check on DC01:

```powershell
(Get-Item "$env:windir\System32\SnippingTool.exe").VersionInfo.FileVersion   # 10.0.26100.1
Get-AppxPackage -AllUsers *ScreenSketch* | Select-Object Name, Version         # nothing
Get-AppxPackage -AllUsers *SnippingTool* | Select-Object Name, Version         # nothing
```

Override: `Scans > Overrides > New`, NVT OID `1.3.6.1.4.1.25623.1.0.836385`, host `192.0.2.10`, severity Any, new severity False Positive. GVM hides false positives unless the filter includes `levels=...f`.

After triage, both states: 1 High, 2 Medium, 1 Low, 1 false positive.

### What this shows

- GVM finds missing patches and vulnerable software. The baseline changes configuration. The two don't overlap, so neither scan type shows the baseline's effect.
- A vulnerability scan can't prove hardening. That takes a configuration check: [`Get-HardeningState.ps1`](../scripts/Get-HardeningState.ps1), run on each checkpoint.

## Configuration check: before vs after

[`Get-HardeningState.ps1`](../scripts/Get-HardeningState.ps1) v1.0 run on DC01 in each state, elevated, 22 Nov 2026. Raw values:

| Setting | Clean | Hardened | Changed by baseline |
|---|---|---|---|
| SMB server signing required | True | True | No, Server 2025 default |
| SMB client signing required | True | True | No, Server 2025 default |
| SMBv1 enabled | False | False | No, Server 2025 default |
| LDAPServerIntegrity (legacy value) | 1 | 1 | No. Server 2025 enforces LDAP signing through the newer "LDAP server signing requirements Enforcement" policy |
| LdapEnforceChannelBinding | Not set | 2 (always) | **Yes** |
| LmCompatibilityLevel | Not set (OS default 3) | 5 (NTLMv2 only) | **Yes** |
| NoLMHash | 1 | 1 | No |
| WDigest UseLogonCredential | Not set | Not set | No. Off by default on Server 2025, and Microsoft removed it from the baseline |
| LSA protection | Not set | `RunAsPPLBoot = 1`, but LSASS not protected | Configured, not active (see below) |
| UAC FilterAdministratorToken | Not set | 1 | **Yes** |
| PowerShell script block logging | Not set | 1 | **Yes** |
| Audit: Credential Validation | Success | Success and Failure | **Yes** |
| Audit: Kerberos Authentication Service | Success | Success and Failure | **Yes** |
| Audit: Kerberos Service Ticket Operations | Success | **Failure** | **Yes, reduced** |
| Audit: Directory Service Changes | No Auditing | Success | **Yes** |
| Audit: Security Group Management | Success | Success | No |
| Audit: User Account Management | Success | Success and Failure | **Yes** |
| Audit subcategories with No Auditing | 43 | 30 | **Yes** |
| Firewall profiles off | 0 | 0 | No |
| Print Spooler start type | Automatic | Automatic | No |

v1.0 scored clean 7 of 19 and hardened 13 of 19. v1.1 fixes three targets that were wrong for Server 2025 (legacy LDAP value, WDigest, the LSA protection value name) and accepts "Success and Failure" where the target is "Success".

### What this shows

- The baseline's real changes are invisible to a network scan: NTLM level, LDAP channel binding, UAC, PowerShell logging and audit policy.
- Server 2025 already ships with SMB signing, SMBv1 off, LDAP signing and WDigest off. That's why the unauthenticated scans matched.

### Gaps found

| Gap | Risk | Fix |
|---|---|---|
| Print Spooler running on the DC | PrintNightmare, PrinterBug (T1187) | Lab GPO `Lab - DC Disable Print Spooler`, see [02 - Harden the DC](02-hardening.md) |
| Kerberos Service Ticket Operations audit cut to Failure | Clean logs successful 4769 events and hardened doesn't. The baseline trims a noisy event and loses Kerberoasting (T1558.003) visibility. | Lab GPO setting it to Success and Failure, in the Detect phase |
| LSA protection configured but not active | The GPO sets `Enabled with UEFI Lock` (`RunAsPPLBoot = 1`) and DC01 rebooted after, but an elevated admin can still read LSASS modules and there's no Wininit event 12. LSASS dumping (T1003.001) stays possible. | Cause not found yet. Prove it in the Attack phase with a dump attempt, then fix and recheck. |

Commands used to check LSA protection:

```powershell
# DC01 > PowerShell (admin)
Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa | Select-Object RunAsPPL*      # RunAsPPLBoot = 1
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Wininit'; Id=12} -MaxEvents 1   # no events
Get-Process lsass -Module -ErrorAction Stop | Select-Object -First 1                         # lists lsass.exe = not protected
```

## Gotchas

| Problem | Cause | Fix |
|---|---|---|
| `gpresult : Access Denied` on the hardened DC | Same UAC change | Run it elevated |
| `New-ADUser : Access is denied` on the hardened DC, same command fine on clean | Most likely the baseline turning on UAC Admin Approval Mode for the built-in Administrator, so a non-elevated window gets a filtered token | Run PowerShell as administrator. Check with `whoami /groups`: `High Mandatory Level` = elevated. |
| Wrong report downloaded | Every report from the same task looks alike in the list | Check the `Task Name` column inside the CSV before using it |
| `-AsSecureSting` (typo) stored the password as plain text | `Read-Host` treats unknown words as part of the prompt | Check the prompt shows `*****` while typing |
| Wrong checkpoint branch | `Checkpoint` clicked instead of `Apply`, creating a mislabelled checkpoint | Check `Now` sits under the expected checkpoint before scanning |
| DC01 times 8 hours behind | Server evaluation defaults to Pacific time | `Set-TimeZone -Id 'GMT Standard Time'` in each checkpoint state |

## Lab vs production

- The scan account is in `Administrators` on a DC, which makes it Tier 0. In production: a dedicated account, password in a vault and rotated, logon restricted to the scanner, and the scanner itself treated as Tier 0.
- `svc-scan` is deleted when the scans are done.

## Next

- Authenticated after v2 scan (Print Spooler off), checkpoint `Hardened DC v2`
- Rerun `Get-HardeningState.ps1` v1.1 on `Hardened DC v2`
- Kerberos Service Ticket Operations audit to Success and Failure (Detect phase)
- LSA protection: find out why it isn't active (Attack phase)
- Remove `svc-scan`
