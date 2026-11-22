# 02 - Harden the DC

Microsoft Security Baseline for Windows Server 2025 (v2602), applied by Group Policy.

## Why the Microsoft baseline

- Free, official and GPO-based, so it's easy to apply and to check.
- CIS Benchmarks are stricter. They're the stretch goal, not the starting point.

## Prerequisites

- `Clean DC` checkpoint taken ([01 - Build the DC](01-build-dc.md))
- Windows Server 2025 Security Baseline from the Microsoft Security Compliance Toolkit, extracted to `C:\SCT`
- Work on the Hyper-V console, not RDP. Baseline settings can change RDP behaviour.

## Import the baseline GPOs

Importing creates the GPOs in AD without linking them, so nothing changes yet.

```powershell
# DC01 > PowerShell (admin)
Get-ChildItem -Path C:\SCT -Recurse | Unblock-File
cd "C:\SCT\Windows Server 2025 Security Baseline - 2602\Scripts"
.\Baseline-ADImport.ps1
Get-GPO -All | Select-Object DisplayName
```

`Unblock-File` removes the downloaded-from-internet flag. Without it, execution policy blocks the script.

Eight baseline GPOs import. Two apply to a DC.

## Link the DC GPOs

```powershell
# DC01 > PowerShell (admin)
New-GPLink -Name "MSFT Windows Server 2025 v2602 - Domain Security" -Target "DC=hawkode,DC=lab" -LinkEnabled Yes
New-GPLink -Name "MSFT Windows Server 2025 v2602 - Domain Controller" -Target "OU=Domain Controllers,DC=hawkode,DC=lab" -LinkEnabled Yes
gpupdate /force
Restart-Computer
```

Left unlinked on purpose:

| GPO | Reason |
|---|---|
| Member Server, Member Server Credential Guard | Not for DCs |
| Internet Explorer 11 | Not relevant |
| Defender Antivirus | Optional, can link to the Domain Controllers OU later |
| Domain Controller Virtualization Based Security | Needs nested virtualisation on the VM. Parked. |

## What the baseline changes

| Area | Change | Attack it closes |
|---|---|---|
| SMB | Signing required, SMBv1 off | NTLM relay, EternalBlue-class exploits |
| LDAP | Signing and channel binding | LDAP relay to take over AD |
| Legacy auth | NTLMv1 and LM off, NTLM auditing on, WDigest off | Weak hashes, cleartext credential caching |
| Logging | Advanced audit policy, PowerShell logging | Kerberoasting, password spray and similar attacks leaving no trace |
| User rights | Tighter local logon, RDP and service logon rights | Fewer accounts able to try |
| Crypto and surface | Old TLS and ciphers off, firewall on with logging | Downgrade attacks, exposed services |

## What can break

- Devices doing unsigned LDAP binds, such as older printers and MFPs looking up address books. Fix: LDAPS (port 636) and firmware updates.
- Anything still on SMBv1 or NTLMv1.
- Test on a non-critical server first. Production DCs don't have a checkpoint to fall back on.

## Verify

```powershell
# DC01 > PowerShell (admin)
gpresult /r /scope computer                        # both baseline GPOs under Applied Group Policy Objects
Get-ADDomain | Select-Object DNSRoot, DomainMode   # domain still healthy after reboot
```

Result: both GPOs applied, the domain answers and admin logon works.

## Checkpoint

`Hyper-V Manager > DC01 > Checkpoint > rename to Hardened DC`

This is the "after" state for the scans.

## Lab addition: Print Spooler off on DCs

The baseline leaves Print Spooler running. Found in the scans: [04 - Scan results](04-scan-results.md).

- `GPMC > hawkode.lab > Domain Controllers > right-click > Create a GPO in this domain, and Link it here > Lab - DC Disable Print Spooler`
- `Edit > Computer Configuration > Policies > Windows Settings > Security Settings > System Services > Print Spooler > Define > Disabled`
- Link it on the **Domain Controllers** OU, not the domain root, or every computer loses printing

```powershell
# DC01 > PowerShell (admin, elevated)
gpupdate /force; Restart-Computer
# after reboot
Get-Service Spooler | Select-Object Status, StartType          # Stopped, Disabled
gpresult /r /scope computer | Select-String 'Spooler'          # Lab - DC Disable Print Spooler
```

Checkpoint: `Hardened DC v2`.

Rollback: remove the GPO link, `gpupdate /force`, then `Set-Service Spooler -StartupType Automatic; Start-Service Spooler`.

## Rollback

- Unlink: `Remove-GPLink -Name "<gpo>" -Target "<dn>"`
- Unlinking doesn't fully undo the baseline, because some settings stay tattooed in the registry. The clean undo is to apply the `Clean DC` checkpoint.
