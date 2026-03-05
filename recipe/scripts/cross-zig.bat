@echo off
REM Cross-compiler wrapper: injects -target for commands that support it
REM cc/c++ use stripped triplet (clang rejects glibc version suffix)
REM zig-native commands use full triplet (zig accepts glibc version)
setlocal
REM Support both Library/bin (new) and bin (old zig_impl) layouts
set "NATIVE_ZIG=%~dp0@NATIVE_ZIG_EXT@"
if not exist "%NATIVE_ZIG%" set "NATIVE_ZIG=%~dp0..\..\bin\@NATIVE_ZIG_EXT@"
set "CMD=%1"
if "%CMD%"=="cc" goto inject_cc_target
if "%CMD%"=="c++" goto inject_cc_target
if "%CMD%"=="build-exe" goto inject_zig_target
if "%CMD%"=="build-lib" goto inject_zig_target
if "%CMD%"=="build-obj" goto inject_zig_target
if "%CMD%"=="test" goto inject_zig_target
if "%CMD%"=="run" goto inject_zig_target
if "%CMD%"=="translate-c" goto inject_zig_target
goto passthrough

:inject_cc_target
shift
"%NATIVE_ZIG%" %CMD% -target @CC_TRIPLET@ %*
goto :eof

:inject_zig_target
shift
"%NATIVE_ZIG%" %CMD% -target @ZIG_TRIPLET@ %*
goto :eof

:passthrough
"%NATIVE_ZIG%" %*
