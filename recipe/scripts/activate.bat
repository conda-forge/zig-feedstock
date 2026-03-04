@echo off
REM Zig compiler activation script for Windows
REM Installed to: %PREFIX%\etc\conda\activate.d\zig_activate.bat
REM
REM Exports ZIG_CC, ZIG_CXX, etc. pointing to pre-installed wrapper scripts
REM in %CONDA_PREFIX%\Library\share\zig\wrappers\

set "_CROSS_TARGET_TRIPLET=@CROSS_TARGET_TRIPLET@"

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
if exist "%_wrapper_dir%\zig-cc.bat"     set "ZIG_CC=%_wrapper_dir%\zig-cc.bat"
if exist "%_wrapper_dir%\zig-cxx.bat"    set "ZIG_CXX=%_wrapper_dir%\zig-cxx.bat"
if exist "%_wrapper_dir%\zig-ar.bat"     set "ZIG_AR=%_wrapper_dir%\zig-ar.bat"
if exist "%_wrapper_dir%\zig-ranlib.bat" set "ZIG_RANLIB=%_wrapper_dir%\zig-ranlib.bat"
if exist "%_wrapper_dir%\zig-asm.bat"    set "ZIG_ASM=%_wrapper_dir%\zig-asm.bat"
if exist "%_wrapper_dir%\zig-rc.bat"     set "ZIG_RC=%_wrapper_dir%\zig-rc.bat"

:cleanup
set "_CROSS_TARGET_TRIPLET="
set "_wrapper_dir="
