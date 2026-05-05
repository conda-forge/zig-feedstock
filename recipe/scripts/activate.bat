@echo off
REM Zig compiler activation script (non-unix)
REM Installed to: %PREFIX%\etc\conda\activate.d\zig_activate.bat
REM
REM Exports ZIG_CC, ZIG_CXX, etc. pointing to pre-installed wrapper scripts
REM in %CONDA_PREFIX%\Library\share\zig\wrappers\

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

REM === Wrapper directory (pre-installed at build time) ===
set "_wrapper_dir=%CONDA_PREFIX%\Library\share\zig\wrappers"

if not exist "%_wrapper_dir%" (
    echo WARNING: zig-cc activation: wrapper directory not found: %_wrapper_dir% 1>&2
    goto :cleanup
)

REM === Export variables ===
set "_zig_bin=%CONDA_PREFIX%\Library\bin\@CONDA_TRIPLET@-zig.exe"
if exist "%_zig_bin%" set "ZIG=%_zig_bin%"

if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-cc.exe"     set "ZIG_CC=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-cc.exe"
if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-cxx.exe"    set "ZIG_CXX=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-cxx.exe"
if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-ar.bat"     set "ZIG_AR=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-ar.bat"
if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-ranlib.bat" set "ZIG_RANLIB=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-ranlib.bat"
if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-asm.bat"    set "ZIG_ASM=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-asm.bat"
if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-rc.bat" (
    set "ZIG_RC=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-rc.bat"
    set "ZIG_RC_CMAKE=%_wrapper_dir:\=/%/%_CONDA_TRIPLET%-zig-rc.bat"
)
if exist "%_wrapper_dir%\%_CONDA_TRIPLET%-zig-ld.bat" set "ZIG_LLD=%_wrapper_dir%\%_CONDA_TRIPLET%-zig-ld.bat"

:cleanup
set "_CONDA_TRIPLET="
set "_CROSS_TARGET_TRIPLET="
set "_wrapper_dir="
set "_zig_bin="
