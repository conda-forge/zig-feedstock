@echo off
REM Zig compiler deactivation script for Windows
REM Installed to: %PREFIX%\etc\conda\deactivate.d\zig_deactivate.bat

REM === Unset toolchain variables ===
set "CONDA_ZIG_CC="
set "CONDA_ZIG_CXX="
set "CONDA_ZIG_AR="
set "CONDA_ZIG_LD="
set "ZIG_TARGET_TRIPLET="
