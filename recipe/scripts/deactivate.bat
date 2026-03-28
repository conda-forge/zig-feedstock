@echo off
REM Zig compiler deactivation script (non-unix)
REM Installed to: %PREFIX%\etc\conda\deactivate.d\zig_deactivate.bat

REM === Unset all zig-cc variables ===
set "ZIG_CC="
set "ZIG_CXX="
set "ZIG_AR="
set "ZIG_RANLIB="
set "ZIG_ASM="
set "ZIG_RC="
set "ZIG_RC_CMAKE="
set "ZIG_CXX_SHARED="

REM === Unset toolchain identification ===
set "CONDA_ZIG_BUILD="
set "CONDA_ZIG_HOST="

REM === Unset cross-compiler variables ===
set "ZIG_TARGET_TRIPLET="
