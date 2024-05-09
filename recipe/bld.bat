@echo off
:: powershell -File "%RECIPE_DIR%\x86_64-windows.ps1"

:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "TARGET=x86_64-windows-msvc"
set "MCPU=native"
set "ZIG=%SRC_DIR%\zig-bootstrap\zig.exe"

%ZIG% build ^
  --prefix "%PREFIX%" ^
  --search-prefix "%PREFIX%\Library" ^
  -Dflat ^
  -Denable-llvm ^
  -Doptimize=ReleaseFast ^
  -Dstrip ^
  -Dversion-string="%ZIG_VERSION%"
::  -Dtarget="%TARGET%" ^
::  -Dcpu="%MCPU%" ^
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
