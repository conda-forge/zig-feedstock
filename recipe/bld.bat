@echo off
:: powershell -File "%RECIPE_DIR%\x86_64-windows.ps1"

:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "HOST_TARGET=x86_64-windows-msvc"
set "TARGET=x86_64-windows-gnu"
set "MCPU=native"
set "ZIG=%SRC_DIR%\zig-bootstrap\zig.exe"

%ZIG% build ^
  --prefix "%PREFIX%" ^
  --search-prefix "%PREFIX%\Library" ^
  -Dflat ^
  -Doptimize=ReleaseFast ^
  -Dstrip ^
  -Dversion-string="%ZIG_VERSION%"
::  -Denable-llvm ^
::  -Dtarget="%TARGET%" ^
::  -Dcpu="%MCPU%" ^
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
