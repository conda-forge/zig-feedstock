@echo off
REM Wrapper: zig cc -target @ZIG_TARGET@
"@ZIG_BIN@" cc -target @ZIG_TARGET@ -mcpu=baseline %*
