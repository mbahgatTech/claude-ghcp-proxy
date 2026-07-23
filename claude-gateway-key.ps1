$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'proxy-common.ps1')

$settings = Get-ProxySettings
$startScript = Join-Path $root 'start.ps1'
$logDirectory = Join-Path $env:LOCALAPPDATA 'litellm-copilot-proxy\logs'

function Test-LiteLLM {
    try {
        $response = Invoke-RestMethod `
            -Uri "$($settings.BaseUrl)/v1/models" `
            -Headers @{ 'x-api-key' = $settings.MasterKey } `
            -TimeoutSec 1

        return @($response.data).Count -gt 0
    }
    catch [System.Net.WebException] {
        return $false
    }
}

if (-not (Test-LiteLLM)) {
    if (-not (Test-Path -LiteralPath $startScript)) {
        throw "LiteLLM startup script was not found at $startScript."
    }

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $startArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`""

    Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $startArguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDirectory 'proxy.out.log') `
        -RedirectStandardError (Join-Path $logDirectory 'proxy.err.log') | Out-Null

    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Milliseconds 250
        if (Test-LiteLLM) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        throw "LiteLLM did not become ready at $($settings.BaseUrl). See $logDirectory."
    }
}

Write-Output $settings.MasterKey
