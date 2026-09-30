# Regression tests for upload-release-assets.ps1.
#
# Drives the script against a local HttpListener stub of the release API, so the
# whole path is exercised: tag lookup, upload URI construction, the existing
# asset guard, and the overwrite delete-then-upload branch. No network, token, or
# second PowerShell process needed.
#
# Run with: pwsh -NoProfile -File .github/workflows/scripts/test-upload-release-assets.ps1

# Strict mode makes the script under test fail loudly on an unexpected response
# shape instead of silently posting to a null URL.
Set-StrictMode -Version Latest

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$uploadScript = Join-Path $scriptDir "upload-release-assets.ps1"
if (-not (Test-Path -LiteralPath $uploadScript)) {
    throw "cannot find $uploadScript"
}

$passed = 0
$failed = 0
$script:lastOutput = ""

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:passed++
        Write-Host "  PASS  $Message"
    } else {
        $script:failed++
        Write-Host "  FAIL  $Message"
    }
}

# Runs the script in-process, returning the exception message or $null on success.
function Invoke-Upload {
    param([string] $AssetDir, [string] $Overwrite, [switch] $CaptureOutput)
    $env:GITHUB_TOKEN = "test-token"
    $env:GITHUB_REPOSITORY = "o/r"
    $env:TAG_NAME = "v9.9.9"
    $env:OVERWRITE = $Overwrite
    try {
        if ($CaptureOutput) {
            $out = & $uploadScript -AssetDir $AssetDir -ApiBaseUrl $base 6>&1
            $script:lastOutput = ($out | ForEach-Object { "$_" }) -join "`n"
        } else {
            & $uploadScript -AssetDir $AssetDir -ApiBaseUrl $base *>&1 | Out-Null
        }
        return $null
    } catch {
        return $_.Exception.Message
    } finally {
        foreach ($k in "GITHUB_TOKEN", "GITHUB_REPOSITORY", "TAG_NAME", "OVERWRITE") {
            Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue
        }
    }
}

# --- stub release API -------------------------------------------------------

$releaseId = 4242
$listener = [System.Net.HttpListener]::new()
$bound = $false
foreach ($port in 18080..18099) {
    try {
        $listener.Prefixes.Add("http://127.0.0.1:$port/")
        $listener.Start()
        $base = "http://127.0.0.1:$port"
        $bound = $true
        break
    } catch {
        $listener.Prefixes.Clear()
    }
}
if (-not $bound) { throw "could not bind a stub listener on 127.0.0.1:18080-18099" }

$requests = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$existingNames = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

$server = Start-ThreadJob -ScriptBlock {
    param($Listener, $Base, $Requests, $Existing, $ReleaseId)

    while ($Listener.IsListening) {
        try { $context = $Listener.GetContext() } catch { break }

        $path = $context.Request.Url.AbsolutePath
        $method = $context.Request.HttpMethod
        $Requests.Enqueue("$method $path")

        $payload = $null
        $status = 200

        if ($path -eq "/repos/o/r/releases/tags/v9.9.9" -and $method -eq "GET") {
            $assetList = @()
            foreach ($name in $Existing.ToArray()) {
                $assetList += @{
                    name = $name
                    url  = "$Base/repos/o/r/releases/assets/$ReleaseId"
                }
            }
            $payload = @{
                id         = $ReleaseId
                upload_url = "$Base/repos/o/r/releases/$ReleaseId/assets{?name,label}"
                assets     = $assetList
            }
        } elseif ($path -eq "/repos/o/r/releases/$ReleaseId/assets" -and $method -eq "POST") {
            $status = 201
            $payload = @{ name = $context.Request.QueryString["name"] }
        } elseif ($path -eq "/repos/o/r/releases/assets/$ReleaseId" -and $method -eq "DELETE") {
            $status = 204
        } else {
            $status = 404
            $payload = @{ message = "Not Found" }
        }

        $body = if ($payload) { ConvertTo-Json -Depth 5 -Compress -InputObject $payload } else { "" }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $context.Response.StatusCode = $status
        $context.Response.ContentType = "application/json"
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
    }
} -ArgumentList $listener, $base, $requests, $existingNames, $releaseId

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ef-upload-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$assets = Join-Path $work "assets"
New-Item -ItemType Directory -Path $assets | Out-Null
$assetName = "build_linux_CUDA_12.8_MATLAB_2024a.zip"
Set-Content -Path (Join-Path $assets $assetName) -Value "zip"

try {
    Write-Host "case: upload to a release with no existing assets"
    $err = Invoke-Upload $assets "false" -CaptureOutput
    Assert-True ($null -eq $err) "uploads without error ($err)"
    Assert-True ($script:lastOutput -match [regex]::Escape("Uploaded $assetName")) "reports the upload"
    $seen = $requests.ToArray()
    Assert-True ($seen -contains "GET /repos/o/r/releases/tags/v9.9.9") "looks the release up by tag"
    Assert-True ($seen -contains "POST /repos/o/r/releases/$releaseId/assets") "posts to upload_url, not a host-less URI"

    Write-Host "case: existing asset and overwrite=false"
    $existingNames.Enqueue($assetName)
    $err = Invoke-Upload $assets "false"
    Assert-True ($err -match "already exists") "refuses to clobber without overwrite ($err)"

    Write-Host "case: existing asset and overwrite=true"
    $err = Invoke-Upload $assets "true"
    Assert-True ($null -eq $err) "uploads when overwriting ($err)"
    $seen = $requests.ToArray()
    Assert-True ($seen -contains "DELETE /repos/o/r/releases/assets/$ReleaseId") "deletes the stale asset first"
    $existingNames.Clear()

    Write-Host "case: empty asset directory"
    $empty = Join-Path $work "empty"
    New-Item -ItemType Directory -Path $empty | Out-Null
    $err = Invoke-Upload $empty "false"
    Assert-True ($err -match "No release assets found") "rejects an empty asset directory ($err)"
} finally {
    $listener.Stop()
    $listener.Close()
    Remove-Job $server -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "passed: $passed  failed: $failed"
if ($failed -gt 0) { exit 1 }
