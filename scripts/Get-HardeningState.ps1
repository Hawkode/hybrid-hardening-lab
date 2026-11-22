<#
.SYNOPSIS
    Reads the settings the Microsoft Security Baseline changes on a DC and shows each one against its target.
.DESCRIPTION
    Read-only. Changes nothing. Run it on each DC01 checkpoint (clean, hardened, hardened v2) to get a
    before/after table that a vulnerability scan can't give.
    Checks: SMB signing and SMBv1, LDAP signing and channel binding, NTLM level, LM hash, WDigest,
    UAC for the built-in Administrator, LSA protection, PowerShell logging, audit policy, firewall, Print Spooler.
.PARAMETER Label
    Name of the state being checked, e.g. clean or hardened. Goes into the output and the CSV name.
.PARAMETER CsvPath
    Optional. Folder to save a CSV in. Default: no CSV.
.EXAMPLE
    .\Get-HardeningState.ps1 -Label clean
.EXAMPLE
    .\Get-HardeningState.ps1 -Label hardened -CsvPath C:\Scripts\Logs
.NOTES
    Runs on : the DC itself (reads local registry, services and audit policy)
    Requires: Windows PowerShell 5.1 or PowerShell 7, elevated (auditpol needs admin). No extra modules.
    Author  : Alex
    Version : 1.1 - 22/11/2026 - Server 2025 targets: LDAP signing, WDigest, LSA protection (RunAsPPLBoot + live check),
                                 audit "at least" matching
              1.0 - 22/11/2026
    Targets : Microsoft Security Baseline for Windows Server 2025 (v2602), Domain Controller + Domain Security GPOs.
              Lab targets that go beyond the baseline: Print Spooler disabled, Kerberos Service Ticket Operations
              Success and Failure (Kerberoasting detection needs successful 4769 events).
              Target "info" = shown for context, not scored.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Label,

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { 'Not set' }
}

function New-Check {
    param([string]$Area, [string]$Setting, $Value, $Target, [string]$Closes, [Nullable[bool]]$Pass)
    if ($null -eq $Pass) { $Pass = ("$Value" -in @($Target | ForEach-Object { "$_" })) }
    [pscustomobject]@{
        State   = $Label
        Area    = $Area
        Setting = $Setting
        Value   = "$Value"
        Target  = (@($Target) -join ' or ')
        Pass    = $Pass
        Closes  = $Closes
    }
}

$lsa    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$ntds   = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
$uac    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$wdig   = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
$psLog  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'

$smbServer = Get-SmbServerConfiguration
$smbClient = Get-SmbClientConfiguration

$results = [System.Collections.Generic.List[object]]::new()

# Key command: each line reads one setting and compares it with the baseline target
$results.Add((New-Check 'SMB'  'Server signing required'     $smbServer.RequireSecuritySignature $true 'NTLM relay to SMB'))
$results.Add((New-Check 'SMB'  'Client signing required'     $smbClient.RequireSecuritySignature $true 'NTLM relay to SMB'))
$results.Add((New-Check 'SMB'  'SMBv1 enabled'               $smbServer.EnableSMB1Protocol       $false 'EternalBlue-class exploits'))
# Server 2025 enforces LDAP signing through the "LDAP server signing requirements Enforcement" policy,
# even when this older value stays at 1. Shown for context; prove signing with an unsigned bind test.
$results.Add((New-Check 'LDAP' 'LDAPServerIntegrity (legacy)' (Get-RegValue $ntds 'LDAPServerIntegrity')     'info' 'LDAP relay'))
$results.Add((New-Check 'LDAP' 'LdapEnforceChannelBinding'   (Get-RegValue $ntds 'LdapEnforceChannelBinding') 2 'LDAPS relay (2 = always)'))
$results.Add((New-Check 'NTLM' 'LmCompatibilityLevel'        (Get-RegValue $lsa 'LmCompatibilityLevel') 5 'NTLMv1 and LM downgrade (5 = NTLMv2 only)'))
$results.Add((New-Check 'NTLM' 'NoLMHash'                    (Get-RegValue $lsa 'NoLMHash')             1 'LM hashes stored'))
# WDigest is off by default on Server 2025 when the value is absent
$results.Add((New-Check 'Creds' 'WDigest UseLogonCredential' (Get-RegValue $wdig 'UseLogonCredential')  @(0, 'Not set') 'Cleartext passwords in LSASS'))

# LSA protection: the baseline GPO writes RunAsPPLBoot; the manual method writes RunAsPPL
$ppl     = Get-RegValue $lsa 'RunAsPPL'
$pplBoot = Get-RegValue $lsa 'RunAsPPLBoot'
$pplSet  = ($ppl -in 1, 2) -or ($pplBoot -in 1, 2)
$results.Add((New-Check 'Creds' 'LSA protection configured' ("RunAsPPL={0}; RunAsPPLBoot={1}" -f $ppl, $pplBoot) 'RunAsPPL or RunAsPPLBoot = 1 or 2' 'LSASS dumping (T1003.001)' $pplSet))

# Live check: a protected LSASS refuses module reads, even from an elevated admin
try   { $null = Get-Process -Name lsass -Module -ErrorAction Stop; $pplLive = $false }
catch { $pplLive = $true }
$results.Add((New-Check 'Creds' 'LSASS running protected' $pplLive $true 'LSASS dumping (T1003.001)'))
$results.Add((New-Check 'UAC'  'FilterAdministratorToken'    (Get-RegValue $uac 'FilterAdministratorToken') 1 'Built-in Administrator always elevated'))
$results.Add((New-Check 'Logging' 'Script block logging'     (Get-RegValue $psLog 'EnableScriptBlockLogging') 1 'PowerShell attacks leaving no 4104 events'))

# Audit policy: subcategories that detections in this lab rely on
$audit = auditpol /get /category:* /r | ConvertFrom-Csv
$auditTargets = [ordered]@{
    'Credential Validation'                 = 'Success and Failure'
    'Kerberos Authentication Service'       = 'Success and Failure'
    'Kerberos Service Ticket Operations'    = 'Success and Failure'
    'Directory Service Changes'             = 'Success'
    'Security Group Management'             = 'Success'
    'User Account Management'               = 'Success'
}
foreach ($sub in $auditTargets.Keys) {
    $row = $audit | Where-Object Subcategory -eq $sub
    $value  = if ($row) { $row.'Inclusion Setting' } else { 'Not found' }
    $target = $auditTargets[$sub]
    # "Success and Failure" meets a "Success" target
    $ok = ($value -eq $target) -or ($value -eq 'Success and Failure')
    $results.Add((New-Check 'Audit' $sub $value $target 'Attacks leaving no security events' $ok))
}
$results.Add((New-Check 'Audit' 'Subcategories with No Auditing' (@($audit | Where-Object 'Inclusion Setting' -eq 'No Auditing')).Count 'info' 'Overall logging coverage'))

# Firewall and Print Spooler
$fwOff = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count
$results.Add((New-Check 'Firewall' 'Profiles turned off' $fwOff 0 'Exposed services'))

$spooler = Get-Service -Name Spooler
$results.Add((New-Check 'Services' 'Print Spooler start type' $spooler.StartType 'Disabled' 'PrintNightmare, PrinterBug (T1187)'))

$results | Format-Table Area, Setting, Value, Target, Pass -AutoSize

$passed = @($results | Where-Object { $_.Target -ne 'info' -and $_.Pass }).Count
$total  = @($results | Where-Object { $_.Target -ne 'info' }).Count
Write-Host ("{0}: {1} of {2} checks at target" -f $Label, $passed, $total)

if ($CsvPath) {
    if (-not (Test-Path $CsvPath)) { New-Item -Path $CsvPath -ItemType Directory | Out-Null }
    $file = Join-Path $CsvPath ("Get-HardeningState_{0}_{1:yyyyMMdd-HHmm}.csv" -f $Label, (Get-Date))
    $results | Export-Csv -Path $file -NoTypeInformation
    Write-Host "Saved: $file"
}
