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
  -Dstatic-llvm ^
  -Doptimize=ReleaseFast ^
  -Dstrip ^
  -Dtarget="%TARGET%" ^
  -Dcpu="%MCPU%" ^
  -Dversion-string="%ZIG_VERSION%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
