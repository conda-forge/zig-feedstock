@echo off
:: powershell -File "%RECIPE_DIR%\x86_64-windows.ps1"

:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "HOST_TARGET=x86_64-windows-msvc"
set "TARGET=x86_64-windows-gnu"
set "MCPU=native"
set "ZIG=%SRC_DIR%\zig-bootstrap\zig.exe"

:: Configure CMake in build directory
set "SOURCE_DIR=%SRC_DIR%\zig-source"
set "CONFIG_DIR=%SRC_DIR%\_config"
set "ZIG_BUILD_DIR=%SRC_DIR%\_build"
set "ZIG_TEST_DIR=%SRC_DIR%\_self-build"

echo "Configuring ZIG in %CONFIG_DIR% from %SOURCE_DIR%"
mkdir %CONFIG_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %CONFIG_DIR%
  cmake %SOURCE_DIR% ^
    -G "Ninja" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_INSTALL_PREFIX="%PREFIX%" ^
    -DCMAKE_PREFIX_PATH="%PREFIX%" ^
    -DZIG_TARGET_TRIPLE="%HOST_TARGET%" ^
    -DZIG_TARGET_MCPU=baseline ^
    -DZIG_VERSION="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%

echo "Building ZIG with: %ZIG% in %ZIG_BUILD_DIR%"
mkdir %ZIG_BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %ZIG_BUILD_DIR%
  echo "   Copying sources ..."
  dir %SOURCE_DIR%
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  echo "   Building ..."
  dir %CONFIG_DIR%
  dir %CONFIG_DIR%/config.h
  %ZIG% build ^
    --prefix "%PREFIX%" ^
    -Dconfig_h="%CONFIG_DIR%/config.h" ^
    -Dflat ^
    -Doptimize=ReleaseFast ^
    -Dstrip ^
    -Dversion-string="%PKG_VERSION%"
  ::  -Denable-llvm ^
  ::  -Dtarget="%TARGET%" ^
  ::  -Dcpu="%MCPU%" ^
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%

echo "Building ZIG with: %PREFIX%\bin\zig.exe in %ZIG_TEST_DIR%"
mkdir %ZIG_TEST_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %ZIG_TEST_DIR%
  echo "   Copying sources ..."
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  set "ZIG=%PREFIX%\bin\zig.exe"

  echo "   Building ..."
  %ZIG% build ^
    --prefix "%SRC_DIR%/_self-test" ^
    -Dconfig_h="%CONFIG_DIR%/config.h" ^
    -Dflat ^
    -Doptimize=ReleaseFast ^
    -Dstrip ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
