function Get-ProxySettings {
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'local.settings.json')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Local settings were not found at $Path. Run setup.cmd first."
    }

    $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $portProperty = $settings.PSObject.Properties['port']
    $masterKeyProperty = $settings.PSObject.Properties['masterKey']

    if (-not $portProperty) {
        throw "Local settings at $Path do not define port."
    }

    $port = 0
    if (-not [int]::TryParse([string]$portProperty.Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Local settings at $Path contain an invalid port."
    }

    if (-not $masterKeyProperty -or [string]::IsNullOrWhiteSpace([string]$masterKeyProperty.Value)) {
        throw "Local settings at $Path do not define masterKey."
    }

    return [pscustomobject]@{
        Port = $port
        MasterKey = [string]$masterKeyProperty.Value
        BaseUrl = "http://127.0.0.1:$port"
        Path = $Path
    }
}

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText(
        $temporaryPath,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-Utf8LinesAtomic {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.Generic.IEnumerable[string]]$Lines
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllLines(
        $temporaryPath,
        $Lines,
        [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}
