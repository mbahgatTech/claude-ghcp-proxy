[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 4000,

    [ValidateNotNullOrEmpty()]
    [string]$LiteLLMVersion = '1.93.0',

    [string]$MasterKey,

    [switch]$ForceAuthentication,

    [switch]$SkipClaudeInstall,

    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    throw 'This installer currently supports native Windows only.'
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'proxy-common.ps1')

$localSettingsPath = Join-Path $root 'local.settings.json'
$venvPath = Join-Path $root '.venv'
$venvPython = Join-Path $venvPath 'Scripts\python.exe'
$helperPath = Join-Path $root 'claude-gateway-key.ps1'
$claudeSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$accessTokenPath = Join-Path $env:USERPROFILE '.config\litellm\github_copilot\access-token'

function Set-JsonProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath;$env:Path"
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "WinGet is required to install $PackageId. Install App Installer from Microsoft Store and rerun setup.cmd."
    }

    & winget.exe install `
        --id $PackageId `
        --exact `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install $PackageId with exit code $LASTEXITCODE."
    }

    Refresh-ProcessPath
}

function Resolve-Uv {
    $command = Get-Command uv.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $knownPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\uv.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\uv.exe')
    )

    foreach ($path in $knownPaths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

function Stop-InstalledProxy {
    $connection = Get-NetTCPConnection `
        -LocalAddress 127.0.0.1 `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $connection) {
        return
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)"
    $normalizedRoot = [System.IO.Path]::GetFullPath($root)
    if (-not $process.CommandLine -or $process.CommandLine.IndexOf($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Port $Port is already used by an unrelated process: $($process.CommandLine)"
    }

    Stop-Process -Id $connection.OwningProcess -Force

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 250
        $remaining = Get-NetTCPConnection `
            -LocalAddress 127.0.0.1 `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue

        if (-not $remaining) {
            return
        }
    }

    throw "LiteLLM did not release port $Port."
}

function Merge-ClaudeSettings {
    $settingsDirectory = Split-Path -Parent $claudeSettingsPath
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $claudeSettingsPath) {
        $settings = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $claudeSettingsPath -Destination "$claudeSettingsPath.$timestamp.bak"
    }
    else {
        $settings = [pscustomobject]@{}
    }

    if (-not $settings.PSObject.Properties['$schema']) {
        Set-JsonProperty `
            -Object $settings `
            -Name '$schema' `
            -Value 'https://json.schemastore.org/claude-code-settings.json'
    }

    if (-not $settings.PSObject.Properties['env'] -or -not $settings.env) {
        Set-JsonProperty -Object $settings -Name 'env' -Value ([pscustomobject]@{})
    }

    $helperCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$helperPath`""
    Set-JsonProperty -Object $settings -Name 'apiKeyHelper' -Value $helperCommand
    Set-JsonProperty -Object $settings.env -Name 'ANTHROPIC_BASE_URL' -Value "http://127.0.0.1:$Port"
    Set-JsonProperty -Object $settings.env -Name 'CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY' -Value '1'

    Write-Utf8NoBomAtomic `
        -Path $claudeSettingsPath `
        -Content ($settings | ConvertTo-Json -Depth 20)
}

$existingSettings = $null
if (Test-Path -LiteralPath $localSettingsPath) {
    $existingSettings = Get-Content -LiteralPath $localSettingsPath -Raw | ConvertFrom-Json
}

if (
    $existingSettings -and
    -not $PSBoundParameters.ContainsKey('Port') -and
    $existingSettings.PSObject.Properties['port']
) {
    $Port = [int]$existingSettings.port
}

if ([string]::IsNullOrWhiteSpace($MasterKey)) {
    if ($existingSettings -and $existingSettings.PSObject.Properties['masterKey']) {
        $MasterKey = [string]$existingSettings.masterKey
    }
    else {
        $MasterKey = "sk-litellm-$([guid]::NewGuid().ToString('N'))"
    }
}

$localSettings = [ordered]@{
    port = $Port
    masterKey = $MasterKey
}
Write-Utf8NoBomAtomic `
    -Path $localSettingsPath `
    -Content ($localSettings | ConvertTo-Json)

Stop-InstalledProxy

$uv = Resolve-Uv
if (-not $uv) {
    Install-WingetPackage -PackageId 'astral-sh.uv'
    $uv = Resolve-Uv
}
if (-not $uv) {
    throw 'uv was installed but could not be located. Open a new terminal and rerun setup.cmd.'
}

& $uv python install 3.12
if ($LASTEXITCODE -ne 0) {
    throw "uv failed to install Python 3.12 with exit code $LASTEXITCODE."
}

& $uv venv --allow-existing --python 3.12 $venvPath
if ($LASTEXITCODE -ne 0) {
    throw "uv failed to create the virtual environment with exit code $LASTEXITCODE."
}

& $uv pip install `
    --python $venvPython `
    --upgrade `
    "litellm[proxy]==$LiteLLMVersion"
if ($LASTEXITCODE -ne 0) {
    throw "uv failed to install LiteLLM $LiteLLMVersion with exit code $LASTEXITCODE."
}

if (-not $SkipClaudeInstall -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Install-WingetPackage -PackageId 'Anthropic.ClaudeCode'
}

if ($ForceAuthentication -or -not (Test-Path -LiteralPath $accessTokenPath)) {
    & (Join-Path $root 'authenticate.ps1')
}

Merge-ClaudeSettings
& (Join-Path $root 'sync-models.ps1')

if (-not $NoStart) {
    $null = & $helperPath
    $models = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$Port/v1/models" `
        -Headers @{ 'x-api-key' = $MasterKey } `
        -TimeoutSec 10

    if (@($models.data).Count -eq 0) {
        throw 'LiteLLM started without any configured models.'
    }
}

Write-Output ''
Write-Output 'Setup complete.'
Write-Output "LiteLLM: http://127.0.0.1:$Port"
Write-Output 'Run Claude Code with: claude'
Write-Output 'Open the model picker with: /model'
