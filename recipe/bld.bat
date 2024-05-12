@echo off
:: powershell -File "%RECIPE_DIR%\x86_64-windows.ps1"

:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "HOST_TARGET=x86_64-windows-msvc"
set "TARGET=x86_64-windows-gnu"
set "MCPU=native"
set "ZIG=%SRC_DIR%\zig-bootstrap\zig.exe"

:: Configure CMake in build directory
mkdir build
cd build
cmake %SRC_DIR%/zig-source ^
  -G "Ninja" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%PREFIX%" ^
  -DCMAKE_PREFIX_PATH="%PREFIX%" ^
  -DZIG_TARGET_TRIPLE="%HOST_TARGET%" ^
  -DZIG_TARGET_MCPU=baseline ^
  -DZIG_VERSION="%PKG_VERSION%"
cd ..

%ZIG% build ^
  --prefix "%PREFIX%" ^
  -Dconfig_h="build/config.h" ^
  -Dflat ^
  -Doptimize=ReleaseFast ^
  -Dstrip ^
  -Dversion-string="%PKG_VERSION%"
::  -Denable-llvm ^
::  -Dtarget="%TARGET%" ^
::  -Dcpu="%MCPU%" ^
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
