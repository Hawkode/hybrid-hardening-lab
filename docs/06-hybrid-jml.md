# 06 - Hybrid joiner, mover, leaver tests

Phase 3: run the hybrid scripts from [entra-iam-automation](https://github.com/Hawkode/entra-iam-automation) against `hawkode.lab` and the Entra lab tenant. AD is the source of authority, and Entra Connect carries every change to the cloud.

## Tests

| # | Test | What proves it | Status |
|---|---|---|---|
| 1 | Prep: what the hybrid scripts need | Scripts, parameters, requirements and lab config listed | Done |
| 2 | Joiner | New AD user syncs to Entra, gets usage location and licence | Done |
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
| `LicenseSkuPartNumber` | `AAD_PREMIUM_P2` | The Entra ID P2 trial is the only SKU in the lab tenant |

## Test 2 - Joiner

### Setup

Checkpoint first: `Pre-JML`.

Copy the scripts and the config from the host. Only tracked files go in the zip, so the config goes separately.

```powershell
# Host > PowerShell 7 (admin)
git -C C:\Repos\entra-iam-automation archive --format=zip -o "$env:TEMP\eia.zip" HEAD
Copy-VMFile -Name DC01 -SourcePath "$env:TEMP\eia.zip" -DestinationPath 'C:\Scripts\eia.zip' -FileSource Host -CreateFullPath
Copy-VMFile -Name DC01 -SourcePath 'C:\Repos\entra-iam-automation\config.local.psd1' -DestinationPath 'C:\Scripts\entra-iam-automation\config.local.psd1' -FileSource Host -CreateFullPath
```

```powershell
# DC01 > PowerShell (admin)
Expand-Archive C:\Scripts\eia.zip -DestinationPath C:\Scripts\entra-iam-automation -Force
Get-ChildItem C:\Scripts\entra-iam-automation -Recurse | Unblock-File

Set-ADForest -Identity hawkode.lab -UPNSuffixes @{Add = 'contoso.onmicrosoft.com'}
'HR','Finance','Leavers' | ForEach-Object {
    New-ADOrganizationalUnit -Name $_ -Path 'OU=Lab Users,DC=hawkode,DC=lab' }

Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions,
    Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance `
    -Scope AllUsers -Repository PSGallery -Force

# Graph fails on Windows PowerShell 5.1 here (see gotchas), so PowerShell 7
iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
```

From here everything runs in PowerShell 7.6 (admin) on DC01. It finds the Graph modules in `C:\Program Files\WindowsPowerShell\Modules`, so no reinstall.

Checks:

| Check | Result |
|---|---|
| `(Get-ADForest).UPNSuffixes` | `contoso.onmicrosoft.com` |
| OUs under `Lab Users` | `HR`, `Finance`, `Leavers` |
| Graph modules | 5 modules, all `2.41.2` |
| `Test-WSMan DC01.hawkode.lab` | Responds |
| `Get-MgSubscribedSku` | `AAD_PREMIUM_P2` |

Then the hybrid keys in `config.local.psd1`, as in the test 1 table.

### Dry run

```powershell
# DC01 > PowerShell 7 (admin) > C:\Scripts\entra-iam-automation
.\Hybrid\New-HybridJoiner.ps1 -GivenName Oliver -Surname Bennett -Department HR -JobTitle 'HR Advisor' -WhatIf
```

Stopped: `oliver.bennett@contoso.onmicrosoft.com already exists in Entra ID. Entra Connect would soft-match the new AD account onto it. Nothing was created.` A cloud-only user from earlier cloud tests had that UPN. The guard did its job: without it, Entra Connect would have linked the new AD account to the cloud account and taken it over.

Second try, with a free name:

```powershell
.\Hybrid\New-HybridJoiner.ps1 -GivenName Harriet -Surname Cole -Department HR -JobTitle 'HR Advisor' -WhatIf
```

`What if: Create AD user in OU=HR,OU=Lab Users,DC=hawkode,DC=lab (HR), sync, set usage location, assign AAD_PREMIUM_P2`

### Run

```powershell
.\Hybrid\New-HybridJoiner.ps1 -GivenName Harriet -Surname Cole -Department HR -JobTitle 'HR Advisor'
```

| Step | Time (UTC) | Result |
|---|---|---|
| AD user created | 18:52:25 | `harriet.cole` in `OU=HR,OU=Lab Users` |
| Delta sync on DC01 | 18:52:43 | Completed (Success) |
| Usage location | 18:52:44 | `GB` |
| Licence | 18:52:45 | `AAD_PREMIUM_P2` |

20 seconds from AD account to licensed user in Entra, with no manual steps. The run CSV (in `output\`, gitignored) has no passwords. The temporary password appears once in the console, and the user must change it at first sign-in.

### Verify

```powershell
# DC01 > PowerShell 7 (admin)
$upn = 'harriet.cole@contoso.onmicrosoft.com'
Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties Department, Title |
    Select-Object DistinguishedName, Department, Title, ObjectGUID
Get-MgUser -UserId $upn -Property UserPrincipalName, OnPremisesSyncEnabled, UsageLocation, Department, JobTitle, AssignedLicenses |
    Select-Object UserPrincipalName, OnPremisesSyncEnabled, UsageLocation, Department, JobTitle,
        @{n='Licences';e={$_.AssignedLicenses.SkuId}}
```

Result: the AD user sits in the HR OU with department `HR` and title `HR Advisor`. In Entra: `OnPremisesSyncEnabled` is `True`, usage location is `GB`, department and title match AD, and there's one licence.

`harriet.cole` carries on through the mover, leaver and restore tests.

## Gotchas

| Problem | Cause | Fix |
|---|---|---|
| Graph modules installed but `Get-Module -ListAvailable` shows nothing | DC01's `PSModulePath` has no Documents folder, so `-Scope CurrentUser` installs are invisible | `-Scope AllUsers` |
| `Connect-MgGraph`: `Method 'RefreshCacheAsync' ... does not have an implementation` | Known assembly loading bug in Graph SDK 2.34+ on Windows PowerShell 5.1. Still there in 2.41.2, even in a clean session with Graph loaded first | PowerShell 7 on DC01. Microsoft is ending Graph SDK support on 5.1 |
| `config.local.psd1 is not ready: DepartmentOUs is missing or empty` | Config copied from the cloud-only setup, hybrid keys still unset | Set the hybrid keys from the test 1 table |
| Joiner: `already exists in Entra ID` | A cloud-only user with the same UPN | Pick a free name. This is the soft-match guard working |
| AD cmdlets not recognised | DC01 commands run on the host by mistake | Run `hostname` first |

## Lab vs production

- The scripts run on the DC to save RAM. In production they run from an admin workstation or management server, and Entra Connect sits on its own Tier 0 server.
- PowerShell 7 is the platform for the Graph SDK from here on. In production, install it on the management server before anything else.
- Temporary passwords go to the manager through a one-time secret link, never email or chat.
- `contoso.onmicrosoft.com` stands in for a verified company domain. In production the AD UPN suffix and the verified domain are the same real domain.
