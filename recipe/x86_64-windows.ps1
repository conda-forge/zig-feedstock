$TARGET = "x86_64-windows-gnu"
$MCPU = "baseline"
HOST_TARGET="x86_64-windows-msvc"
$CONDA_PREFIX = "$PREFIX"


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
  -DCMAKE_PREFIX_PATH="$($CONDA_PREFIX -Replace "\\", "/")" `
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

Write-Output "Main test suite..."
& "stage3-release\bin\zig.exe" build test docs `
  --zig-lib-dir "$ZIG_LIB_DIR" `
  --search-prefix "$PREFIX_PATH" `
  -Dstatic-llvm `
  -Dskip-non-native `
  -Denable-symlinks-windows
CheckLastExitCode

Write-Output "Build x86_64-windows-msvc behavior tests using the C backend..."
& "stage3-release\bin\zig.exe" test `
  ..\test\behavior.zig `
  --zig-lib-dir "$ZIG_LIB_DIR" `
  -ofmt=c `
  -femit-bin="test-x86_64-windows-msvc.c" `
  --test-no-exec `
  -target x86_64-windows-msvc `
  -lc
CheckLastExitCode

& "stage3-release\bin\zig.exe" build-obj `
  --zig-lib-dir "$ZIG_LIB_DIR" `
  -ofmt=c `
  -OReleaseSmall `
  --name compiler_rt `
  -femit-bin="compiler_rt-x86_64-windows-msvc.c" `
  --dep build_options `
  -target x86_64-windows-msvc `
  --mod root ..\lib\compiler_rt.zig `
  --mod build_options config.zig
CheckLastExitCode

Import-Module "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
CheckLastExitCode

Enter-VsDevShell -VsInstallPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
  -DevCmdArguments '-arch=x64 -no_logo' `
  -StartInPath $(Get-Location)
CheckLastExitCode

Write-Output "Build and run behavior tests with msvc..."
& cl.exe -I..\lib test-x86_64-windows-msvc.c compiler_rt-x86_64-windows-msvc.c /W3 /Z7 -link -nologo -debug -subsystem:console kernel32.lib ntdll.lib libcmt.lib
CheckLastExitCode

& .\test-x86_64-windows-msvc.exe
CheckLastExitCode