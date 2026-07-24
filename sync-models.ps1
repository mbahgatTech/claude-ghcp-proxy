$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'proxy-common.ps1')

$settings = Get-ProxySettings
$configPath = Join-Path $root 'config.yaml'
$tokenDirectory = Join-Path $HOME '.config\litellm\github_copilot'
$accessTokenPath = Join-Path $tokenDirectory 'access-token'
$apiKeyPath = Join-Path $tokenDirectory 'api-key.json'
$claudeGatewayBaseUrl = $settings.BaseUrl
$claudeModelCachePath = Join-Path $HOME '.claude\cache\gateway-models.json'

$githubHeaders = @{
    Accept = 'application/json'
    'Content-Type' = 'application/json'
    'Editor-Version' = 'vscode/1.95.0'
    'Editor-Plugin-Version' = 'copilot-chat/0.26.7'
    'User-Agent' = 'GitHubCopilotChat/0.26.7'
}

function Get-CopilotApiKey {
    if (Test-Path -LiteralPath $apiKeyPath) {
        $cached = Get-Content -LiteralPath $apiKeyPath -Raw | ConvertFrom-Json
        $minimumExpiry = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60
        if ($cached.token -and $cached.endpoints.api -and [long]$cached.expires_at -gt $minimumExpiry) {
            return $cached
        }
    }

    if (-not (Test-Path -LiteralPath $accessTokenPath)) {
        throw "GitHub Copilot authentication is missing. Run $root\authenticate.ps1."
    }

    $accessToken = (Get-Content -LiteralPath $accessTokenPath -Raw).Trim()
    if (-not $accessToken) {
        throw "GitHub Copilot access token is empty. Run $root\authenticate.ps1."
    }

    $headers = $githubHeaders.Clone()
    $headers.Authorization = "token $accessToken"
    $apiKey = Invoke-RestMethod `
        -Method Get `
        -Uri 'https://api.github.com/copilot_internal/v2/token' `
        -Headers $headers

    if (-not $apiKey.token -or -not $apiKey.endpoints.api) {
        throw 'GitHub Copilot returned an invalid API key response.'
    }

    Write-Utf8NoBomAtomic `
        -Path $apiKeyPath `
        -Content ($apiKey | ConvertTo-Json -Depth 20 -Compress)

    return $apiKey
}

function Get-ModelMode {
    param($Model)

    $endpoints = @($Model.supported_endpoints)
    if (
        $endpoints -contains '/responses' -and
        $endpoints -notcontains '/chat/completions' -and
        $endpoints -notcontains '/v1/messages'
    ) {
        return 'responses'
    }

    return 'chat'
}

function Get-VersionSortKey {
    param([string]$ModelId)

    if ($ModelId -match '(\d+(?:[.-]\d+)*)$') {
        return (($Matches[1] -split '[.-]' | ForEach-Object { '{0:D6}' -f [int]$_ }) -join '.')
    }

    return $ModelId
}

function ConvertTo-YamlScalar {
    param([string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Add-ModelRoute {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [System.Collections.Generic.HashSet[string]]$PublicNames,
        [string]$PublicName,
        [string]$CopilotModel,
        [string]$Mode
    )

    if (-not $PublicNames.Add($PublicName)) {
        return
    }

    $Lines.Add("  - model_name: $(ConvertTo-YamlScalar $PublicName)")
    $Lines.Add('    litellm_params:')
    $Lines.Add("      model: $(ConvertTo-YamlScalar "github_copilot/$CopilotModel")")
    $Lines.Add('    model_info:')
    $Lines.Add("      mode: $(ConvertTo-YamlScalar $Mode)")
}

function Add-ModelAlias {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Aliases,
        [System.Collections.Generic.HashSet[string]]$PublicNames,
        [string]$PublicName,
        [string]$TargetModel,
        [bool]$Hidden = $false
    )

    if (-not $PublicNames.Add($PublicName)) {
        return
    }

    $Aliases.Add($PublicName, [ordered]@{
        model = $TargetModel
        hidden = $Hidden
    })
}

$apiKey = Get-CopilotApiKey
$copilotHeaders = $githubHeaders.Clone()
$copilotHeaders.Authorization = "Bearer $($apiKey.token)"
$copilotHeaders['Copilot-Integration-Id'] = 'vscode-chat'
$copilotHeaders['X-GitHub-Api-Version'] = '2025-04-01'

$apiBase = $apiKey.endpoints.api.TrimEnd('/')
$response = Invoke-RestMethod -Method Get -Uri "$apiBase/models" -Headers $copilotHeaders
$models = @($response.data | Where-Object {
    $policyProperty = $_.PSObject.Properties['policy']
    $policyState = $null
    if ($policyProperty -and $policyProperty.Value) {
        $stateProperty = $policyProperty.Value.PSObject.Properties['state']
        if ($stateProperty) {
            $policyState = [string]$stateProperty.Value
        }
    }

    $_.model_picker_enabled -eq $true -and
    $_.capabilities.type -eq 'chat' -and
    (-not $policyState -or $policyState -eq 'enabled')
})

if ($models.Count -eq 0) {
    throw 'GitHub Copilot returned no picker-enabled chat models.'
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('model_list:')
$publicNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$aliases = [ordered]@{}
$pickerModels = [System.Collections.Generic.List[object]]::new()
$pickerModelIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

# Register upstream IDs first so generated aliases can never shadow a real model.
foreach ($model in $models) {
    Add-ModelRoute `
        -Lines $lines `
        -PublicNames $publicNames `
        -PublicName $model.id `
        -CopilotModel $model.id `
        -Mode (Get-ModelMode $model)
}

$families = [ordered]@{
    sonnet = 'claude-sonnet-'
    opus = 'claude-opus-'
    haiku = 'claude-haiku-'
}

foreach ($family in $families.GetEnumerator()) {
    $candidate = $models |
        Where-Object { $_.id -like "$($family.Value)*" } |
        Sort-Object @{ Expression = { Get-VersionSortKey $_.id }; Descending = $true } |
        Select-Object -First 1

    if ($candidate) {
        Add-ModelAlias `
            -Aliases $aliases `
            -PublicNames $publicNames `
            -PublicName $family.Key `
            -TargetModel $candidate.id
    }
}

foreach ($model in $models) {
    $pickerModelId = $model.id
    if ($model.id -like 'claude-*') {
        $compatibilityModelId = $model.id.Replace('.', '-')
        if ($compatibilityModelId -cne $model.id) {
            Add-ModelAlias `
                -Aliases $aliases `
                -PublicNames $publicNames `
                -PublicName $compatibilityModelId `
                -TargetModel $model.id `
                -Hidden $true
        }
    }
    else {
        $pickerModelId = "claude-$($model.id)"
        Add-ModelAlias `
            -Aliases $aliases `
            -PublicNames $publicNames `
            -PublicName $pickerModelId `
            -TargetModel $model.id
    }

    $nameProperty = $model.PSObject.Properties['name']
    $displayName = if ($nameProperty -and $nameProperty.Value) {
        [string]$nameProperty.Value
    }
    else {
        [string]$model.id
    }

    if ($pickerModelIds.Add($pickerModelId)) {
        $pickerModels.Add([ordered]@{
            id = $pickerModelId
            display_name = $displayName
        })
    }
}

if ($aliases.Count -gt 0) {
    $lines.Add('')
    $lines.Add('router_settings:')
    $lines.Add('  model_group_alias:')
    foreach ($alias in $aliases.GetEnumerator()) {
        $lines.Add("    $(ConvertTo-YamlScalar $alias.Key):")
        $lines.Add("      model: $(ConvertTo-YamlScalar $alias.Value.model)")
        $lines.Add("      hidden: $(([string]$alias.Value.hidden).ToLowerInvariant())")
    }
}

$lines.Add('')
$lines.Add('general_settings:')
$lines.Add('  master_key: os.environ/LITELLM_MASTER_KEY')

Write-Utf8LinesAtomic -Path $configPath -Lines $lines

$claudeModelCache = [ordered]@{
    baseUrl = $claudeGatewayBaseUrl
    fetchedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    models = @($pickerModels)
}
Write-Utf8NoBomAtomic `
    -Path $claudeModelCachePath `
    -Content ($claudeModelCache | ConvertTo-Json -Depth 10 -Compress)

Write-Output "Configured $($models.Count) GitHub Copilot chat models and refreshed Claude's picker cache."
