param(
    [Parameter(Mandatory = $true)]
    [string] $AssetDir
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
    -Uri "https://api.github.com/repos/$env:GITHUB_REPOSITORY/releases/tags/$env:TAG_NAME"
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
    Invoke-RestMethod `
        -Method Post `
        -Headers $headers `
        -ContentType "application/zip" `
        -InFile $asset.FullName `
        -Uri "$uploadUrl?name=$name" | Out-Null
    Write-Host "Uploaded $($asset.Name)"
}
