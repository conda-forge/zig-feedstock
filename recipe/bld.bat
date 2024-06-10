@echo off
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

call :configZigCmakeBuild
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
call :buildZigCmake
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
call :buildZigWithZIG
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo "Copying ZIG to %PREFIX%"
copy %ZIG_INSTALL_DIR%\zig.exe %PREFIX%\bin\zig.exe > nul
xcopy /E %ZIG_INSTALL_DIR%\lib %PREFIX%\lib > nul
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

:: Exit main script
GOTO :EOF

:: --- Functions ---

:configZigCmakeBuild
echo "Configuring ZIG in %CONFIG_DIR% from %SOURCE_DIR%"
mkdir %CONFIG_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %CONFIG_DIR%
  set "PATH=%PREFIX%\bin;%PATH%"

  set "_prefix=%PREFIX:\=\\%"
  set "_build_prefix=%BUILD_PREFIX:\=\\%"
  set "_zig_install_dir=%ZIG_INSTALL_DIR:\=\\%"
  set "_zig=%ZIG:\=\\%"

  for /F "tokens=2 delims=:" %%a in ('systeminfo ^| findstr /C:"Available Physical Memory"') do set "freemem=%%a"
  for /F "tokens=1 delims=MB" %%a in ("%freemem%") do set /A "freemem_int=%%a"
  set freemem_int=%freemem_int:~1%
  echo Available Physical Memory: %freemem%

  set "CLANG_MAXIMUM_CONCURRENT_JOBS=1"
  cmake %SOURCE_DIR% ^
    -G "Ninja" ^
    -D CMAKE_BUILD_TYPE=Release ^
    -D CMAKE_INSTALL_PREFIX="%_zig_install_dir%" ^
    -D CMAKE_PREFIX_PATH="%_prefix%\\Library\\lib" ^
    -D CMAKE_C_COMPILER="%_zig%;cc" ^
    -D CMAKE_CXX_COMPILER="%_zig%;c++" ^
    -D CMAKE_AR="%_zig%" ^
    -D ZIG_AR_WORKAROUND=ON ^
    -D ZIG_USE_LLVM_CONFIG=OFF ^
    -D ZIG_SHARED_LLVM=ON ^
    -D ZIG_VERSION="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
    :: -D ZIG_SYSTEM_LIBCXX="c++" ^
cd %SRC_DIR%
GOTO :EOF

:buildZigCmake
echo "Building ZIG from source in %CONFIG_DIR%
cd %CONFIG_DIR%
  echo "   Building ..."
  set "CLANG_MAXIMUM_CONCURRENT_JOBS=1"
  cmake --build . --config Release --target zigcpp -- -j 1
  :: cmake --build . --config Release --target install
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  :: echo "   Testing ..."
  :: %ZIG_INSTALL_DIR%\bin\zig.exe build test
cd %SRC_DIR%
GOTO :EOF

:buildZigWithZIG
echo "Building ZIG with: %ZIG% in %ZIG_BUILD_DIR%"
mkdir %ZIG_BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

cd %ZIG_BUILD_DIR%
  echo "   Copying sources ..."
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  echo "   Building ..."
  mkdir %ZIG_INSTALL_DIR%

  %ZIG% build ^
    --prefix "%ZIG_INSTALL_DIR%" ^
    --search-prefix "%PREFIX%\Library\lib" ^
    --maxrss 24696061952 \
    -Doptimize=ReleaseSafe ^
    -Dconfig_h="%CONFIG_DIR%\config.h" ^
    -Denable-llvm ^
    -Dskip-non-native `
    -Denable-symlinks-windows ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
    :: -Dtarget="%TARGET%" ^
  echo "   Built."
  dir %ZIG_INSTALL_DIR%
cd %SRC_DIR%
GOTO :EOF

:: echo "Testing self-build ZIG with: %ZIG_INSTALL_DIR%\zig.exe in %ZIG_TEST_DIR%"
:: mkdir %ZIG_TEST_DIR%
:: if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
:: cd %ZIG_TEST_DIR%
::   echo "   Copying sources ..."
::   xcopy /E %SOURCE_DIR%\* . > nul
::   if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
::
::   set "ZIG=%ZIG_INSTALL_DIR%\bin\zig.exe"
::
::   echo "   Building ..."
::   mkdir %SRC_DIR%\_self-test
::   %ZIG% build ^
::     --prefix "%SRC_DIR%/_self-test" ^
::     -Doptimize=ReleaseFast ^
::     -Dstrip ^
::     -Dtarget="%HOST_TARGET%" ^
::     -Dcpu="%MCPU%" ^
::     -Dversion-string="%PKG_VERSION%"
::   if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
:: cd %SRC_DIR%
::
:: echo "ZIG built and tested successfully."
:: echo "Copying ZIG to %PREFIX%"
:: copy %ZIG_INSTALL_DIR%\zig.exe %PREFIX%\bin\zig.exe > nul
:: xcopy /E %ZIG_INSTALL_DIR%\lib %PREFIX%\lib > nul
:: if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
