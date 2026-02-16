@echo off
REM Zig C compiler wrapper for Windows
if defined CONDA_ZIG_CC (
    %CONDA_ZIG_CC% %*
) else (
    zig cc %*
)
