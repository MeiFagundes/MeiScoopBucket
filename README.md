# Mei's Scoop Bucket

[![Tests](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/ci.yml/badge.svg)](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/ci.yml) [![Excavator](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/excavator.yml/badge.svg)](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/excavator.yml)

My personal bucket for [Scoop](https://scoop.sh), the Windows command-line installer.

## Install

```powershell
scoop bucket add mei https://github.com/MeiFagundes/MeiScoopBucket
```

Then install an app from the bucket, for example:

```powershell
scoop install mei/zapfast
```

## Apps

| Manifest | App | Architectures | Additional Info |
| --- | --- | --- | --- |
| `zapfast` | [ZapFast](https://zapfast.rocks), a lightweight native WhatsApp client | x64, ARM64 | Settings stay in `%APPDATA%\paolino\zapfast\config`, and sessions, archives, and caches stay in `%LOCALAPPDATA%\paolino\zapfast`. Scoop upgrades and uninstalls leave these folders intact. See ZapFast's [settings and files documentation](https://zapfast.rocks/settings-and-files/). |
| `mvoltplus` | [mVolt+](https://github.com/b00nz/mVolt), NVIDIA GPU tuning and monitoring | x64 | mVolt+ is distributed as the official standalone Windows executable from the [upstream GitHub releases](https://github.com/b00nz/mVolt/releases). Profiles and preferences remain in `%LOCALAPPDATA%\mVolt+`, Scoop upgrades do not relocate or remove them. The upstream guide documents its [profile storage location](https://github.com/b00nz/mVolt/blob/main/docs/guide.md#files-and-logging). |
| `sidequest` | [SideQuest](https://github.com/SideQuestVR/SideQuest), desktop app for sideloading and managing apps on VR headsets | x64 | Uses the official Windows ZIP from [GitHub releases](https://github.com/SideQuestVR/SideQuest/releases) and adds a Start menu shortcut. Update with `scoop update sidequest`. |

## mVolt+ profile protection

Before a Scoop install or upgrade, the mVolt+ manifest snapshots the existing
profile JSON and adjacent `.bak` file to
`%LOCALAPPDATA%\mVoltPlus-ProfileBackups`. Snapshots include hashes, schema,
GPU/VBIOS identity, profile IDs, and available executable versions. Unchanged
profile documents are deduplicated. The newest 30 valid snapshots per GPU and
the newest snapshot containing the protected `Mei UV / OC / XBAR` profile are
retained. Incident snapshots and existing recovery folders in Documents are
not pruned.

The local `scripts\mvoltplus-profile-guard.ps1` health check can report when
that protected profile is missing. The per-user `Mei mVolt+ Profile Backup`
task runs it at logon and every five minutes without elevation.

To recover, close mVolt+, copy the current profile directory aside, and inspect
the snapshot's `metadata.json`. Restore the original JSON and adjacent `.bak`
bytes only when the GPU/VBIOS identity matches and the installed mVolt+ version
supports that schema. Reopen the app and confirm the profile list before
applying anything. Do not merge documents or relabel schemas. The guard never
restores profiles or applies tuning.

## Automation

- CI runs the template's Scoop tests on Windows PowerShell and PowerShell 7
  for pushes and pull requests, and can be started manually.
- Excavator checks for new releases every four hours and can be started
  manually. Automated updates use the Scoop template's bot identity.
- The template's issue and pull request handlers remain enabled.

## Contributing

Read Scoop's [contribution guide](https://github.com/ScoopInstaller/.github/blob/main/.github/CONTRIBUTING.md) and [app manifest documentation](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests).
Create manifests in `bucket/`, using `bucket/app-name.json.template` as a starting point.

Useful checks from the repository root:

```powershell
.\bin\checkver.ps1 zapfast
.\bin\checkhashes.ps1 zapfast
.\bin\test.ps1
```

The test suite requires Pester 5.2.0 or newer and BuildHelpers 2.0.1 or newer,
CI installs these dependencies automatically.
