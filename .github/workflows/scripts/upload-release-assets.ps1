param(
    [Parameter(Mandatory = $true)]
    [string] $AssetDir,

    # Overridable so the test suite can drive the script against a local stub.
    [string] $ApiBaseUrl = "https://api.github.com"
)

$ErrorActionPreference = "Stop"

$assets = Get-ChildItem $AssetDir -Filter *.zip
if (-not $assets) { throw "No release assets found in $AssetDir." }

$headers = @{
    Authorization = "Bearer $env:GITHUB_TOKEN"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$release = Invoke-RestMethod `
    -Headers $headers `
    -Uri "$ApiBaseUrl/repos/$env:GITHUB_REPOSITORY/releases/tags/$env:TAG_NAME"
$uploadUrl = $release.upload_url.Split("{")[0]

foreach ($asset in $assets) {
    $existing = $release.assets | Where-Object { $_.name -eq $asset.Name }
    if ($existing) {
        if ($env:OVERWRITE -ne "true") {
            throw "Release asset already exists: $($asset.Name). Re-run with overwrite=true."
        }
        Invoke-RestMethod -Method Delete -Headers $headers -Uri $existing.url | Out-Null
    }

    $name = [uri]::EscapeDataString($asset.Name)

    # "?" is a legal PowerShell variable-name character, so "$uploadUrl?name"
    # parses as one (undefined) variable and yields a host-less URI. The braces
    # force the expansion to stop at the variable.
    $uploadUri = "${uploadUrl}?name=$name"
    if (-not [uri]::IsWellFormedUriString($uploadUri, [System.UriKind]::Absolute)) {
        throw "Malformed upload URI '$uploadUri' for $($asset.Name)."
    }

    Invoke-RestMethod `
        -Method Post `
        -Headers $headers `
        -ContentType "application/zip" `
        -InFile $asset.FullName `
        -Uri $uploadUri | Out-Null
    Write-Host "Uploaded $($asset.Name)"
}
