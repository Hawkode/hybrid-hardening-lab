# 01 - Build the DC

Windows Server 2025 evaluation on Hyper-V, promoted to a new forest `hawkode.lab`.

## Prerequisites

- Windows 11 Pro host with Hyper-V enabled
- Hyper-V External switch bound to the host's NIC (VMs need internet for activation and, later, Entra Connect)
- Windows Server 2025 evaluation ISO from the Microsoft Evaluation Center

Check Hyper-V on the host:

```powershell
# Host > PowerShell (admin)
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V   # State: Enabled
```

## VM settings

`Hyper-V Manager > New > Virtual Machine`

| Setting | Value | Why |
|---|---|---|
| Name | `DC01` | |
| Generation | 2 | UEFI, Secure Boot, vTPM |
| Memory | 4096 MB, Dynamic Memory off | A DC prefers fixed memory |
| Network | External switch | |
| Disk | 60 GB, dynamically expanding | |
| Processor | 2 vCPU | |
| Security | Trusted Platform Module on | Needed later for BitLocker and Credential Guard |
| Automatic checkpoints | Off | Stops a checkpoint being taken at every start |

Install Server 2025 with Desktop Experience from the ISO.

## Static IP and rename

A DC needs a fixed address, and it points DNS at itself.

```powershell
# DC01 > PowerShell (admin)
$if = "Ethernet"
Set-NetIPInterface -InterfaceAlias $if -Dhcp Disabled
Remove-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -Confirm:$false
Remove-NetRoute -InterfaceAlias $if -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $if -IPAddress 192.0.2.10 -PrefixLength 24 -DefaultGateway 192.0.2.1
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 192.0.2.10
Rename-Computer -NewName DC01 -Restart
```

Pick an address outside the router's DHCP pool, or reserve it.

## Promote to a new forest

```powershell
# DC01 > PowerShell (admin)
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName "hawkode.lab" -DomainNetbiosName "HAWKODE" -InstallDns -Force
```

- It prompts for the DSRM (Directory Services Restore Mode) password. Store it in a password manager.
- `hawkode.lab` is a non-routable lab name. The UPN suffix for Entra sync is set separately in phase 2.

## DNS forwarders

After promotion the DC resolves only its own zone. Forwarders bring internet name resolution back.

```powershell
# DC01 > PowerShell (admin)
Set-DnsServerForwarder -IPAddress 1.1.1.1,8.8.8.8
Resolve-DnsName microsoft.com
```

## Verify

```powershell
Get-ADDomain | Select-Object DNSRoot, DomainMode   # hawkode.lab, Windows2025Domain
nltest /dsgetdc:hawkode.lab                        # finds DC01
Get-NetIPConfiguration                             # static IP, DNS = itself
```

## Checkpoint

`Hyper-V Manager > DC01 > Checkpoint > rename to Clean DC`

This is the "before" state for the scans.

## Rollback

It's a lab: delete the VM and rebuild. To demote instead: `Uninstall-ADDSDomainController`.
