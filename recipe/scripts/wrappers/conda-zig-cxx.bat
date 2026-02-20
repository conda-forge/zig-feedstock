@echo off
REM Zig C++ compiler wrapper for Windows
if defined CONDA_ZIG_CXX (
    %CONDA_ZIG_CXX% %*
) else (
    zig c++ %*
)
