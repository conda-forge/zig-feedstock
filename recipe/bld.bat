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

call :configZigCmakeBuildMSVC "%CONFIG_DIR%" "%SRC_DIR%\_conda-cmake-built"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

:: call :buildZigWithZIG "%SRC_DIR%\_conda-zig-build" "%SRC_DIR%\_conda-cmake-built\bin\zig.exe" "%SRC_DIR%\_conda-final"
:: if %ERRORLEVEL% neq 0 (
::     echo "Failed to build ZIG"
::     exit /b %ERRORLEVEL%
::     )

echo Copying ZIG to %PREFIX%
mkdir %PREFIX%\bin
mkdir %PREFIX%\lib
mkdir %PREFIX%\doc
copy %SRC_DIR%\_conda-cmake-built\zig.exe %PREFIX%\bin\zig.exe
xcopy /E %SRC_DIR%\_conda-cmake-built\lib %PREFIX%\lib\ > nul
xcopy /E %SRC_DIR%\_conda-cmake-built\doc %PREFIX%\doc\ > nul

dir %PREFIX%\lib

:: Exit main script
GOTO :EOF

:: --- Functions ---

:configZigCmakeBuildMSVC
setlocal emabledelayedexpansion
set "_build_dir=%~1"
set "_zig_install_dir=%~2"

mkdir %_build_dir%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
cd %_build_dir%
  set "_prefix=%PREFIX:\=\\%"
  set "_zig_install_dir=%_zig_install_dir:\=\\%"

  set "CLANG_MAXIMUM_CONCURRENT_JOBS=1"
  set "CMAKE_BUILD_PARALLEL_LEVEL=1"
  cmake %CMAKE_ARGS% ^
    -G "Ninja" ^
    -D CMAKE_BUILD_TYPE=Release ^
    -D CMAKE_INSTALL_PREFIX="%_zig_install_dir%" ^
    -D CMAKE_VERBOSE_MAKEFILE=ON ^
    -D LLVM_ENABLE_XML2=ON ^
    -D ZIG_USE_LLVM_CONFIG=OFF ^
    -D ZIG_STATIC=ON ^
    -D ZIG_TARGET_TRIPLE=%GNU_TARGET% ^
    -D ZIG_TARGET_MCPU="baseline" ^
    -D ZIG_SYSTEM_LIBCXX="c++" ^
    -D ZIG_VERSION="%PKG_VERSION%" ^
    %SOURCE_DIR%
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

  :: :: Configuration puts -lzstd.dll instead of -lzstd
  :: set "old_string=zstd.dll"
  :: set "new_string=zstd"
  :: for /f "tokens=*" %%A in (config.h) do (
  ::     set "line=%%A"
  ::     set "line=!line:%old_string%=%new_string%!"
  ::     echo !line! >> _config.h
  :: )
  :: move /y _config.h config.h
  type config.h

  cmake --build . --config Release
  if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

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
    --zig_lib_dir "%PREFIX%\Library\lib" ^
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
