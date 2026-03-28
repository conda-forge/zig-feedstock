@echo off
REM Test script for cross-compiler .exe shim validation (non-unix)
REM Runs during zig_$cross_target_platform_ package tests (cross-compiler only)
setlocal enabledelayedexpansion

set _pass=0
set _fail=0

echo === Cross-compiler .exe Shim Validation ===

REM CONDA_TRIPLET is the target triplet (e.g. aarch64-w64-mingw32)
set "_shim=%CONDA_PREFIX%\Library\bin\%CONDA_TRIPLET%-zig.exe"

REM --- 1. Shim exists as .exe ---
echo --- Shim existence ---
if exist "%_shim%" (
    echo   PASS: %CONDA_TRIPLET%-zig.exe exists
    set /a _pass+=1
) else (
    echo   FAIL: %CONDA_TRIPLET%-zig.exe not found at %_shim%
    set /a _fail+=1
    goto :summary
)

REM --- 2. Shim is a PE executable (not a .bat) ---
REM Check for MZ header (PE signature)
echo --- PE format validation ---
findstr /B /C:"MZ" "%_shim%" >nul 2>&1
if not errorlevel 1 (
    echo   PASS: shim has MZ PE header
    set /a _pass+=1
) else (
    echo   FAIL: shim does not have MZ PE header - may be a .bat rename
    set /a _fail+=1
)

REM --- 3. No .bat/.cmd siblings (replaced by .exe) ---
echo --- Legacy wrapper cleanup ---
if not exist "%CONDA_PREFIX%\Library\bin\%CONDA_TRIPLET%-zig.bat" (
    echo   PASS: no legacy .bat wrapper
    set /a _pass+=1
) else (
    echo   FAIL: legacy .bat wrapper still exists
    set /a _fail+=1
)
if not exist "%CONDA_PREFIX%\Library\bin\%CONDA_TRIPLET%-zig.cmd" (
    echo   PASS: no legacy .cmd wrapper
    set /a _pass+=1
) else (
    echo   FAIL: legacy .cmd wrapper still exists
    set /a _fail+=1
)

:summary
echo.
echo === Results: %_pass% passed, %_fail% failed ===
if not "%_fail%"=="0" exit /b 1
