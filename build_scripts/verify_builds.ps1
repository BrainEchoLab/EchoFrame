<#
.SYNOPSIS
    Verifies the three EchoFrame build paths from a clean copy of the tree.

.DESCRIPTION
    Copies echoframe/cpp to a short working directory (the Visual Studio generator
    overruns the 260-character path limit from a deep checkout) and runs:

      1. Wheel      -- pip install with VCPKG_ROOT cleared. Proves the Python
                       extension needs no vcpkg, matio, HDF5 or zlib.
      2. MEX+Python -- CMake with -DEF_BUILD_CLI=OFF and VCPKG_ROOT cleared.
                       Proves the MEX gateway has no third-party dependencies,
                       and that no libraries leak in from a machine-wide
                       `vcpkg integrate install`.
      3. CLI        -- CMake with -DEF_BUILD_CLI=ON and VCPKG_ROOT set.
                       Proves manifest mode provisions matio/HDF5/zlib, that
                       Release links the release matio (not the debug one), and
                       that there is no /MT-vs-/MD CRT mismatch.

    Nothing outside -WorkDir is modified. VCPKG_ROOT is changed only for this
    process, never for the machine.

.PARAMETER WorkDir
    Short scratch path for the copied tree. Keep it short.

.PARAMETER SkipMex
    Skip test 2, which needs a local MATLAB matching -MatlabVersion.

.PARAMETER SkipCli
    Skip test 3, which needs vcpkg. The first run builds matio and HDF5.

.PARAMETER Keep
    Leave the working directory in place for inspection.

.EXAMPLE
    pwsh -File build_scripts/verify_builds.ps1

.EXAMPLE
    pwsh -File build_scripts/verify_builds.ps1 -SkipMex -Keep
#>
[CmdletBinding()]
param(
    [string] $RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $WorkDir       = 'C:\ef_verify',
    [string] $Python        = '',
    [string] $VcpkgRoot     = $env:VCPKG_ROOT,
    [string] $MatlabVersion = '24.1',
    [string] $Generator     = 'Visual Studio 17 2022',
    [switch] $SkipMex,
    [switch] $SkipCli,
    [switch] $Keep
)

$ErrorActionPreference = 'Continue'
$results = [ordered]@{}
$origVcpkgRoot = $env:VCPKG_ROOT

function Write-Head($text) { Write-Host "`n===== $text =====" -ForegroundColor Cyan }

# Statuses are strings, never booleans. `$true -eq 'skipped'` is TRUE in
# PowerShell -- the right operand is coerced to the left operand's type, and a
# non-empty string converts to $true -- so storing booleans here makes every
# result match the 'skipped' branch and the script exits 0 on failure.
function Get-Status([bool]$ok) { if ($ok) { 'pass' } else { 'fail' } }
function Count-In($path, $pattern) {
    if (-not (Test-Path $path)) { return -1 }
    (Select-String -Path $path -Pattern $pattern -AllMatches -ErrorAction SilentlyContinue |
        Measure-Object).Count
}

# ---------------------------------------------------------------- sanity ----
if (-not (Test-Path (Join-Path $RepoRoot 'echoframe\cpp\src\CMakeLists.txt'))) {
    throw "RepoRoot '$RepoRoot' does not look like an EchoFrame checkout."
}
if (-not $Python) {
    $Python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $Python) { throw 'No python found. Pass -Python <path to python.exe>.' }
}
if ($WorkDir.Length -gt 40) {
    Write-Warning "WorkDir '$WorkDir' is long; the VS generator may hit the 260-char path limit."
}

Write-Host "repo      : $RepoRoot"
Write-Host "workdir   : $WorkDir"
Write-Host "python    : $Python"
Write-Host "vcpkg     : $(if ($VcpkgRoot) { $VcpkgRoot } else { '<not set -- CLI test will be skipped>' })"

# ------------------------------------------------------------ fresh copy ----
Write-Head 'Preparing clean tree'
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
$dst = Join-Path $WorkDir 'EchoFrame\echoframe\cpp'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# Exclude build outputs and the in-tree virtualenvs; they are large and stale.
$exclude = @('build', 'build_py', 'dist', '_deps', '__pycache__', '.git',
             'echoframe_py_env', 'py3.10_wheel_build', 'py3.11_wheel_build',
             'py3.12_wheel_build', 'py3.13_wheel_build', 'py3.14_wheel_build')
$rc = @((Join-Path $RepoRoot 'echoframe\cpp'), $dst, '/E', '/R:0', '/W:0',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XD') + $exclude
$null = robocopy @rc
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

$src = Join-Path $WorkDir 'EchoFrame\echoframe\cpp\src'
Write-Host ("copied {0} files" -f (Get-ChildItem (Join-Path $WorkDir 'EchoFrame') -Recurse -File).Count)

try {
    # ------------------------------------------------- 1. wheel, no vcpkg ----
    Write-Head '1. Wheel (pip install, VCPKG_ROOT cleared)'
    $env:VCPKG_ROOT = $null
    $venv = Join-Path $WorkDir 'venv'
    $log1 = Join-Path $WorkDir 't1.log'
    & $Python -m venv $venv
    $vpy = Join-Path $venv 'Scripts\python.exe'
    & $vpy -m pip install -q -U pip 2>&1 | Out-Null
    & $vpy -m pip install $src 2>&1 | Out-File $log1 -Encoding utf8
    $pipOk  = $LASTEXITCODE -eq 0
    & $vpy -c 'import echoframe' 2>&1 | Out-Null
    $impOk  = $LASTEXITCODE -eq 0
    $depRef = Count-In $log1 'vcpkg|matio|hdf5|ZLIB'
    Write-Host "  pip install      : $pipOk"
    Write-Host "  import echoframe : $impOk"
    Write-Host "  dependency refs  : $depRef (expect 0)"
    $results['1. wheel (no vcpkg)'] = Get-Status ($pipOk -and $impOk -and $depRef -eq 0)

    # -------------------------------------------- 2. MEX + Python, no vcpkg --
    if ($SkipMex) {
        Write-Head '2. MEX + Python -- SKIPPED'
        $results['2. MEX + Python (no vcpkg)'] = 'skipped'
    } else {
        Write-Head '2. MEX + Python (CMake, VCPKG_ROOT cleared)'
        $env:VCPKG_ROOT = $null
        $b2   = Join-Path $src 'b2'
        $log2 = Join-Path $WorkDir 't2.log'
        cmake -S $src -B $b2 -G $Generator -A x64 -DCMAKE_BUILD_TYPE=Release `
              -DMATLAB_VERSION="$MatlabVersion" `
              -DEF_BUILD_CLI=OFF -DEF_BUILD_MEX=ON -DEF_BUILD_PYTHON=ON 2>&1 |
              Out-File $log2 -Encoding utf8
        $cfgOk = $LASTEXITCODE -eq 0
        cmake --build $b2 --config Release 2>&1 | Out-File $log2 -Append -Encoding utf8
        $bldOk = $LASTEXITCODE -eq 0
        # Libraries injected by a machine-wide `vcpkg integrate install` would
        # show up here; VCPkgLocalAppDataDisabled in CMAKE_VS_GLOBALS blocks them.
        $leak  = Count-In $log2 'opencv|protobuf|abseil|imgui|matio|hdf5'
        $mex   = @(Get-ChildItem $b2 -Recurse -Filter *.mexw64 -ErrorAction SilentlyContinue).Count
        $pyd   = @(Get-ChildItem $b2 -Recurse -Filter *.pyd     -ErrorAction SilentlyContinue).Count
        Write-Host "  configure        : $cfgOk"
        Write-Host "  build            : $bldOk"
        Write-Host "  leaked libs      : $leak (expect 0)"
        Write-Host "  artifacts        : $mex mexw64, $pyd pyd"
        $results['2. MEX + Python (no vcpkg)'] =
            Get-Status ($cfgOk -and $bldOk -and $leak -eq 0 -and $mex -ge 1 -and $pyd -ge 1)
    }

    # ------------------------------------------------ 3. CLI, vcpkg needed ---
    if ($SkipCli -or -not $VcpkgRoot) {
        Write-Head '3. CLI -- SKIPPED'
        $results['3. CLI (vcpkg manifest)'] = 'skipped'
    } else {
        Write-Head '3. CLI (CMake, VCPKG_ROOT set, manifest mode)'
        $env:VCPKG_ROOT = $VcpkgRoot
        $b3   = Join-Path $src 'b3'
        $log3 = Join-Path $WorkDir 't3.log'
        Write-Host '  (first run builds matio and HDF5 -- this takes a few minutes)'
        cmake -S $src -B $b3 -G $Generator -A x64 -DCMAKE_BUILD_TYPE=Release `
              -DEF_BUILD_CLI=ON -DEF_BUILD_MEX=OFF -DEF_BUILD_PYTHON=OFF 2>&1 |
              Out-File $log3 -Encoding utf8
        $cfgOk = $LASTEXITCODE -eq 0
        cmake --build $b3 --config Release 2>&1 | Out-File $log3 -Append -Encoding utf8
        $bldOk = $LASTEXITCODE -eq 0
        $crt   = Count-In $log3 'LNK4098|LNK2038'   # /MT vs /MD mismatch
        $leak  = Count-In $log3 'cpplibs'           # machine-wide vcpkg injection
        $exe   = @(Get-ChildItem $b3 -Recurse -Filter echoframe_cli.exe -ErrorAction SilentlyContinue).Count

        # Release must link the RELEASE matio. Both configs carry the same
        # filename and differ only by directory, so this is easy to get wrong.
        $matioOk = $false
        $proj = Join-Path $b3 'echoframe_cli.vcxproj'
        if (Test-Path $proj) {
            $xml = [xml](Get-Content $proj)
            foreach ($g in $xml.Project.ItemDefinitionGroup) {
                $deps = $g.Link.AdditionalDependencies
                if ($deps -and $g.Condition -match "=='Release\|") {
                    $m = ($deps -split ';') | Where-Object { $_ -match 'libmatio' }
                    $matioOk = ($m -and $m -notmatch '\\debug\\')
                    Write-Host "  matio [Release]  : $m"
                }
            }
        }
        Write-Host "  configure        : $cfgOk"
        Write-Host "  build            : $bldOk"
        Write-Host "  CRT warnings     : $crt (expect 0)"
        Write-Host "  leaked libs      : $leak (expect 0)"
        Write-Host "  release matio    : $matioOk"
        Write-Host "  artifacts        : $exe exe"
        $results['3. CLI (vcpkg manifest)'] =
            Get-Status ($cfgOk -and $bldOk -and $crt -eq 0 -and $leak -eq 0 -and $matioOk -and $exe -ge 1)
    }
}
finally {
    $env:VCPKG_ROOT = $origVcpkgRoot

    # Keep the tree whenever something failed -- the logs are the only record of
    # why, and deleting them on failure is precisely backwards.
    $anyFailed = @($results.Values | Where-Object { [string]$_ -eq 'fail' }).Count -gt 0
    if ($Keep -or $anyFailed) {
        if ($anyFailed) { Write-Host "`na test failed -- keeping logs for diagnosis" -ForegroundColor Yellow }
        Write-Host "kept: $WorkDir"
        Get-ChildItem $WorkDir -Filter 't*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "  log: $($_.FullName)" }
    } else {
        Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------- summary ----
Write-Head 'Summary'
$failed = 0
foreach ($k in $results.Keys) {
    # String-to-string comparison; see the note on Get-Status above.
    switch ([string]$results[$k]) {
        'skipped' { Write-Host ("  SKIP  {0}" -f $k) -ForegroundColor Yellow }
        'pass'    { Write-Host ("  PASS  {0}" -f $k) -ForegroundColor Green }
        default   { Write-Host ("  FAIL  {0}" -f $k) -ForegroundColor Red; $failed++ }
    }
}
Write-Host ''
exit $failed
