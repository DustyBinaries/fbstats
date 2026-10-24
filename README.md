# Firebird · Size statistics (Delphi 7 + Borion)

🇧🇷 [Leia em português](README_pt-BR.md)

Firebird size statistics tool written in Delphi 7 using the [Borion framework](https://github.com/DustyBinaries/Borion/).
Web interface (`web\`) and analysis: Services API (gstat), page census of the `.fdb`,
BLOB column measurement, duplication between BLOBs and observations.

## Building

    set DELPHI=C:\Program Files (x86)\Borland\Delphi7
    build.bat

Produces `fbstats.exe` (the interface is embedded). Or use `borion dev` to reload the interface on save.

## Usage

    fbstats.exe                      # opens the window
    fbstats.exe C:\data\database.fdb # opens and analyzes the database on startup
    fbstats.exe --selftest C:\data\database.fdb [user] [password] [--no-census] [--no-blobs] [--dup]
                                     # no window; JSON on stdout, progress on stderr

The exe is **32-bit** (Delphi 7): it needs the **32-bit** `fbclient.dll` (next to the .exe, in the
Firebird `WOW64` folder, or in `C:\Windows\SysWOW64`). The search ignores 64-bit DLLs.
Since the exe is a GUI app, to capture `--selftest` output to a file use `Start-Process -Wait -RedirectStandardOutput`.

## Structure

- `FbApi.pas`       fbclient binding (Services API + DSQL), loaded dynamically
- `FbAnalysis.pas`  header, census, gstat parsing, BLOBs, duplication, observations, report JSON
- `fbstats.dpr` Borion commands (`analyze` in a thread, `cancel_analysis`, `default_fbclient`, `startup_db`, `save_text`)
- `web\`            interface (HTML/CSS/JS), using `window.borion`
