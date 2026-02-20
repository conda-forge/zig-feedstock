@echo off
REM Zig compiler deactivation script for Windows
REM Installed to: %PREFIX%\etc\conda\deactivate.d\zig_deactivate.bat

REM === Unset cross-compiler variables ===
set "ZIG_TARGET_TRIPLET="
