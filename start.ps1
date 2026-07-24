$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'proxy-common.ps1')

$settings = Get-ProxySettings
$litellm = Join-Path $root '.venv\Scripts\litellm.exe'
$config = Join-Path $root 'config.yaml'

if (-not (Test-Path -LiteralPath $litellm)) {
    throw "LiteLLM was not found at $litellm. Run setup.cmd."
}

$env:LITELLM_MASTER_KEY = $settings.MasterKey
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$syncArguments = @{}
if (-not $settings.ConfigureClaude) {
    $syncArguments.SkipClaudeCache = $true
}
if (-not $settings.ConfigureCodex) {
    $syncArguments.SkipCodexCatalog = $true
}
& "$root\sync-models.ps1" @syncArguments

& $litellm `
    --config $config `
    --host 127.0.0.1 `
    --port $settings.Port
