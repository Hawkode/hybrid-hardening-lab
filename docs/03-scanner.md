# 03 - Build the scanner

Kali Linux VM running Greenbone Community Edition (GVM, formerly OpenVAS). It scans DC01 before and after hardening, and doubles as the attack box for later phases.

## Why Kali

- GVM is packaged: `apt install gvm`, no containers needed.
- It has a desktop for the Greenbone web UI.
- The same VM is the attacker for the Attack and Detect phases.

## Prerequisites

- Kali Linux 64-bit **Installer** image (not Live, NetInstaller or Everything)
- DC01 shut down during the build, to free host RAM

## VM settings

`Hyper-V Manager > New > Virtual Machine`

| Setting | Value | Why |
|---|---|---|
| Name | `KALI01` | |
| Generation | 2 | |
| Memory | 4096 MB, Dynamic Memory off | 6 GB failed to start on a 16 GB host. 4 GB is Greenbone's minimum. |
| Network | External switch | Same network as DC01 |
| Disk | 60 GB, dynamically expanding | The feed and database take 20+ GB |
| Processor | 2 vCPU | |
| Secure Boot | **Off** | Kali won't boot with it on |
| Automatic checkpoints | Off | |

## Install

- `Graphical install`, English, United Kingdom, `en_GB.UTF-8`, British English keyboard
- Hostname `kali01`, no domain name. It is not joined to `hawkode.lab`.
- Non-root user (it gets sudo)
- Guided partitioning, entire disk, all files in one partition
- Software: defaults (Xfce, top10, default tools)
- GRUB to `/dev/sda`

## Update and checkpoint

```bash
# KALI01 > Terminal
ip -4 a show eth0        # address on the lab subnet
ping -c 3 1.1.1.1
sudo apt update && sudo apt full-upgrade -y
sudo poweroff
```

`Hyper-V Manager > KALI01 > Checkpoint > rename to Clean Kali`

## Install GVM

```bash
# KALI01 > Terminal
sudo apt install -y gvm
sudo gvm-setup           # prints the admin password once - store it
sudo gvm-check-setup     # should end with "installation is OK"
sudo gvm-start
```

Web UI: `https://127.0.0.1:9392`, user `admin`.

Feed timings on 4 GB RAM:

| Stage | Time |
|---|---|
| `apt install gvm` | 5-10 min |
| `gvm-setup`: Notus, NASL, SCAP, CERT and GVMD data | 30-90 min |
| `gvmd` loading the feed after setup | 30-60+ min |

Ready to scan when `Administration > Feed Status` shows every feed as `Current`.

## Gotchas

| Problem | Cause | Fix |
|---|---|---|
| Black screen or no boot image | Secure Boot on | Turn the VM off, untick Secure Boot |
| `Unable to allocate 6144 MB of RAM` | Static memory needs the full amount free at start | Shut DC01 down, close host apps, or drop to 4096 MB |
| Paste doesn't work in the console | Basic Hyper-V session | `VM window > Clipboard > Type clipboard text` |
| Feed download stalls | Host went to sleep | Host sleep off, charger in, Kali screen lock off during the sync |
| `gvmd` or `ospd-openvas` crashes mid-scan | Out of RAM | Close host apps, scan one host at a time |
| Start is greyed out: "Feed is currently syncing" | After a reboot, `ospd-openvas` reloads the VTs into its cache (about 4 min) | Wait for `Finished loading VTs` in `/var/log/gvm/ospd-openvas.log` |
| Admin password doesn't work after a change | Shell quoting, or UK/US keyboard mismatch in the console | Reset it, using letters, numbers and hyphens in single quotes (below) |
| `sudo: unable to resolve host` after renaming | Hostname changed before `/etc/hosts` | Update the `127.0.1.1` line in `/etc/hosts` first, then `hostnamectl` |
| DC01 won't start after applying a checkpoint | The checkpoint restores its saved state and its 4 GB memory setting | `Remove-VMSavedState`, then set memory again (below) |

Reset the GVM admin password:

```bash
sudo runuser -u _gvm -- gvmd --user=admin --new-password='<password>'
```

Make DC01 fit after applying a checkpoint:

```powershell
# Host > PowerShell (admin)
Stop-VM DC01 -TurnOff -Force -ErrorAction SilentlyContinue
if ((Get-VM DC01).State -eq 'Saved') { Remove-VMSavedState -VMName DC01 }
Set-VMMemory -VMName DC01 -DynamicMemoryEnabled $false -StartupBytes 2GB
Start-VM DC01
```

Copy a report out of the VM (the basic Hyper-V console has no clipboard out):

```bash
cd ~/Downloads && python3 -m http.server 8000   # browse to http://<kali-ip>:8000 from the host, Ctrl+C when done
```

## Status

- KALI01 built and updated, hostname `kali01`
- GVM installed, all feeds `Current`
- Unauthenticated "after" scan done, "before" scan in progress: see [04 - Scan results](04-scan-results.md)

## Rollback

`Hyper-V Manager > KALI01 > Clean Kali > Apply`
