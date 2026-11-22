# 05 - Sync to Entra ID with Entra Connect

Phase 2: sync a scoped set of test users from `hawkode.lab` to the Entra lab tenant with Microsoft Entra Connect Sync, password hash sync only.

## Why Connect Sync, not Cloud Sync

- The hybrid scripts in [entra-iam-automation](https://github.com/Hawkode/entra-iam-automation) use the ADSync module (`Start-ADSyncSyncCycle` and friends). Only Connect Sync installs it.
- Cloud Sync is a lighter agent managed from the cloud. It would use less RAM, but the hybrid scripts would have nothing to talk to.

## Prerequisites

| Item | State |
|---|---|
| Phase 1 scans | Finished. Entra Connect adds services, SQL LocalDB and ports, so any scan after this measures Entra Connect, not the baseline. |
| `svc-scan` | Deleted. It's Tier 0 and must never sync. |
| Checkpoint | `Pre-sync` (under `Hardened DC v2`) |
| RAM | KALI01 off, DC01 at 4 GB |
| Tenant domain | Only `contoso.onmicrosoft.com`, no custom domain |
| Tenant admin | Global Administrator (lab). Production: Hybrid Identity Administrator, activated through PIM. |
| Server 2025 | Microsoft lists a known Entra Connect Sync issue on Server 2025, fixed by the 20 Oct 2025 update (KB5070773) or later. DC01 build checked: `26100.32230`. |

```powershell
# DC01 > PowerShell (admin)
Remove-ADUser -Identity svc-scan -Confirm:$false
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($cv.CurrentBuild).$($cv.UBR)"
[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)    # 4
```

```powershell
# Host > PowerShell (admin)
Set-VMMemory -VMName DC01 -DynamicMemoryEnabled $false -StartupBytes 4GB
Get-VM DC01, KALI01 | Select-Object Name, State, MemoryStartup
```

## UPN suffix

`hawkode.lab` isn't routable, so Entra can't verify it. With no custom domain in the tenant, Entra Connect falls back to the `onmicrosoft.com` domain:

| AD UPN | Entra UPN |
|---|---|
| `hy.alice@hawkode.lab` | `hy.alice@contoso.onmicrosoft.com` |

Users sign in with the Entra UPN and their AD password (password hash sync).

## Test users

One OU, synced on its own. The `hy.` prefix keeps the names away from existing cloud users.

⚠ Soft-match risk: if an AD user has the same UPN or email as an existing cloud-only user, Entra Connect merges them and takes over the cloud account. New, unique names avoid that.

```powershell
# DC01 > PowerShell (admin, elevated) - Windows PowerShell 5.1
New-ADOrganizationalUnit -Name 'Lab Users' -Path 'DC=hawkode,DC=lab'
$pw = Read-Host -AsSecureString 'test user password'
$users = @(
  @{G='Alice';  S='Morgan'; D='Finance'; T='Analyst'},
  @{G='Ben';    S='Carter'; D='IT';      T='Engineer'},
  @{G='Chloe';  S='Davies'; D='HR';      T='Advisor'},
  @{G='Daniel'; S='Evans';  D='Sales';   T='Manager'}
)
foreach ($u in $users) {
  $sam = "hy.$($u.G.ToLower())"
  New-ADUser -Name "$($u.G) $($u.S)" -GivenName $u.G -Surname $u.S -SamAccountName $sam `
    -UserPrincipalName "$sam@hawkode.lab" -Department $u.D -Title $u.T `
    -Path 'OU=Lab Users,DC=hawkode,DC=lab' -AccountPassword $pw -Enabled $true
}
Get-ADUser -SearchBase 'OU=Lab Users,DC=hawkode,DC=lab' -Filter * | Select-Object SamAccountName, UserPrincipalName
```

Result: `hy.alice`, `hy.ben`, `hy.chloe`, `hy.daniel`, all `@hawkode.lab`.

Department and title are set so the joiner/mover/leaver tests in Phase 3 have attributes to change.

## Get the installer onto DC01

Download: `Entra admin center > Entra ID > Entra Connect > Get started > Download Connect Sync Agent` (`AzureADConnect.msi`). Microsoft now serves the latest build there; the Download Center page lags behind.

Edge is blocked on the hardened DC ("This app has been blocked by your system administrator"). Browsing from a DC is bad practice anyway, so download on the host and push the file in through Hyper-V:

```powershell
# Host > PowerShell (admin)
Enable-VMIntegrationService -VMName DC01 -Name 'Guest Service Interface'
Copy-VMFile -Name DC01 -SourcePath 'C:\Users\<you>\Downloads\AzureADConnect.msi' -DestinationPath 'C:\Scripts\AzureADConnect.msi' -FileSource Host -CreateFullPath
```

```powershell
# DC01 > PowerShell
Get-Item C:\Scripts\AzureADConnect.msi | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB)}}   # 182
```

Checkpoint: `Pre-Entra Connect`.

## Install (custom settings)

| Wizard page | Choice | Why |
|---|---|---|
| Express Settings | **Customize** | Express syncs the whole domain |
| Required components | Nothing ticked | Installs SQL LocalDB and the ADSync service |
| User sign-in | Password Hash Synchronization, single sign-on off | Simplest sign-in; Seamless SSO adds a computer account to protect |
| Connect to Entra ID | Lab Global Admin | See prerequisites for the production choice |
| Connect directories | `hawkode.lab` > Create new AD account > `HAWKODE.LAB\Administrator` | Creates the `MSOL_` connector account. The Enterprise Admin credentials are used once, not stored. |
| Entra sign-in | `hawkode.lab` Not Added > tick "Continue without matching all UPN suffixes" | No custom domain, so the `onmicrosoft.com` fallback |
| Domain and OU filtering | Sync selected > only `Lab Users` | Keeps Administrator, `MSOL_`, built-ins and DCs out of Entra |
| Identifying users | Represented once; Azure manages the source anchor | One forest. `ms-DS-ConsistencyGuid` links AD and Entra objects. |
| Filtering | Synchronize all users and devices | The OU filter already limits scope. Group filtering is for pilots only. |
| Optional features | Password hash sync only | |
| Ready to configure | Start sync ticked, staging mode off | Deletion threshold 500 is on by default |

Result: `Configuration complete`. Warnings shown: AD Recycle Bin not enabled, source anchor set to `ms-DS-ConsistencyGuid`.

### What the install creates

| Object | Risk |
|---|---|
| `MSOL_xxxxxxxx` user in `CN=Users` | Has Replicate Directory Changes rights, the same rights DCSync abuses. Tier 0. Goes into the Attack phase. |
| ADSync service and SQL LocalDB | The sync database holds the connector credentials. The Entra Connect server is Tier 0. |
