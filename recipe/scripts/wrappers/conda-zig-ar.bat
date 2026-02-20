@echo off
REM Zig archiver wrapper for Windows
if defined CONDA_ZIG_AR (
    %CONDA_ZIG_AR% %*
) else (
    zig ar %*
)
