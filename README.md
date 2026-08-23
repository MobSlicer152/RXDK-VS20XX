# RXDK for Visual Studio

<p align="center"><b>Original Xbox development in Visual Studio 2022 / 2026 — project templates, build, deploy, and native debugging for the open RXDK SDK</b></p>

<p align="center">
  <a href="https://github.com/Team-Resurgent/RXDK-VS20XX/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <a href="https://github.com/Team-Resurgent/RXDK-VS20XX/actions/workflows/build-vsix.yml"><img src="https://github.com/Team-Resurgent/RXDK-VS20XX/actions/workflows/build-vsix.yml/badge.svg" alt="Build"></a>
  <a href="https://discord.gg/VcdSfajQGK"><img src="https://img.shields.io/badge/chat-on%20discord-7289da.svg?logo=discord" alt="Discord"></a>
</p>

<p align="center">
  <a href="https://ko-fi.com/J3J7L5UMN"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="ko-fi"></a>
  <a href="https://www.patreon.com/teamresurgent"><img src="https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white" alt="Patreon"></a>
</p>

<p align="center">
  <a href="https://github.com/Team-Resurgent/RXDK-VS20XX/releases/latest"><img src="https://img.shields.io/badge/download-latest-brightgreen.svg?style=for-the-badge&logo=github" alt="Download"></a>
</p>

A Visual Studio 2022 / 2026 extension for building homebrew for the original Xbox
against **[RXDK](https://github.com/Team-Resurgent/RXDK-Libs)** — the open,
self-contained, MSVC-free Xbox SDK. It is the Visual Studio counterpart to the
[RXDK VS Code extension](https://github.com/Team-Resurgent/RXDK-VSCode), sharing the
same on-disk layout (`%ProgramData%\RXDK`) and the same headers/libs from
[RXDK-SDK](https://github.com/Team-Resurgent/RXDK-SDK).

## Features

- **Project templates** — Original Xbox Game, Empty, Lib, DXT, Controller Input,
  Font Scroller, Network Server, Video Player, and multi-project samples (Cube,
  Music Visualizer).
- **Native build / deploy / debug** — press **F5**: the extension builds the `.xbe`,
  deploys it to the devkit over XBDM, and attaches the debugger (via a managed Debug
  Adapter). Deploy to Xbox and Remove DXT are on the project's right-click menu.
- **RXDK tool window** — set the devkit IP, warm-reboot, open the SDK / tools / docs
  folders, launch xbWatson and Xbox Neighborhood, browse the docs, and manage the
  installed components.
- **One-click setup** — installs the host tools, SDK, docs, and the Zig toolchain
  into `%ProgramData%\RXDK`, and shows the **installed vs available** version of each
  component with a per-component (and *Update All*) update button.
- **VS2003 project import** — bring a classic XDK `.vcproj` / `.sln` forward to an
  RXDK project.

## Getting started

1. Install the VSIX from the [latest release](https://github.com/Team-Resurgent/RXDK-VS20XX/releases/latest)
   (or build it — see below), then restart Visual Studio.
2. Open the **RXDK** tool window (View ▸ Other Windows ▸ RXDK, or the RXDK menu) and
   click **Install Prerequisites**. This downloads the SDK, host tools, docs, and Zig.
3. **File ▸ New ▸ Project**, filter by the **Xbox** tag, and pick a template.
4. Set your devkit IP in the tool window, then press **F5** to build, deploy, and debug.

## Building the extension

Requires Visual Studio 2022/2026 with the **Visual Studio extension development**
workload. The out-of-process engine/adapter (`Rxdk.Cli`, `Rxdk.Dap`) target .NET 8.

```powershell
msbuild RxdkVs.Package\RxdkVs.Package.csproj /p:Configuration=Release
```

The built `RxdkVs.Package.vsix` lands under `RxdkVs.Package\bin\Release`.

## Repository layout

| Path | Purpose |
|------|---------|
| `RxdkVs.Package/` | The VSIX package: tool window, commands, project templates, VS integration (.NET Framework) |
| `Rxdk.Engine/` | Pure-.NET build/deploy/staging engine (.NET 8) |
| `Rxdk.Cli/` | Thin CLI over the engine that the package shells out to |
| `Rxdk.Dap/` | Debug Adapter (DAP) the VS Debug Adapter Host launches for F5 debugging |

## Related projects

- **[RXDK-Libs](https://github.com/Team-Resurgent/RXDK-Libs)** — the open Xbox runtime/SDK sources
- **[RXDK-SDK](https://github.com/Team-Resurgent/RXDK-SDK)** — the consumer SDK package (headers + libs)
- **[RXDK-Tools](https://github.com/Team-Resurgent/RXDK-Tools)** — host-side build & deploy tools
- **[RXDK-Docs](https://github.com/Team-Resurgent/RXDK-Docs)** — in-editor documentation
- **[RXDK-Samples](https://github.com/Team-Resurgent/RXDK-Samples)** — the ported XDK sample suite
- **[RXDK-VSCode](https://github.com/Team-Resurgent/RXDK-VSCode)** — the VS Code extension

## License

GPLv3 — see [LICENSE.md](LICENSE.md).
