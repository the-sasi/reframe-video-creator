# Builds the Foundation-only targets with the Windows Swift toolchain.
#
# The rest of the engine links AVFoundation, Vision and Metal and can only compile on macOS
# (CI does that). But RecipeCore — schema, timeline, commands, binder, mix planner — is pure
# Swift, and a ten-second local loop on the densest logic is worth having. Also runs the
# CoreCheck executable, a lightweight assertion harness for the same code, when -Check is given.
#
# Usage (from any shell):  powershell -File Packages/ReframeKit/build-core.ps1 [-Check]
param([switch]$Check)

$vs = "C:\Program Files\Microsoft Visual Studio\2022\Community"
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll" -ErrorAction SilentlyContinue
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=x64" 2>$null | Out-Null
$env:SDKROOT = "$env:LOCALAPPDATA\Programs\Swift\Platforms\6.3.3\Windows.platform\Developer\SDKs\Windows.sdk"
Set-Location $PSScriptRoot

if ($Check) {
    swift run CoreCheck 2>&1
} else {
    swift build --target RecipeCore 2>&1
}
exit $LASTEXITCODE
