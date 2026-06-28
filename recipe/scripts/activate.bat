@echo off
REM Zig compiler activation script (non-unix)
REM Installed to: %PREFIX%\etc\conda\activate.d\zig_activate.bat
REM
REM Exports ZIG_CC, ZIG_CXX, etc. pointing to compiled wrappers
REM in %CONDA_PREFIX%\Library\bin\

set "_CONDA_TRIPLET=@CONDA_TRIPLET@"
set "_CROSS_TARGET_TRIPLET=@CROSS_TARGET_TRIPLET@"

REM === Zig toolchain identification ===
REM These variables identify the zig binary name without depending on gcc's TOOLCHAIN.
REM CONDA_ZIG_BUILD = build machine zig binary name (e.g. x86_64-w64-mingw32-zig)
REM CONDA_ZIG_HOST  = target machine zig binary name (e.g. x86_64-w64-mingw32-zig)
set "CONDA_ZIG_BUILD=@CONDA_ZIG_BUILD@"
set "CONDA_ZIG_HOST=@CONDA_ZIG_HOST@"

REM === Cross-compiler variable (set only for cross builds) ===
if not "%_CROSS_TARGET_TRIPLET%"=="" (
    set "ZIG_TARGET_TRIPLET=%_CROSS_TARGET_TRIPLET%"
)

REM === Export variables ===
set "_zig_bin=%CONDA_PREFIX%\Library\bin\@CONDA_TRIPLET@-zig.exe"
if exist "%_zig_bin%" set "ZIG=%_zig_bin%"

if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-cc.exe"     set "ZIG_CC=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-cc.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-cxx.exe"    set "ZIG_CXX=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-cxx.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-ar.exe"     set "ZIG_AR=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-ar.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-ranlib.exe" set "ZIG_RANLIB=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-ranlib.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-asm.exe"    set "ZIG_ASM=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-asm.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-rc.exe" (
    set "ZIG_RC=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-rc.exe"
    setlocal enabledelayedexpansion
    set "_rc_path=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-rc.exe"
    for /f "tokens=* delims=" %%F in ("!_rc_path:\=/!") do endlocal & set "ZIG_RC_CMAKE=%%F"
)
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-lld.exe" set "ZIG_LLD=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-lld.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-force-load-cc.exe"  set "ZIG_FORCE_LOAD_CC=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-force-load-cc.exe"
if exist "%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-force-load-cxx.exe" set "ZIG_FORCE_LOAD_CXX=%CONDA_PREFIX%\Library\bin\%_CONDA_TRIPLET%-zig-force-load-cxx.exe"

REM === Ensure zig can resolve a writable cache directory ===
REM Short %TEMP% path also avoids a cold-compile integer-overflow panic seen
REM with long cache paths when cross-compiling *-windows-gnu (PR #120).
REM Mirrors the recipe build (ZIG_GLOBAL_CACHE_DIR=%TEMP%\zig-cache).
if not defined ZIG_GLOBAL_CACHE_DIR set "ZIG_GLOBAL_CACHE_DIR=%TEMP%\zig-cache"

:cleanup
set "_CONDA_TRIPLET="
set "_CROSS_TARGET_TRIPLET="
set "_zig_bin="
set "_rc_path="
