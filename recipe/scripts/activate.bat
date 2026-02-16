@echo off
REM Zig compiler activation script for Windows
REM Installed to: %PREFIX%\etc\conda\activate.d\zig_activate.bat

REM === Toolchain configuration (user-overridable) ===
if not defined CONDA_ZIG_CC set "CONDA_ZIG_CC=@CC@"
if not defined CONDA_ZIG_CXX set "CONDA_ZIG_CXX=@CXX@"
if not defined CONDA_ZIG_AR set "CONDA_ZIG_AR=@AR@"
if not defined CONDA_ZIG_LD set "CONDA_ZIG_LD=@LD@"
