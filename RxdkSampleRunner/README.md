# RXDK Sample Runner

An Avalonia desktop tool to batch-test the XDK samples — build them, boot the
resulting ISO in **xemu**, and (optionally) deploy + run on a real devkit.

## Run

```
dotnet run --project RxdkSampleRunner/RxdkSampleRunner.csproj
```

(Standalone — not part of RXDK-VS20XX.sln, so `dotnet build` on it won't drag in
the VSIX project.)

## What it does

* **Samples root** — point it at a folder (e.g. `XDKSamples`); it lists every
  `*.vcxproj` under it and shows whether each has a built ISO (`out\XISO\*.iso`).
* **Build** / **Build All** — runs `msbuild <vcxproj> /p:Configuration=<cfg>;Platform=Xbox`
  (the `Rxdk.Xbox.targets` generate the manifest and produce the ISO). MSBuild is
  found via `vswhere`.
* **xemu** — clears the console pane, then runs
  `xemu <params> -dvd_path <iso>` and streams the output. The default params
  `-device lpc47m157 -serial stdio` route the Xbox serial console to the pane, so
  you see the title's output live. The pane auto-scrolls and is cleared on every
  launch.
* **HW** — deploys and runs the built title on the devkit via the rxdk CLI
  (`%ProgramData%\RXDK\engine\Rxdk.Cli.exe`), using the *Xbox IP* if set.

## Settings

Persisted to `%AppData%\RxdkSampleRunner\settings.json`: xemu path + params,
samples root, devkit IP, build configuration, and optional CLI/MSBuild overrides.
