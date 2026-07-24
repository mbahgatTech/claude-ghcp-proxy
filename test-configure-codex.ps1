$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'configure-codex.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "configure-codex-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-Merge {
    param([string]$ConfigPath)
    & $scriptPath `
        -Path $ConfigPath `
        -BaseUrl 'http://127.0.0.1:4000/v1' `
        -DefaultModel 'gpt-test' `
        -ModelCatalogPath (Join-Path $tempRoot 'models.json') `
        -HelperPath (Join-Path $tempRoot 'gateway-key.ps1') | Out-Null
}

try {
    $configPath = Join-Path $tempRoot 'preserve\config.toml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) | Out-Null
    $original = @'
# user heading
model = "old" # replaced comment may be owned
approval_policy = "on-request" # preserve exactly

[features]
web_search = true

[model_providers.other]
name = "Other"
base_url = "https://example.test/v1"

[model_providers.ghcp]
name = "Old GHCP"
base_url = "http://old/v1"
wire_api = "responses"
custom_future_key = "keep me"

[model_providers.ghcp.auth]
command = "old.exe"
args = ["old"]
timeout_ms = 1234
'@ -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($configPath, $original, [System.Text.UTF8Encoding]::new($false))

    Invoke-Merge $configPath
    $merged = [System.IO.File]::ReadAllText($configPath)
    Assert-True ($merged.Contains("approval_policy = `"on-request`" # preserve exactly`r`n")) 'unrelated root setting and comment are preserved'
    Assert-True ($merged.Contains("[features]`r`nweb_search = true`r`n")) 'unrelated table is preserved'
    Assert-True ($merged.Contains("[model_providers.other]`r`nname = `"Other`"")) 'other provider is preserved'
    Assert-True ($merged.Contains('custom_future_key = "keep me"')) 'unknown GHCP provider key is preserved'
    Assert-True ($merged.Contains('timeout_ms = 45000')) 'owned auth timeout is updated'
    Assert-True ($merged.Contains('refresh_interval_ms = 300000')) 'auth refresh interval is configured'
    Assert-True ($merged.Contains('model = "gpt-test"')) 'default model is updated'
    Assert-True ($merged.Contains('model_provider = "ghcp"')) 'default provider is added'
    Assert-True ($merged.Contains('model_catalog_json = "')) 'catalog is configured'
    Assert-True ($merged.Contains('base_url = "http://127.0.0.1:4000/v1"')) 'GHCP base URL is updated'
    Assert-True ($merged.Contains('command = "powershell.exe"')) 'auth command is configured'
    Assert-True ((Get-ChildItem -LiteralPath (Split-Path -Parent $configPath) -Filter 'config.toml.*.bak').Count -eq 1) 'changed existing file gets one backup'

    $beforeSecondRun = [System.IO.File]::ReadAllBytes($configPath)
    Invoke-Merge $configPath
    $afterSecondRun = [System.IO.File]::ReadAllBytes($configPath)
    Assert-True ([Convert]::ToBase64String($beforeSecondRun) -ceq [Convert]::ToBase64String($afterSecondRun)) 'second run is byte-idempotent'
    Assert-True ((Get-ChildItem -LiteralPath (Split-Path -Parent $configPath) -Filter 'config.toml.*.bak').Count -eq 1) 'idempotent run does not create backup'

    $newPath = Join-Path $tempRoot 'new\config.toml'
    Invoke-Merge $newPath
    Assert-True (Test-Path -LiteralPath $newPath) 'missing config is created'
    Assert-True ((Get-ChildItem -LiteralPath (Split-Path -Parent $newPath) -Filter '*.bak').Count -eq 0) 'new config has no backup'

    $unsafeFixtures = @(
        @{ Name = 'malformed'; Text = "model = `"unterminated`n" },
        @{ Name = 'duplicate'; Text = "model = `"one`"`nmodel = `"two`"`n" },
        @{ Name = 'inline-provider'; Text = "model_providers.ghcp = { name = `"unsafe`" }`n" },
        @{ Name = 'array-provider'; Text = "[[model_providers.ghcp]]`nname = `"unsafe`"`n" }
    )
    foreach ($fixture in $unsafeFixtures) {
        $unsafePath = Join-Path $tempRoot "$($fixture.Name)\config.toml"
        New-Item -ItemType Directory -Path (Split-Path -Parent $unsafePath) | Out-Null
        [System.IO.File]::WriteAllText($unsafePath, $fixture.Text, [System.Text.UTF8Encoding]::new($false))
        $before = [System.IO.File]::ReadAllBytes($unsafePath)
        $threw = $false
        try { Invoke-Merge $unsafePath } catch { $threw = $true }
        Assert-True $threw "$($fixture.Name) fixture is rejected"
        $after = [System.IO.File]::ReadAllBytes($unsafePath)
        Assert-True ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String($after)) "$($fixture.Name) fixture is not overwritten"
        Assert-True ((Get-ChildItem -LiteralPath (Split-Path -Parent $unsafePath) -Filter '*.bak').Count -eq 0) "$($fixture.Name) fixture creates no backup"
    }

    Write-Output 'All configure-codex fixture tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
