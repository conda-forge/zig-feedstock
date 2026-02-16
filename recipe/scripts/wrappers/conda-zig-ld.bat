@echo off
REM Zig linker wrapper for Windows
if defined CONDA_ZIG_LD (
    %CONDA_ZIG_LD% %*
) else (
    zig cc %*
)
