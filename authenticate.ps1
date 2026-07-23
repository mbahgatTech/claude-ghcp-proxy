$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'proxy-common.ps1')

$clientId = 'Iv1.b507a08c87ecfe98'
$headers = @{
    Accept = 'application/json'
    'Content-Type' = 'application/json'
    'Editor-Version' = 'vscode/1.95.0'
    'Editor-Plugin-Version' = 'copilot-chat/0.26.7'
    'User-Agent' = 'GitHubCopilotChat/0.26.7'
}

$device = Invoke-RestMethod `
    -Method Post `
    -Uri 'https://github.com/login/device/code' `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body (@{
        client_id = $clientId
        scope = 'read:user'
    } | ConvertTo-Json -Compress)

if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    Set-Clipboard -Value $device.user_code
}

$browser = Start-Process -FilePath $device.verification_uri -PassThru -ErrorAction SilentlyContinue
if (-not $browser) {
    Write-Warning "Could not open a browser automatically. Open $($device.verification_uri)."
}

Write-Output "Enter code $($device.user_code) at $($device.verification_uri). The code was copied to the clipboard."

$interval = [Math]::Max(5, [int]$device.interval)
$deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$device.expires_in)

while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds $interval

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri 'https://github.com/login/oauth/access_token' `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body (@{
            client_id = $clientId
            device_code = $device.device_code
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
        } | ConvertTo-Json -Compress)

    if ($response.access_token) {
        $tokenDirectory = Join-Path $HOME '.config\litellm\github_copilot'
        $tokenPath = Join-Path $tokenDirectory 'access-token'
        $apiKeyPath = Join-Path $tokenDirectory 'api-key.json'

        Write-Utf8NoBomAtomic -Path $tokenPath -Content ([string]$response.access_token)
        if (Test-Path -LiteralPath $apiKeyPath) {
            Remove-Item -LiteralPath $apiKeyPath -Force
        }

        Write-Output "GitHub Copilot authentication saved to $tokenPath."
        exit 0
    }

    switch ($response.error) {
        'authorization_pending' { continue }
        'slow_down' {
            $interval += 5
            continue
        }
        'access_denied' { throw 'GitHub authorization was denied.' }
        'expired_token' { throw 'The GitHub device code expired.' }
        default { throw "GitHub authentication failed: $($response.error_description)" }
    }
}

throw 'The GitHub device authorization expired before completion.'
