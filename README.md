# Mei's Scoop Bucket

[![Tests](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/ci.yml/badge.svg)](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/ci.yml) [![Excavator](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/excavator.yml/badge.svg)](https://github.com/MeiFagundes/MeiScoopBucket/actions/workflows/excavator.yml)

My personal bucket for [Scoop](https://scoop.sh), the Windows command-line installer.

## Install

```powershell
scoop bucket add mei https://github.com/MeiFagundes/MeiScoopBucket
scoop install mei/zapfast
scoop install mei/mvoltplus
```

## Apps

| Manifest | App | Architectures |
| --- | --- | --- |
| `zapfast` | [ZapFast](https://zapfast.rocks), a lightweight native WhatsApp client | x64, ARM64 |
| `mvoltplus` | [mVolt+](https://github.com/b00nz/mVolt), NVIDIA GPU tuning and monitoring | x64 |

ZapFast uses the official Windows ZIP releases. Scoop creates a `zapfast`
command and a Start menu shortcut. Update it with `scoop update zapfast`.
The portable updater marker is removed so updates remain managed by Scoop.

Settings stay in `%APPDATA%\paolino\zapfast\config`, and sessions, archives,
and caches stay in `%LOCALAPPDATA%\paolino\zapfast`. Scoop upgrades and
uninstalls leave these folders intact. See ZapFast's
[settings and files documentation](https://zapfast.rocks/settings-and-files/).

mVolt+ is distributed as the official standalone Windows executable from the
[upstream GitHub releases](https://github.com/b00nz/mVolt/releases). Scoop adds
the `mvoltplus` command and an `mVolt+` Start menu shortcut. Run the app as
administrator when tuning the GPU. Its profiles and preferences remain in
`%LOCALAPPDATA%\mVolt+`, outside the Scoop app directory, so Scoop upgrades do
not relocate or remove them. The upstream guide documents its
[profile storage location](https://github.com/b00nz/mVolt/blob/main/docs/guide.md#files-and-logging).
Update it with `scoop update mvoltplus`.

## Automation

- CI runs the template's Scoop tests on Windows PowerShell and PowerShell 7
  for pushes and pull requests, and can be started manually.
- Excavator checks for new releases every four hours and can be started
  manually. Automated updates use the Scoop template's bot identity.
- The template's issue and pull request handlers remain enabled.

Repository Actions settings allow all actions and reusable workflows, with
read-only default token permissions. Workflows request write permissions
only where the template's automation needs them.

## Contributing

Read Scoop's [contribution guide](https://github.com/ScoopInstaller/.github/blob/main/.github/CONTRIBUTING.md)
and [app manifest documentation](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests).
Create manifests in `bucket/`, using `bucket/app-name.json.template` as a starting point.

Useful checks from the repository root:

```powershell
.\bin\checkver.ps1 zapfast
.\bin\checkhashes.ps1 zapfast
.\bin\test.ps1
```

The test suite requires Pester 5.2.0 or newer and BuildHelpers 2.0.1 or newer;
CI installs these dependencies automatically.
