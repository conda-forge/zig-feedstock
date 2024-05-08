@echo off
:: powershell -File "%RECIPE_DIR%\x86_64-windows.ps1"

:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "TARGET=x86_64-windows-gnu"
set "MCPU=native"
set "ZIG=%SRC_DIR%\zig-bootstrap\zig.exe"

%ZIG% build ^
  --prefix "%PREFIX%" ^
  --search-prefix "%PREFIX%" ^
  -Dflat ^
  -Denable-llvm ^
  -Doptimize=ReleaseFast ^
  -Dstrip ^
  -Dtarget="%TARGET%" ^
  -Dcpu="%MCPU%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
