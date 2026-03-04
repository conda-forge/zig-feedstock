@echo off
REM Wrapper: zig cc (assembler mode) -target @ZIG_TARGET@
"@ZIG_BIN@" cc -target @ZIG_TARGET@ -mcpu=baseline %*
