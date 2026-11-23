# 06 - Hybrid joiner, mover, leaver tests

Phase 3: run the hybrid scripts from [entra-iam-automation](https://github.com/Hawkode/entra-iam-automation) against `hawkode.lab` and the Entra lab tenant. AD is the source of authority, and Entra Connect carries every change to the cloud.

## Tests

| # | Test | What proves it | Status |
|---|---|---|---|
| 1 | Prep: what the hybrid scripts need | Scripts, parameters, requirements and lab config listed | Done |
| 2 | Joiner | New AD user syncs to Entra, gets usage location and licence | Planned |
| 3 | Mover | Department and title change in AD, Entra follows, group membership follows | Planned |
| 4 | Leaver | Sign-in blocked, sessions revoked, licence removed | Planned |
| 5 | Source of authority | A Graph edit on a synced user fails cleanly | Planned |
| 6 | Recycle Bin restore | Same `objectGUID`, the user syncs back | Planned |

## Test 1 - What the scripts need

Read from `entra-iam-automation` at commit `9c5631f`.

### Scripts

| Test | Script | Main parameters |
|---|---|---|
| 2 | `Hybrid\New-HybridJoiner.ps1` | `-GivenName -Surname -Department [-JobTitle] [-Manager]`, or `-CsvPath`, or `-ResumeUserPrincipalName`. `-SkipLicense` |
| 3 | `Hybrid\Move-HybridUser.ps1` | `-UserPrincipalName -Department [-JobTitle] [-Manager]` |
| 4 | `Hybrid\Disable-HybridLeaver.ps1` | `-UserPrincipalName -Ticket [-DelegateTo] [-AutoReplyMessage]`. Switches: `-KeepLicense -RemoveAuthMethods -ConvertMailbox -NoDelegate -HideFromGal` |
| 5 | `Cloud\Move-CloudUser.ps1` | Run on purpose against a synced user |

All three hybrid scripts take `-SyncTimeoutSeconds` and support `-WhatIf`.

```powershell
# Laptop > PowerShell 7
cd C:\Repos\entra-iam-automation
'New-HybridJoiner','Move-HybridUser','Disable-HybridLeaver' |
    ForEach-Object { Get-Command ".\Hybrid\$_.ps1" -Syntax }
```

### Requirements

| Need | Detail |
|---|---|
| PowerShell | Windows PowerShell 5.1 or PowerShell 7 |
| AD module | `ActiveDirectory`. The scripts check for it and stop if it's missing. |
| Graph modules | `Microsoft.Graph.Authentication`, `.Users`, `.Users.Actions`, `.Identity.DirectoryManagement`, `.Identity.Governance` |
| Entra Connect | WinRM to the active sync server, and `ADSyncOperators` (or local admin) there. Each run starts one delta sync and waits for it. |
| Exchange Online | Only for `-ConvertMailbox` on the leaver |
| Config | `config.local.psd1`, gitignored (checked below) |

Graph scopes (delegated):

| Script | Scopes |
|---|---|
| Joiner | `User.ReadWrite.All`, `LicenseAssignment.Read.All` |
| Mover | `User.Read.All`, `GroupMember.Read.All`, `RoleManagement.Read.Directory` (read-only: the change happens in AD and syncs up) |
| Leaver | `User.ReadWrite.All`, `GroupMember.ReadWrite.All`, `RoleManagement.Read.Directory`, plus `UserAuthenticationMethod.ReadWrite.All` with `-RemoveAuthMethods` |

```powershell
# Laptop > PowerShell 7
git check-ignore -v config.local.psd1   # .gitignore:2:config.local.psd1
```

### Where they run in this lab

DC01. It has the AD module and Entra Connect, so `EntraConnectServer` points at DC01 itself. Only the Graph submodules above get installed, to keep within DC01's RAM and disk.

### UPN match

The mover and leaver look up the user in AD and in Entra with the same UPN. The 4 phase 2 users don't match: `hy.alice@hawkode.lab` in AD, `hy.alice@contoso.onmicrosoft.com` in Entra. Neither lookup would find both.

So for tests 2-6:
- Add `contoso.onmicrosoft.com` as a UPN suffix in AD
- Set `DefaultDomain` to it, so the joiner creates users with the same UPN in AD and Entra
- Use the test 2 joiner for the mover, leaver and restore tests: one user, full lifecycle

The joiner's suffix check also accepts the AD DNS root (`hawkode.lab`). With that as `DefaultDomain`, the check passes but the user lands in Entra under a different UPN, and the wait step can't find it.

### Lab config (hybrid keys, set before test 2)

| Key | Lab value | Why |
|---|---|---|
| `DefaultDomain` | `contoso.onmicrosoft.com` | Same UPN in AD and Entra (see above) |
| `DepartmentOUs` | `HR` and `Finance` OUs under `OU=Lab Users,DC=hawkode,DC=lab` | They have to sit inside the sync scope, or joiners never reach Entra |
| `LeaversOU` | `OU=Leavers,OU=Lab Users,DC=hawkode,DC=lab` | Inside the sync scope, so the cloud account is disabled, not deleted |
| `LeaversOUInSyncScope` | `$true`, after checking Domain and OU filtering | |
| `EntraConnectServer` | `DC01.hawkode.lab` | |
| `ProtectedAdGroups` | `Domain Users` | |
| `LicenseSkuPartNumber` | Picked in test 2 from `Get-MgSubscribedSku` | |

## Lab vs production

- The scripts run on the DC to save RAM. In production they run from an admin workstation or management server, and Entra Connect sits on its own Tier 0 server.
- `contoso.onmicrosoft.com` stands in for a verified company domain. In production the AD UPN suffix and the verified domain are the same real domain.
