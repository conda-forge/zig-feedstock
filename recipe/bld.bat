:: @echo off
:: Try using bootstrapped ZIG to build ZIG for Conda environment
set "MSVC_TARGET=x86_64-windows-msvc"
set "GNU_TARGET=x86_64-windows-gnu"
set "MCPU=native"

:: set "CC=%BUILD_PREFIX%\Library\ucrt64\bin\gcc"
:: set "CXX=%BUILD_PREFIX%\Library\ucrt64\bin\g++"

:: Configure CMake in build directory
set "SOURCE_DIR=%SRC_DIR%\zig-source"
set "CONFIG_DIR=%SRC_DIR%\_config"

call :configZigCmakeBuildGCC "%CONFIG_DIR%" "%SRC_DIR%\_conda-cmake-built"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

:: call :bootstrapZigWithZIG "%SRC_DIR%\_conda-bootstrap" "%SRC_DIR%\zig-bootstrap\zig.exe" "%SRC_DIR%\_conda-bootstrapped"
:: if %ERRORLEVEL% neq 0 (
::   echo "Failed to bootstrap ZIG"
::   exit /b %ERRORLEVEL%
:: )

call :buildZigWithZIG "%SRC_DIR%\_conda-zig-build" "%SRC_DIR%\_conda-cmake-built\bin\zig.exe" "%SRC_DIR%\_conda-final"
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

:configZigCmakeBuildGCC
setlocal
set "_build_dir=%~1"
set "_zig_install_dir=%~2"

mkdir %_build_dir%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %_build_dir%
  set "_prefix=%PREFIX:\=\\%"
  set "_zig_install_dir=%_zig_install_dir:\=\\%"

  %CC% --version
  %CXX% --version
  echo %CFLAGS%
  echo %CXXFLAGS%

  set "CLANG_MAXIMUM_CONCURRENT_JOBS=1"
  cmake %SOURCE_DIR% ^
    -G "Ninja" ^
    -D CMAKE_BUILD_TYPE=Debug ^
    -D CMAKE_INSTALL_PREFIX="%_zig_install_dir%" ^
    -D ZIG_USE_LLVM_CONFIG=ON ^
    -D ZIG_SHARED_LLVM=ON ^
    -D ZIG_TARGET_TRIPLE=%GNU_TARGET% ^
    -D ZIG_VERSION="%PKG_VERSION%" --debug-trycompile
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  cmake --build . --config Release
  cmake --install . --config Release

  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
endlocal
GOTO :EOF

:buildZigWithZIG
setlocal
echo "buildZigWithZIG"
set "BUILD_DIR=%~1"
set "ZIG=%~2"
set "INSTALL_DIR=%~3"

mkdir %BUILD_DIR%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %BUILD_DIR%
  xcopy /E %SOURCE_DIR%\* . > nul
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  echo "%VSINSTALLDIR%"
  dir %VSINSTALLDIR%
  dir %VSINSTALLDIR%VC\Tools\MSVC"
  dir C:\Program Files\Microsoft Visual Studio\2022\Enterprise

  mkdir %INSTALL_DIR%
  %ZIG% build ^
    --prefix "%INSTALL_DIR%" ^
    --search-prefix "%PREFIX%" ^
    --search-prefix "%PREFIX%\Library" ^
    --search-prefix "%PREFIX%\Library\lib" ^
    --search-prefix "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.29.30133\lib" ^
    --skip-oom-steps ^
    -Dconfig_h="%CONFIG_DIR%\config.h" ^
    -Doptimize=ReleaseFast ^
    -Dstatic-llvm ^
    -Dstrip ^
    -Dflat ^
    -Duse-zig-libcxx ^
    -Dversion-string="%PKG_VERSION%"
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %SRC_DIR%
echo "Done"
endlocal
GOTO :EOF
