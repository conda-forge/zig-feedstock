@echo off
:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "MSVC_TARGET=x86_64-windows-msvc"
set "GNU_TARGET=x86_64-windows-gnu"
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
call :buildZigcppCmake
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
call :bootstrapZigWithZIG
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo Copying ZIG to %PREFIX%
mkdir %PREFIX%\bin
mkdir %PREFIX%\lib
mkdir %PREFIX%\doc
copy %ZIG_INSTALL_DIR%\zig.exe %PREFIX%\bin\zig.exe
xcopy /E %ZIG_INSTALL_DIR%\lib %PREFIX%\lib\
xcopy /E %ZIG_INSTALL_DIR%\doc %PREFIX%\doc\ > nul

:: Exit main script
GOTO :EOF

:: --- Functions ---

:configZigCmakeBuild
mkdir %CONFIG_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %CONFIG_DIR%
  set "PATH=%PREFIX%\bin;%PATH%"

  set "_prefix=%PREFIX:\=\\%"
  set "_build_prefix=%BUILD_PREFIX:\=\\%"
  set "_zig_install_dir=%ZIG_INSTALL_DIR:\=\\%"
  set "_zig=%ZIG:\=\\%"

  set "CLANG_MAXIMUM_CONCURRENT_JOBS=1"
  cmake %SOURCE_DIR% ^
    -G "Ninja" ^
    -D CMAKE_BUILD_TYPE=Release ^
    -D CMAKE_INSTALL_PREFIX="%_zig_install_dir%" ^
    -D CMAKE_PREFIX_PATH="%_prefix%\\Library\\lib" ^
    -D ZIG_AR_WORKAROUND=ON ^
    -D ZIG_USE_LLVM_CONFIG=OFF ^
    -D ZIG_STATIC_LLVM=ON ^
    -D ZIG_TARGET_TRIPLE=%GNU_TARGET% ^
    -D ZIG_VERSION="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
    :: -D CMAKE_C_COMPILER="%_zig%;cc" ^
    :: -D CMAKE_CXX_COMPILER="%_zig%;c++" ^
    :: -D CMAKE_AR="%_zig%" ^
    :: -D ZIG_SYSTEM_LIBCXX="c++" ^
cd %SRC_DIR%
GOTO :EOF

:buildZigcppCmake
cd %CONFIG_DIR%
  cmake --build . --config Release --target zigcpp
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
GOTO :EOF

:bootstrapZigWithZIG
mkdir %ZIG_BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

cd %ZIG_BUILD_DIR%
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  mkdir %ZIG_INSTALL_DIR%
  %ZIG% build ^
    --prefix "%ZIG_INSTALL_DIR%" ^
    --search-prefix "%PREFIX%\Library\lib" ^
    --release=small ^
    --skip-oom-steps ^
    -Dconfig_h="%CONFIG_DIR%\config.h" ^
    -Dskip-non-native ^
    -Denable-symlinks-windows ^
    -Dflat ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
GOTO :EOF

:: :buildZigWithZIG
:: echo Testing self-build ZIG with: %ZIG_INSTALL_DIR%\zig.exe in %ZIG_TEST_DIR%
:: mkdir %ZIG_TEST_DIR%
:: if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
:: cd %ZIG_TEST_DIR%
::   echo "   Copying sources ..."
::   xcopy /E %SOURCE_DIR%\* . > nul
::   if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
::
::   set "ZIG=%ZIG_INSTALL_DIR%\zig.exe"
::
::   echo "   Building ..."
::   mkdir %SRC_DIR%\_self-test
::   %ZIG% build ^
::     --prefix "%SRC_DIR%/_self-test" ^
::     --search-prefix "%PREFIX%\Library\lib" ^
::     --skip-oom-steps ^
::     --release=safe ^
::     -Dstrip ^
::     -Dflat ^
::     -Dversion-string="%PKG_VERSION%"
::   if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
:: cd %SRC_DIR%
:: GOTO :EOF
