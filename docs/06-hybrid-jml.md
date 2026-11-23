# 06 - Hybrid joiner, mover, leaver tests

Phase 3: run the hybrid scripts from [entra-iam-automation](https://github.com/Hawkode/entra-iam-automation) against `hawkode.lab` and the Entra lab tenant. AD is the source of authority, and Entra Connect carries every change to the cloud.

## Tests

| # | Test | What proves it | Status |
|---|---|---|---|
| 1 | Prep: what the hybrid scripts need | Scripts, parameters, requirements and lab config listed | Done |
| 2 | Joiner | New AD user syncs to Entra, gets usage location and licence | Done |
| 3 | Mover | Department and title change in AD, Entra follows, group membership follows | Done |
| 4 | Leaver | Sign-in blocked, sessions revoked, licence removed | Done |
| 5 | Source of authority | A Graph edit on a synced user fails cleanly | Done |
| 6 | Recycle Bin restore | Same `objectGUID`, the user syncs back | Done |

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

## Test 3 - Mover

Harriet moves from HR to Finance, with a new title.

### Setup

One AD group, so the review list has something to catch. It sits in the HR OU, inside the sync scope, so it also syncs to Entra.

```powershell
# DC01 > PowerShell 7 (admin) > C:\Scripts\entra-iam-automation
$upn = 'harriet.cole@contoso.onmicrosoft.com'
New-ADGroup -Name 'GG-HR-FileShare' -GroupScope Global -Path 'OU=HR,OU=Lab Users,DC=hawkode,DC=lab'
Add-ADGroupMember 'GG-HR-FileShare' -Members (Get-ADUser -Filter "UserPrincipalName -eq '$upn'")
(Get-MgUserMemberOf -UserId $upn -All).AdditionalProperties.displayName
```

Before: `Dept-HR` (dynamic group, rule on department).

### Dry run

```powershell
.\Hybrid\Move-HybridUser.ps1 -UserPrincipalName $upn -Department Finance -JobTitle 'Finance Analyst' -WhatIf
```

- `What if: department 'HR' -> 'Finance', job title 'HR Advisor' -> 'Finance Analyst', move to OU=Finance,OU=Lab Users,DC=hawkode,DC=lab, delta sync`
- Warning: no manager in AD, so the leaver will have nobody to hand the mailbox to
- Review list (read-only, so it runs under `-WhatIf` too): `AD group: GG-HR-FileShare`

### Run

```powershell
.\Hybrid\Move-HybridUser.ps1 -UserPrincipalName $upn -Department Finance -JobTitle 'Finance Analyst'
```

| Step | Time (UTC) | Result |
|---|---|---|
| AD change and OU move | 18:57:26 | Department, title, `OU=Finance,OU=Lab Users` |
| Delta sync on DC01 | 18:57:43 | Completed (Success) |
| Cloud check | 18:57:44 | User still in Entra (new OU is inside the sync scope) |
| Review list | 18:57:44 | 1 item: `GG-HR-FileShare`, written to `output\` (gitignored) |

### Verify

```powershell
Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties Department, Title | Select-Object DistinguishedName, Department, Title
Get-MgUser -UserId $upn -Property Department, JobTitle | Select-Object Department, JobTitle
(Get-MgUserMemberOf -UserId $upn -All).AdditionalProperties.displayName
```

| Check | Before | After |
|---|---|---|
| AD OU | `OU=HR,OU=Lab Users` | `OU=Finance,OU=Lab Users` |
| Department (AD and Entra) | `HR` | `Finance` |
| Title (AD and Entra) | `HR Advisor` | `Finance Analyst` |
| Cloud groups | `Dept-HR` | `Dept-Finance`, `GG-HR-FileShare` |

The dynamic groups re-scoped by themselves: `Dept-HR` out, `Dept-Finance` in. `GG-HR-FileShare` stayed, in AD and as a synced group in Entra. That's the leftover access the review list flags. The script lists it and leaves the decision to the new manager, because only a person knows whether Finance still needs that share.

## Test 4 - Leaver

Harriet leaves. No `-ConvertMailbox`: the P2 trial has no Exchange plan, so there's no mailbox.

### Sync scope check

The Leavers OU decides the outcome. Inside the sync scope, the cloud account is disabled. Outside it, the sync deletes the cloud account (and its mailbox, if it had one).

```powershell
# DC01 > Windows PowerShell 5.1 (admin) - ADSync doesn't load in PowerShell 7
$c = Get-ADSyncConnector | Where-Object ConnectorTypeName -eq 'AD'
$c.Partitions.ConnectorPartitionScope.ContainerInclusionList   # OU=Lab Users,DC=hawkode,DC=lab
$c.Partitions.ConnectorPartitionScope.ContainerExclusionList   # CN=LostAndFound, and the domain root
```

The domain root is excluded, but the more specific `Lab Users` inclusion wins, so `Leavers` is in scope. `LeaversOUInSyncScope` set to `$true`.

Checkpoint: `Pre-leaver`.

### Dry run

```powershell
# DC01 > PowerShell 7 (admin) > C:\Scripts\entra-iam-automation
$upn = 'harriet.cole@contoso.onmicrosoft.com'
.\Hybrid\Disable-HybridLeaver.ps1 -UserPrincipalName $upn -Ticket LAB-0004 -WhatIf
```

Plan: `AD: disable; reset password; remove from 1 AD group(s): GG-HR-FileShare; clear department 'Finance'; description 'Leaver 2026-11-23 LAB-0004 by administrator'; move to OU=Leavers,OU=Lab Users,DC=hawkode,DC=lab; delta sync; Entra: revoke sessions; remove direct licences`

No cloud-only groups to remove: `Dept-Finance` is dynamic and drops when the department clears.

### Run

```powershell
.\Hybrid\Disable-HybridLeaver.ps1 -UserPrincipalName $upn -Ticket LAB-0004
```

One confirmation prompt, after the plan.

| Step | Time (UTC) | Result |
|---|---|---|
| AD: disable and password reset | 19:05:20 | Done |
| AD: groups | 19:05:20 | Removed from `GG-HR-FileShare` |
| AD: department, description, OU | 19:05:20 | Cleared, stamped, moved to `OU=Leavers,OU=Lab Users` |
| Delta sync on DC01 | 19:05:38 | Completed (Success), account shows disabled in Entra |
| Entra: sessions | 19:05:38 | Revoked |
| Entra: licence | 19:05:39 | 1 direct licence removed |
| Result | 19:05:39 | No manual items, CSV in `output\` (gitignored) |

23 seconds from the first AD change to a blocked, unlicensed cloud account. The order matters: AD first, then sync, then Entra. With password hash sync, the cloud account accepts the old password until the sync shows it as disabled, so the script waits for that before the cloud steps.

### Verify

```powershell
Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties Enabled, Department, Description, MemberOf |
    Select-Object Enabled, DistinguishedName, Department, Description, @{n='Groups';e={$_.MemberOf.Count}}
Get-MgUser -UserId $upn -Property AccountEnabled, Department, AssignedLicenses, SignInSessionsValidFromDateTime |
    Select-Object AccountEnabled, Department, SignInSessionsValidFromDateTime, @{n='Licences';e={$_.AssignedLicenses.Count}}
(Get-MgUserMemberOf -UserId $upn -All).AdditionalProperties.displayName
```

| Check | After |
|---|---|
| AD enabled | `False` |
| AD OU | `OU=Leavers,OU=Lab Users` |
| AD department | Empty |
| AD description | `Leaver 2026-11-23 LAB-0004 by administrator` |
| AD groups | 0 (Domain Users kept as primary group) |
| Entra `AccountEnabled` | `False` |
| Entra sessions valid from | 23 Nov 2026 19:05:38 |
| Entra licences | 0 |
| Entra groups | None: `GG-HR-FileShare` gone through the sync, `Dept-Finance` gone through the dynamic rule |

The leftover access from test 3 is gone too.

## Test 5 - Source of authority

For a synced user, AD is the source of authority. The test checks that the cloud side refuses edits at two levels, the script guard and Graph itself, and that nothing changes.

```powershell
# DC01 > PowerShell 7 (admin) > C:\Scripts\entra-iam-automation
$upn = 'harriet.cole@contoso.onmicrosoft.com'

# 1. Cloud script against a synced user
.\Cloud\Move-CloudUser.ps1 -UserPrincipalName $upn -Department IT

# 2. Raw Graph edit of an AD-mastered attribute
Update-MgUser -UserId $upn -Department 'IT'

# 3. The other way: hybrid script against a cloud-only user
.\Hybrid\Move-HybridUser.ps1 -UserPrincipalName 'oliver.bennett@contoso.onmicrosoft.com' -Department Finance -WhatIf

# 4. Nothing changed
Get-MgUser -UserId $upn -Property Department, OnPremisesSyncEnabled | Select-Object Department, OnPremisesSyncEnabled
```

| # | Attempt | Result |
|---|---|---|
| 1 | `Move-CloudUser.ps1` on synced Harriet | Stopped: `harriet.cole@contoso.onmicrosoft.com is synced from AD. Use the Hybrid script.` |
| 2 | `Update-MgUser -Department` | Graph `400 Request_BadRequest`: `Unable to update the specified properties for on-premises mastered Directory Sync objects or objects currently undergoing migration.` |
| 3 | `Move-HybridUser.ps1` on cloud-only Oliver | Stopped: `oliver.bennett@contoso.onmicrosoft.com not found in AD.` |
| 4 | Harriet afterwards | Department still empty, `OnPremisesSyncEnabled` still `True` |

The guard in 1 runs before any other check, so the disabled account didn't matter, and it gives a clear next step instead of a raw Graph error. Even without the guard, Graph refuses the change, as 2 shows. In 3 the hybrid script stops at the AD lookup, before it reaches Graph.

Not every attribute is AD-mastered. Usage location and licences live only in the cloud, which is why the joiner sets them through Graph on a synced user. Department, title, manager and account state come from AD.

## Test 6 - Recycle Bin restore

Harriet is deleted in AD by mistake, then restored from the AD Recycle Bin. Pass: the same cloud account comes back, not a new one.

Checkpoint: `Pre-restore`.

### Before

```powershell
# DC01 > PowerShell 7 (admin)
$upn   = 'harriet.cole@contoso.onmicrosoft.com'
$guid  = (Get-ADUser -Filter "UserPrincipalName -eq '$upn'").ObjectGUID
$cloud = Get-MgUser -UserId $upn -Property Id, OnPremisesImmutableId
$guid; $cloud.Id; $cloud.OnPremisesImmutableId
[Convert]::ToBase64String($guid.ToByteArray())     # equals OnPremisesImmutableId
```

The source anchor is `mS-DS-ConsistencyGuid`, which Entra Connect filled from the `objectGUID` on the first sync, so both hold the same value. Base64 of it equals the cloud `OnPremisesImmutableId`. That link is what lets Entra Connect find the same cloud account again later.

### Delete in AD and sync

```powershell
Remove-ADUser -Identity $guid -Confirm:$false
Invoke-Command -ComputerName DC01.hawkode.lab { Start-ADSyncSyncCycle -PolicyType Delta }   # Success
Start-Sleep 60
Invoke-MgGraphRequest -Uri "v1.0/directory/deletedItems/$($cloud.Id)" | Select-Object displayName
```

Result: `Harriet Cole` is in Entra ID Deleted users (soft-deleted, kept for 30 days). The AD deletion flowed to the cloud in one sync.

`Invoke-Command` runs the sync from PowerShell 7 through a Windows PowerShell remoting session, where the ADSync module loads. The hybrid scripts do it the same way.

### Restore and sync

```powershell
Get-ADObject -Filter "objectGUID -eq '$guid'" -IncludeDeletedObjects | Restore-ADObject
Invoke-Command -ComputerName DC01.hawkode.lab { Start-ADSyncSyncCycle -PolicyType Delta }   # Success
Start-Sleep 60
```

### Verify

```powershell
Get-ADUser -Identity $guid -Properties Enabled | Select-Object ObjectGUID, DistinguishedName, Enabled
Get-MgUser -UserId $cloud.Id -Property Id, UserPrincipalName, OnPremisesImmutableId, OnPremisesSyncEnabled, AccountEnabled |
    Select-Object Id, UserPrincipalName, OnPremisesImmutableId, OnPremisesSyncEnabled, AccountEnabled
```

| Check | Before delete | After restore |
|---|---|---|
| AD `objectGUID` | `<guid>` | Same |
| AD OU | `OU=Leavers,OU=Lab Users` | Same (restored to its last parent) |
| AD enabled | `False` | `False` |
| Entra object `Id` | `<object id>` | Same |
| Entra `OnPremisesImmutableId` | Base64 of the `objectGUID` | Same |
| Entra synced, enabled | `True`, `False` | `True`, `False` |

Same `objectGUID` in AD, same object `Id` and `ImmutableId` in Entra. Entra Connect matched the restored AD object to the soft-deleted cloud account through the source anchor and brought that account back. The restore also kept the leaver state: disabled, in Leavers, no licence.

A recreated account (a new `New-ADUser` with the same name) would get a new `objectGUID`. Entra Connect would then make a new cloud account, or soft-match by UPN, and the old object ID and its history would be lost. That's why the AD Recycle Bin was turned on in phase 2.

## Result

All 6 tests passed. The hybrid scripts from `entra-iam-automation` work against a real AD and Entra Connect setup:

| Lifecycle step | AD change to cloud result |
|---|---|
| Joiner | 20 seconds to a synced, licensed user |
| Mover | 18 seconds to synced attributes, dynamic groups re-scoped within minutes, leftover AD access listed |
| Leaver | 23 seconds to a disabled, session-revoked, unlicensed cloud account |
| Wrong tool, wrong user | Refused by the script guard and by Graph |
| Accidental delete | Restored with the same AD and cloud identity |

## Audit trail

The same lifecycle, as Entra ID recorded it. `Entra admin center > Identity > Monitoring & health > Audit logs`, last 24 hours, target `harriet.cole`. Times are UTC (GMT in November).

| Time | Activity | Status | Test |
|---|---|---|---|
| 18:52:39 | Add user, Update PasswordProfile | Success | 2 Joiner: created by the sync |
| 18:52:44-45 | Update user, Change user license | Success | 2 Joiner: usage location and licence through Graph |
| 18:52:54 | Add member to group | Success | 2 Joiner: `Dept-HR` dynamic rule |
| 18:57:39 | Update user, Add member to group | Success | 3 Mover: department and title synced, `GG-HR-FileShare` synced |
| 18:58:18-19 | Add member to group, Remove member from group | Success | 3 Mover: `Dept-Finance` in, `Dept-HR` out |
| 19:05:33 | Update user, Disable account, Remove member from group | Success | 4 Leaver: synced from AD, `GG-HR-FileShare` removed |
| 19:05:39 | Update StsRefreshTokenValidFrom, Update user, Change user license | Success | 4 Leaver: sessions revoked, licence removed |
| 19:05:40 | Remove member from group | Success | 4 Leaver: `Dept-Finance` dynamic rule |
| 19:17:52 | Update user | **Failure** (`PropertyUpdateNotAllowed`) | 5 Source of authority: the refused Graph edit |
| 19:21:12 | Delete user | Success | 6 Restore: AD delete synced |
| 19:22:58 | Restore user | Success | 6 Restore: same object back |

Everything the scripts logged in the console shows up here, from Microsoft's side, including the refused edit in test 5.

Gotcha: filter on **Activity: Delete user** to find the delete. A soft-deleted user's UPN gets its object ID in front, so a target filter of "starts with harriet.cole" misses that row.

## Gotchas

| Problem | Cause | Fix |
|---|---|---|
| Graph modules installed but `Get-Module -ListAvailable` shows nothing | DC01's `PSModulePath` has no Documents folder, so `-Scope CurrentUser` installs are invisible | `-Scope AllUsers` |
| `Connect-MgGraph`: `Method 'RefreshCacheAsync' ... does not have an implementation` | Known assembly loading bug in Graph SDK 2.34+ on Windows PowerShell 5.1. Still there in 2.41.2, even in a clean session with Graph loaded first | PowerShell 7 on DC01. Microsoft is ending Graph SDK support on 5.1 |
| `config.local.psd1 is not ready: DepartmentOUs is missing or empty` | Config copied from the cloud-only setup, hybrid keys still unset | Set the hybrid keys from the test 1 table |
| Joiner: `already exists in Entra ID` | A cloud-only user with the same UPN | Pick a free name. This is the soft-match guard working |
| `Get-MgGroup` not recognised | `Microsoft.Graph.Groups` isn't installed. The scripts don't need it | Install it only for ad-hoc checks |
| `Get-ADSyncConnector` not recognised | Run in PowerShell 7 | Type `powershell` to drop into 5.1, `exit` to go back |
| `Start-ADSyncSyncCycle` not recognised in PowerShell 7 | ADSync is a Windows PowerShell module | `Invoke-Command -ComputerName <sync server> { Start-ADSyncSyncCycle -PolicyType Delta }` |
| AD cmdlets not recognised | DC01 commands run on the host by mistake | Run `hostname` first |

## Lab vs production

- The scripts run on the DC to save RAM. In production they run from an admin workstation or management server, and Entra Connect sits on its own Tier 0 server.
- PowerShell 7 is the platform for the Graph SDK from here on. In production, install it on the management server before anything else.
- Review lists for movers go to the new manager with a deadline. Unreviewed AD group access is how permissions pile up over the years.
- The lab leaver has no mailbox. In production, convert the mailbox to shared with `-ConvertMailbox` and agree with HR who gets access.
- Scripts that change users check the sync state first. In a tenant with both cloud-only and synced users, that guard stops the wrong tool being used on the wrong account.
- Accidental deletes: restore from the AD Recycle Bin, never recreate. A recreated account gets a new `objectGUID` and a new cloud identity.
- Temporary passwords go to the manager through a one-time secret link, never email or chat.
- `contoso.onmicrosoft.com` stands in for a verified company domain. In production the AD UPN suffix and the verified domain are the same real domain.
