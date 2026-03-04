@echo off
REM Wrapper: zig c++ -target @ZIG_TARGET@
"@ZIG_BIN@" c++ -target @ZIG_TARGET@ -mcpu=baseline %*
