@echo off
REM Test script for zig wrapper validation (Windows)
REM Runs during zig_$cross_target_platform_ package tests
setlocal enabledelayedexpansion

set "_wrapper_dir=%CONDA_PREFIX%\Library\share\zig\wrappers"
set _pass=0
set _fail=0

echo === Wrapper Script Validation ===

REM --- 1. Wrapper existence ---
echo --- Wrapper existence ---
for %%w in (zig-cc.bat zig-cxx.bat zig-ar.bat zig-ranlib.bat zig-asm.bat zig-rc.bat) do (
    if exist "%_wrapper_dir%\%%w" (
        echo   PASS: %%w exists
        set /a _pass+=1
    ) else (
        echo   FAIL: %%w exists
        set /a _fail+=1
    )
)

REM --- 2. Activation variables ---
echo --- Activation variables ---

if defined ZIG_RC (
    echo   PASS: ZIG_RC is set
    set /a _pass+=1
) else (
    echo   FAIL: ZIG_RC is set
    set /a _fail+=1
)

if defined ZIG_RC_CMAKE (
    echo   PASS: ZIG_RC_CMAKE is set
    set /a _pass+=1
) else (
    echo   FAIL: ZIG_RC_CMAKE is set
    set /a _fail+=1
)

REM --- 3. ZIG_RC_CMAKE has no backslashes ---
echo --- RC path escaping ---
echo %ZIG_RC_CMAKE% | findstr /C:"\" >nul 2>&1
if errorlevel 1 (
    echo   PASS: ZIG_RC_CMAKE has no backslashes
    set /a _pass+=1
) else (
    echo   FAIL: ZIG_RC_CMAKE has no backslashes
    set /a _fail+=1
)

REM Verify ZIG_RC_CMAKE contains forward slashes
echo %ZIG_RC_CMAKE% | findstr /C:"/" >nul 2>&1
if not errorlevel 1 (
    echo   PASS: ZIG_RC_CMAKE has forward slashes
    set /a _pass+=1
) else (
    echo   FAIL: ZIG_RC_CMAKE has forward slashes
    set /a _fail+=1
)

REM Verify ZIG_RC_CMAKE ends with zig-rc.bat
echo %ZIG_RC_CMAKE% | findstr /E /C:"zig-rc.bat" >nul 2>&1
if not errorlevel 1 (
    echo   PASS: ZIG_RC_CMAKE ends with zig-rc.bat
    set /a _pass+=1
) else (
    echo   FAIL: ZIG_RC_CMAKE ends with zig-rc.bat
    set /a _fail+=1
)

echo.
echo === Results: %_pass% passed, %_fail% failed ===
if not "%_fail%"=="0" exit /b 1
