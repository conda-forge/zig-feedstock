@echo off
REM Zig compiler deactivation script (non-unix)
REM Installed to: %PREFIX%\etc\conda\deactivate.d\zig_deactivate.bat

REM === Unset all zig variables ===
set "ZIG="
set "ZIG_CC="
set "ZIG_CXX="
set "ZIG_AR="
set "ZIG_RANLIB="
set "ZIG_ASM="
set "ZIG_RC="
set "ZIG_RC_CMAKE="
set "ZIG_LLD="
set "ZIG_FORCE_LOAD_CC="
set "ZIG_FORCE_LOAD_CXX="

REM === Unset toolchain identification ===
set "CONDA_ZIG_BUILD="
set "CONDA_ZIG_HOST="

REM === Unset cache directory ===
set "ZIG_GLOBAL_CACHE_DIR="

REM === Unset cross-compiler variables ===
set "ZIG_TARGET_TRIPLET="
