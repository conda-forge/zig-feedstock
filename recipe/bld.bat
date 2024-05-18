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
set "ZIG_INSTALL_DIR=%SRC_DIR%\_installed"
set "ZIG_TEST_DIR=%SRC_DIR%\_self-build"

:: We need this so zig can find the libraies (apparently, --search-prefix does not work)
echo "Configuring ZIG in %CONFIG_DIR% from %SOURCE_DIR%"
mkdir %CONFIG_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %CONFIG_DIR%
  set "PATH=%PREFIX%\bin;%PATH%"

  set "_prefix=%PREFIX:\=\\%"
  set "_zig_install_dir=%ZIG_INSTALL_DIR:\=\\%"
  set "_zig=%ZIG:\=\\%"
  cmake %SOURCE_DIR% ^
    -G "Ninja" ^
    -D CMAKE_BUILD_TYPE=Release ^
    -D CMAKE_INSTALL_PREFIX="%_zig_install_dir%" ^
    -D CMAKE_PREFIX_PATH="%_prefix%\\Library" ^
    -D CMAKE_C_COMPILER="%_zig%;cc" ^
    -D CMAKE_CXX_COMPILER="%_zig%;c++" ^
    -D CMAKE_AR="%_zig%" ^
    -D ZIG_AR_WORKAROUND=ON ^
    -D ZIG_USE_LLVM_CONFIG=OFF ^
    -D ZIG_SHARED_LLVM=ON ^
    -D ZIG_VERSION="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

    :: -G "Visual Studio 17 2022" ^
    :: Shared libs are seemingly not supported on Windows MSVC (maybe switch to mingw?)
    :: -D ZIG_SHARED_LLVM=ON ^
    :: -D ZIG_USE_LLVM_CONFIG=ON ^
cd %SRC_DIR%

echo "Building ZIG from source in %CONFIG_DIR%
cd %CONFIG_DIR%
  echo "   Building ..."
  :: cmake --build . --config Release --target install -- -j %NUMBER_OF_PROCESSORS%
  cmake --build . --config Release --target install
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
  echo "   Built."

  echo "   Testing ..."
  %ZIG_INSTALL_DIR%\bin\zig.exe build test
cd %SRC_DIR%

echo "Building ZIG with: %ZIG% in %ZIG_BUILD_DIR%"
mkdir %ZIG_BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %ZIG_BUILD_DIR%
  echo "   Copying sources ..."
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  echo "   Building ..."
  mkdir %ZIG_INSTALL_DIR%
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
  %ZIG% build ^
    --prefix "%ZIG_INSTALL_DIR%" ^
    --search-prefix "%PREFIX%" ^
    --zig-lib-dir "%PREFIX%\Library\lib" ^
    -Doptimize=ReleaseSafe ^
    -Dstatic-llvm ^
    -Duse-zig-libcxx ^
    -Dtarget="%TARGET%" ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
    :: -Dconfig_h="%CONFIG_DIR%\config.h" ^
    :: --search-prefix "%BUILD_PREFIX%\Library\lib" ^
    :: --search-prefix "%PREFIX%\Library\lib" ^
    :: -Dcpu="%MCPU%" ^
  echo "   Built."
  dir %ZIG_INSTALL_DIR%
cd %SRC_DIR%

echo "Testing self-build ZIG with: %ZIG_INSTALL_DIR%\zig.exe in %ZIG_TEST_DIR%"
mkdir %ZIG_TEST_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %ZIG_TEST_DIR%
  echo "   Copying sources ..."
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  set "ZIG=%ZIG_INSTALL_DIR%\bin\zig.exe"

  echo "   Building ..."
  mkdir %SRC_DIR%\_self-test
  %ZIG% build ^
    --prefix "%SRC_DIR%/_self-test" ^
    -Doptimize=ReleaseFast ^
    -Dstrip ^
    -Dtarget="%HOST_TARGET%" ^
    -Dcpu="%MCPU%" ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%

echo "ZIG built and tested successfully."
echo "Copying ZIG to %PREFIX%"
copy %ZIG_INSTALL_DIR%\zig.exe %PREFIX%\bin\zig.exe > nul
xcopy /E %ZIG_INSTALL_DIR%\lib %PREFIX%\lib > nul
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
