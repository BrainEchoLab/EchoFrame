# Bootstrap vcpkg for EchoFrame CLI builds.
# Clones vcpkg to a short path, bootstraps it, and sets VCPKG_ROOT.
# Only the CLI needs this; MEX/Python-only builds (-DEF_BUILD_CLI=OFF) do not use vcpkg.
#
# Usage:
#   .\setup_vcpkg.ps1                 # installs to C:\vcpkg
#   .\setup_vcpkg.ps1 -VcpkgRoot D:\vcpkg

param(
    [string]$VcpkgRoot = "C:\vcpkg"
)

$ErrorActionPreference = "Stop"

if (Test-Path (Join-Path $VcpkgRoot ".vcpkg-root")) {
    Write-Host "vcpkg already present at $VcpkgRoot"
} else {
    Write-Host "Cloning vcpkg into $VcpkgRoot ..."
    git clone https://github.com/microsoft/vcpkg $VcpkgRoot
}

if (-not (Test-Path (Join-Path $VcpkgRoot "vcpkg.exe"))) {
    Write-Host "Bootstrapping vcpkg ..."
    & (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
}

# Persist for future sessions, and set it for this one.
setx VCPKG_ROOT $VcpkgRoot | Out-Null
$env:VCPKG_ROOT = $VcpkgRoot

Write-Host "VCPKG_ROOT set to $VcpkgRoot"
Write-Host "Configure the build with: cmake --preset default   (run from echoframe/cpp/src)"
