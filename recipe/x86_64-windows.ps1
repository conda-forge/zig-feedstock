$TARGET = "x86_64-windows-gnu"
$ZIG_LLVM_CLANG_LLD_NAME = "zig+llvm+lld+clang-$TARGET-0.12.0-dev.2073+402fe565a"
$MCPU = "baseline"
$CONDA_PREFIX = "$PREFIX"
$PREFIX_PATH = "$($Env:USERPROFILE)\$ZIG_LLVM_CLANG_LLD_NAME"
$ZIG = "$($Env:SRC_DIR)\zig-bootstrap\zig.exe"
$ZIG_LIB_DIR = "$(Get-Location)\lib"

function CheckLastExitCode {
    if (!$?) {
        exit 1
    }
    return 0
}

Write-Output "Building from source..."
Remove-Item -Path 'build-release' -Recurse -Force -ErrorAction Ignore
New-Item -Path 'build-release' -ItemType Directory
Set-Location -Path 'build-release'

# CMake gives a syntax error when file paths with backward slashes are used.
# Here, we use forward slashes only to work around this.
& cmake .. `
  -GNinja `
  -DCMAKE_INSTALL_PREFIX="$($CONDA_PREFIX -Replace "\\", "/")" `
  -DCMAKE_PREFIX_PATH="$($PREFIX_PATH -Replace "\\", "/")" `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_C_COMPILER="$($ZIG -Replace "\\", "/");cc;-target;$TARGET;-mcpu=$MCPU" `
  -DCMAKE_CXX_COMPILER="$($ZIG -Replace "\\", "/");c++;-target;$TARGET;-mcpu=$MCPU" `
  -DCMAKE_AR="$($ZIG -Replace "\\", "/")" `
  -DZIG_AR_WORKAROUND=ON `
  -DZIG_TARGET_TRIPLE="$TARGET" `
  -DZIG_TARGET_MCPU="$MCPU"
CheckLastExitCode

ninja install
CheckLastExitCode
