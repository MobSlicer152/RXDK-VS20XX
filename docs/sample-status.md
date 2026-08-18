# XDK sample sweep — status and open items

Running status for the 190-sample regression sweep under xemu and the library
fixes that came out of it. Sweep entry points live in `scripts/`
(`Invoke-SampleSweep.ps1`, `Invoke-SampleRunSweep.ps1`,
`Get-SampleRunReport.ps1`).

## Running a sweep, and where the evidence lands

```powershell
scripts\Invoke-SampleRunSweep.ps1 -OutDir "$env:TEMP\rxdk-sweep-<name>"
scripts\Get-SampleRunReport.ps1   -OutDir "$env:TEMP\rxdk-sweep-<name>"
```

A full sweep takes roughly an hour and writes four files per sample into
`-OutDir`: `<Sample>.a<attempt>.png` (the final-frame screenshot, which is the
actual evidence — the serial trace alone cannot tell a rendering title from a
wedged one), plus `.log`, `.stdout.txt` and `.stderr.txt`. `Get-SampleRunReport`
re-reads those logs and screenshots to produce the verdicts, so classification
can be revised without booting every title again.

**Always pass `-OutDir`.** It defaults to `$env:TEMP\rxdk-runsweep` and the
script wipes that directory on entry, so an unnamed run destroys the previous
one's screenshots. The last trustworthy full runs are
`$env:TEMP\rxdk-sweep-postconv` (182 shots, the post-calling-convention sweep
this status reflects) and `$env:TEMP\rxdk-runsweep-honest` (189, the first with
corrected verdicts). Being under `TEMP`, they are one cleanup away from gone —
copy a run somewhere durable before relying on it as a baseline.

xemu's own F12 screenshots go to `D:\Git\xemu-devkit\screenshots`, which the
sweep empties before each attempt so a grab can tell its own shot from a stale
one.

Latest full sweep after the calling-convention fix: **152 RUNS, 25 with no
framework, 3 stopped in main, 1 emulator abort** — the whole
UIX / SimpleVoice / FastLoad cluster is fixed.

## Recently closed (for context, do not redo)

- **Calling convention.** libxonline's UIX engine was built `/Gz` (stdcall)
  against a cdecl libc. This one bug accounted for six silent-init samples: all
  five UIX samples plus SimpleVoice. `scripts/Test-CallingConventions.ps1` is a
  permanent guard.
- **Push-buffer desync.** The driver could lap the GPU because `GpuGet`
  reported a stale or backwards position. Ported 5849's
  `GpuGet`/`GpuGetOrNewer`/`ComputeGap` plus the fence progress stamp; seven
  aborting samples now run, and a 190-sample sweep showed 181 ISOs, 0 aborts,
  0 regressions.
- **`XONLINE_USER` ABI.** The library used the leak's 128-byte layout where
  5849 uses 112, which smashed the stack.
- **Xbox Live cluster.** Task-status ABI, kernel HD key, wide debug output.
  HMAC-signed local accounts are seeded into the HDD so account-gated samples
  reach their UI; every Networking/Live sample now fails gracefully with no
  Live servers.
- **FastLoad.** libdsound's WMA `ReadAt` handed multi-KB reads to the title
  callback; now chunked to 128 bytes.
- **DMTool.** `Media\Sounds` was missing, so a failed segment load left a NULL
  pointer that `SetRepeats` faulted on. Media restored, ISO rebuilt.
- **Sweep trustworthiness.** Screenshot capture no longer depends on window
  focus; verdicts come from cross-title frame comparison rather than counting
  the BIOS splash as a presented frame; a hard wall-clock kill plus an
  `IsHungAppWindow` guard stops `PrintWindow` blocking forever on a hung
  emulator.
- **All 6 `.uix` skins** are authored and on their discs (five from the shared
  `default.inx`, UIXKeyboard from its own), which took the missing-media count
  from eight samples to two.

## Open items

### Missing or incomplete media
- **Fur** shader `.xvu` files and **SpeechRecognition**'s `SampleSRBank_en.xsr`
  are still absent.
- **PolynomialTextureMaps** needs 46 `TestImage` BMPs — this is why its quad
  never rasterizes, so the media gap and the blank-quad symptom are one item.
- **GlobalFX** references `d:\media\image.bin`, which is not on its disc.

### Behaviour to investigate
- **DMTool** renders its text but no note quads and no audio level meters, and
  the frame never changes. Check whether libdmusic delivers note PMSGs to the
  title's `IDirectMusicTool`.
- **SilentAuth** is now *stopped in main*. Compare against the earlier baseline
  to decide whether this is a regression.
- **UIX samples** present a menu once and then never change. That may be correct
  for a text menu awaiting input — needs a triage pass to confirm.
- Triage the remaining static-frame samples against the corrected screenshots,
  then work through the leftover failure clusters and re-verify each fix.

### Emulator gaps (not RXDK bugs)
- **Render target aliased as a vertex stream** reads stale guest RAM, because
  xemu never writes rendered surfaces back. Affects PaintEffect and
  DisplacementMap.
- **`D3DFMT_V16U16`** is missing from xemu and aborts HighQualityBumpMapping.
  Our format table matches the leak byte-for-byte, so the choice is to add the
  format to xemu or accept that the sample cannot run.
- **BeginPush and CrashDump** wedge on the BIOS splash: the guest spins forever
  in the kernel's IDE status poll (port `0x1F7`, BSY), inside xbdm.dll's LBA28
  PIO routine with the drive stuck at `BSY=0xD0`. No RXDK frame is on the call
  chain. Untested theory worth trying: give xemu an explicitly raw HDD image and
  re-run both.

### Build and distribution
- **Build-graph gap:** `zig build libxonline` does not rebuild libuix (it is a
  separate archive), and a plain `zig build` misses the subsystem libs. This
  matters for the distribution.
- **Publish a full Debug + ReleaseSmall library distribution.**

### Host tools
See `RXDK-Tools/docs/skinbld-bundler-parity.md` for the `.uix`/`.xpr`
byte-parity work: what is already exact, the remaining tasks, how to resume
them, and the findings that were expensive to reach.

`skinbld` is built by `RXDKTools.sln` and published into every platform's
managed tool bundle, so it arrives with the rest of the host tools. It is not in
`HostToolsInstaller.RequiredHostTools` yet — add it there in the same change that
teaches `XboxBuild.cs` to compile `.inx` skins, so no install is declared
incomplete before a release carries the tool.
