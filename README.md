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
