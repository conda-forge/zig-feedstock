@echo off
:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "MSVC_TARGET=x86_64-windows-msvc"
set "GNU_TARGET=x86_64-windows-gnu"
set "MCPU=native"

:: Configure CMake in build directory
set "SOURCE_DIR=%SRC_DIR%\zig-source"
set "CONFIG_DIR=%SRC_DIR%\_config"

call :configZigCmakeBuildMSVC "%SRC_DIR%\_conda-cmake-built"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

call :bootstrapZigWithZIG "%SRC_DIR%\_conda-bootstrap" "%SRC_DIR%\zig-bootstrap\zig.exe" "%SRC_DIR%\_conda-bootstrapped"
if %ERRORLEVEL% neq 0 (
  echo "Failed to bootstrap ZIG"
  exit /b %ERRORLEVEL%
)

call :buildZigWithZIG "%SRC_DIR%\_conda-zig-build" "%SRC_DIR%\_conda-bootstrapped\zig.exe" "%SRC_DIR%\_conda-final"
if %ERRORLEVEL% neq 0 (
    echo "Failed to build ZIG"
    exit /b %ERRORLEVEL%
    )

echo Copying ZIG to %PREFIX%
mkdir %PREFIX%\bin
mkdir %PREFIX%\lib
mkdir %PREFIX%\doc
copy %SRC_DIR%\_conda-final\zig.exe %PREFIX%\bin\zig.exe
xcopy /E %SRC_DIR%\_conda-final\lib %PREFIX%\lib\ > nul
xcopy /E %SRC_DIR%\_conda-final\doc %PREFIX%\doc\ > nul

dir %PREFIX%\lib

:: Exit main script
GOTO :EOF

:: --- Functions ---

:configZigCmakeBuildMSVC
set "INSTALL_DIR=%~1"
mkdir %CONFIG_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %CONFIG_DIR%
  set "_prefix=%PREFIX:\=\\%"
  set "_zig_install_dir=%INSTALL_DIR:\=\\%"

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

  cmake --build . --config Release --target zigcpp
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
GOTO :EOF

:configZigCmakeBuildZIG
setlocal
set "INSTALL_DIR=%~1"
set "ZIG=%~2"

mkdir %CONFIG_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %CONFIG_DIR%
  set "_prefix=%PREFIX:\=\\%"
  set "_zig_install_dir=%INSTALL_DIR:\=\\%"
  set "_zig=%ZIG:\=\\%"

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
    -D ZIG_STATIC_LLVM=ON ^
    -D ZIG_TARGET_TRIPLE=%GNU_TARGET% ^
    -D ZIG_VERSION="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  cmake --build . --config Release --target zigcpp
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
endlocal
GOTO :EOF

:bootstrapZigWithZIG
setlocal
echo "bootstrapZigWithZIG"
set "BUILD_DIR=%~1"
set "ZIG=%~2"
set "INSTALL_DIR=%~3"

mkdir %BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

cd %BUILD_DIR%
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  mkdir %INSTALL_DIR%
  %ZIG% build ^
    --prefix "%INSTALL_DIR%" ^
    --search-prefix "%PREFIX%\Library\lib" ^
    --release=small ^
    --skip-oom-steps ^
    -Dconfig_h="%CONFIG_DIR%\config.h" ^
    -Dskip-non-native ^
    -Denable-symlinks-windows ^
    -Dflat ^
    -Dno-langref ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo "Done"
cd %SRC_DIR%
endlocal
GOTO :EOF

:buildZigWithZIG
setlocal
echo "buildZigWithZIG"
set "BUILD_DIR=%~1"
set "ZIG=%~2"
set "INSTALL_DIR=%~3"

echo "BUILD_DIR: %BUILD_DIR%"
echo "ZIG: %ZIG%"
echo "INSTALL_DIR: %INSTALL_DIR%"

mkdir %BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %BUILD_DIR%
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  mkdir %INSTALL_DIR%
  %ZIG% build ^
    --prefix "%INSTALL_DIR%" ^
    --search-prefix "%PREFIX%\Library\lib" ^
    --skip-oom-steps ^
    --release=safe ^
    -Denable-llvm ^
    -Dstrip ^
    -Dflat ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
echo "Done"
endlocal
GOTO :EOF
