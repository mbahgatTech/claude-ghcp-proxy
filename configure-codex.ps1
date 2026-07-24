[CmdletBinding()]
param(
    [string]$Path = (Join-Path $HOME '.codex\config.toml'),

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DefaultModel,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ModelCatalogPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$HelperPath
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-TomlBasicString {
    param([Parameter(Mandatory)][string]$Value)

    $builder = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -ne '\') {
            $null = $builder.Append($character)
            continue
        }

        $index++
        if ($index -ge $Value.Length) {
            throw 'A quoted TOML key ends with an incomplete escape sequence.'
        }

        $escaped = $Value[$index]
        switch ($escaped) {
            'b' { $null = $builder.Append("`b") }
            't' { $null = $builder.Append("`t") }
            'n' { $null = $builder.Append("`n") }
            'f' { $null = $builder.Append("`f") }
            'r' { $null = $builder.Append("`r") }
            '"' { $null = $builder.Append('"') }
            '\' { $null = $builder.Append('\') }
            'u' {
                if ($index + 4 -ge $Value.Length) { throw 'A quoted TOML key has an incomplete Unicode escape.' }
                $hex = $Value.Substring($index + 1, 4)
                if ($hex -notmatch '^[0-9A-Fa-f]{4}$') { throw 'A quoted TOML key has an invalid Unicode escape.' }
                $null = $builder.Append([char][Convert]::ToInt32($hex, 16))
                $index += 4
            }
            default { throw "A quoted TOML key contains unsupported escape \$escaped." }
        }
    }

    return $builder.ToString()
}

function ConvertFrom-TomlKeyPath {
    param([Parameter(Mandatory)][string]$Text)

    $segments = [System.Collections.Generic.List[string]]::new()
    $index = 0
    while ($index -lt $Text.Length) {
        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) { $index++ }
        if ($index -ge $Text.Length) { throw "Invalid empty TOML key in '$Text'." }

        if ($Text[$index] -eq '"') {
            $index++
            $start = $index
            $escaped = $false
            while ($index -lt $Text.Length) {
                if (-not $escaped -and $Text[$index] -eq '"') { break }
                if (-not $escaped -and $Text[$index] -eq '\') { $escaped = $true }
                else { $escaped = $false }
                $index++
            }
            if ($index -ge $Text.Length) { throw "Unterminated quoted TOML key in '$Text'." }
            $segments.Add((ConvertFrom-TomlBasicString -Value $Text.Substring($start, $index - $start)))
            $index++
        }
        elseif ($Text[$index] -eq "'") {
            $index++
            $start = $index
            while ($index -lt $Text.Length -and $Text[$index] -ne "'") { $index++ }
            if ($index -ge $Text.Length) { throw "Unterminated literal TOML key in '$Text'." }
            $segments.Add($Text.Substring($start, $index - $start))
            $index++
        }
        else {
            $start = $index
            while ($index -lt $Text.Length -and $Text[$index] -match '[A-Za-z0-9_-]') { $index++ }
            if ($start -eq $index) { throw "Invalid TOML key in '$Text'." }
            $segments.Add($Text.Substring($start, $index - $start))
        }

        while ($index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$index])) { $index++ }
        if ($index -eq $Text.Length) { break }
        if ($Text[$index] -ne '.') { throw "Invalid TOML key path '$Text'." }
        $index++
    }

    return ,([string[]]$segments.ToArray())
}

function Find-TomlAssignmentEquals {
    param([Parameter(Mandatory)][string]$Line)

    $quote = [char]0
    $escaped = $false
    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        if ($quote -ne [char]0) {
            if ($quote -eq '"' -and -not $escaped -and $character -eq '\') { $escaped = $true; continue }
            if (-not $escaped -and $character -eq $quote) { $quote = [char]0 }
            $escaped = $false
            continue
        }
        if ($character -eq '"' -or $character -eq "'") { $quote = $character; continue }
        if ($character -eq '=') { return $index }
        if ($character -eq '#') { break }
    }

    return -1
}

function Get-TomlValueExtent {
    param(
        [Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][int]$StartLine,
        [Parameter(Mandatory)][int]$StartColumn
    )

    $squareDepth = 0
    $curlyDepth = 0
    $state = 'normal'
    $hasValue = $false
    for ($lineIndex = $StartLine; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex].Body
        $column = if ($lineIndex -eq $StartLine) { $StartColumn } else { 0 }
        while ($column -lt $line.Length) {
            $character = $line[$column]
            if ($state -eq 'basic') {
                if ($character -eq '\') { $column += 2; continue }
                if ($character -eq '"') { $state = 'normal' }
                $column++; continue
            }
            if ($state -eq 'literal') {
                if ($character -eq "'") { $state = 'normal' }
                $column++; continue
            }
            if ($state -eq 'multibasic') {
                if ($column + 2 -lt $line.Length -and $line.Substring($column, 3) -eq '"""') { $state = 'normal'; $column += 3; continue }
                if ($character -eq '\') { $column += 2; continue }
                $column++; continue
            }
            if ($state -eq 'multiliteral') {
                if ($column + 2 -lt $line.Length -and $line.Substring($column, 3) -eq "'''") { $state = 'normal'; $column += 3; continue }
                $column++; continue
            }

            if ($character -eq '#') { break }
            if ([char]::IsWhiteSpace($character)) { $column++; continue }
            $hasValue = $true
            if ($column + 2 -lt $line.Length -and $line.Substring($column, 3) -eq '"""') { $state = 'multibasic'; $column += 3; continue }
            if ($column + 2 -lt $line.Length -and $line.Substring($column, 3) -eq "'''") { $state = 'multiliteral'; $column += 3; continue }
            if ($character -eq '"') { $state = 'basic'; $column++; continue }
            if ($character -eq "'") { $state = 'literal'; $column++; continue }
            switch ($character) {
                '[' { $squareDepth++ }
                ']' { $squareDepth--; if ($squareDepth -lt 0) { throw "Unexpected ] on TOML line $($lineIndex + 1)." } }
                '{' { $curlyDepth++ }
                '}' { $curlyDepth--; if ($curlyDepth -lt 0) { throw "Unexpected } on TOML line $($lineIndex + 1)." } }
            }
            $column++
        }

        if ($state -eq 'basic' -or $state -eq 'literal') {
            throw "Unterminated string on TOML line $($lineIndex + 1)."
        }
        if ($state -eq 'normal' -and $squareDepth -eq 0 -and $curlyDepth -eq 0) {
            if (-not $hasValue) { throw "Missing TOML value on line $($StartLine + 1)." }
            return $lineIndex
        }
    }

    throw "Unterminated TOML value beginning on line $($StartLine + 1)."
}

function Get-TomlDocument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $lines = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Content, '([^\r\n]*)(\r\n|\n|\r|$)')) {
        if ($match.Length -eq 0) { continue }
        $lines.Add([pscustomobject]@{ Body = $match.Groups[1].Value; Eol = $match.Groups[2].Value })
    }

    $statements = [System.Collections.Generic.List[object]]::new()
    $context = @()
    $seenTables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $trimmed = $lines[$lineIndex].Body.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        if ($trimmed.StartsWith('[')) {
            if ($trimmed -notmatch '^(\[\[|\[)(.*?)(\]\]|\])\s*(?:#.*)?$') {
                throw "Malformed TOML table header on line $($lineIndex + 1)."
            }
            $openingBrackets = $Matches[1]
            $headerText = $Matches[2]
            $closingBrackets = $Matches[3]
            $isArray = $openingBrackets -eq '[['
            if (($isArray -and $closingBrackets -ne ']]') -or (-not $isArray -and $closingBrackets -ne ']')) {
                throw "Mismatched TOML table brackets on line $($lineIndex + 1)."
            }
            [string[]]$path = (ConvertFrom-TomlKeyPath -Text $headerText)
            $canonical = $path -join ([char]31)
            if (-not $isArray -and -not $seenTables.Add($canonical)) {
                throw "Duplicate TOML table [$($path -join ([char]31))] on line $($lineIndex + 1)."
            }
            $context = $path
            $statements.Add([pscustomobject]@{ Type = if ($isArray) { 'ArrayTable' } else { 'Table' }; Start = $lineIndex; End = $lineIndex; Path = $path; KeyPath = @() })
            continue
        }

        $equals = Find-TomlAssignmentEquals -Line $lines[$lineIndex].Body
        if ($equals -lt 0) { throw "Expected a TOML assignment on line $($lineIndex + 1)." }
        [string[]]$keyPath = (ConvertFrom-TomlKeyPath -Text $lines[$lineIndex].Body.Substring(0, $equals))
        $fullPath = @($context) + @($keyPath)
        $canonical = $fullPath -join ([char]31)
        if (-not $seenKeys.Add($canonical)) {
            throw "Duplicate TOML key '$($fullPath -join '.')' on line $($lineIndex + 1) (context '$($context -join '.')', key '$($keyPath -join '.')')."
        }
        $statementStart = $lineIndex
        $endLine = Get-TomlValueExtent -Lines $lines.ToArray() -StartLine $statementStart -StartColumn ($equals + 1)
        if ($endLine -lt $statementStart) { throw "Internal TOML parser error on line $($statementStart + 1)." }
        $statements.Add([pscustomobject]@{ Type = 'Assignment'; Start = $statementStart; End = $endLine; Path = @($context); KeyPath = $keyPath })
        $lineIndex = $endLine
    }

    return [pscustomobject]@{ Lines = $lines.ToArray(); Statements = $statements.ToArray() }
}

function ConvertTo-TomlString {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.IndexOfAny([char[]]@([char]0, "`r", "`n")) -ge 0) {
        throw 'Codex setting values cannot contain NUL or newline characters.'
    }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t') + '"'
}

$fullConfigPath = [System.IO.Path]::GetFullPath($Path)
$fullCatalogPath = [System.IO.Path]::GetFullPath($ModelCatalogPath)
$fullHelperPath = [System.IO.Path]::GetFullPath($HelperPath)
foreach ($value in @($BaseUrl, $DefaultModel, $fullCatalogPath, $fullHelperPath)) {
    if ($value.IndexOfAny([char[]]@([char]0, "`r", "`n")) -ge 0) { throw 'Codex setting values cannot contain NUL or newline characters.' }
}
$baseUri = $null
if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri) -or $baseUri.Scheme -notin @('http', 'https')) {
    throw 'BaseUrl must be an absolute HTTP or HTTPS URL.'
}

$hadFile = Test-Path -LiteralPath $fullConfigPath
$hadBom = $false
if ($hadFile) {
    $bytes = [System.IO.File]::ReadAllBytes($fullConfigPath)
    $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hadBom) { 3 } else { 0 }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try { $content = $utf8.GetString($bytes, $offset, $bytes.Length - $offset) }
    catch { throw "Codex config at $fullConfigPath is not valid UTF-8; it was not changed." }
}
else {
    $content = ''
}

try { $document = Get-TomlDocument -Content $content }
catch { throw "Codex config at $fullConfigPath is malformed or cannot be merged safely: $($_.Exception.Message) It was not changed." }

$rootOwned = @{
    model = "model = $(ConvertTo-TomlString $DefaultModel)"
    model_provider = 'model_provider = "ghcp"'
    model_catalog_json = "model_catalog_json = $(ConvertTo-TomlString $fullCatalogPath)"
}
$providerOwned = @{
    name = 'name = "GitHub Copilot via LiteLLM"'
    base_url = "base_url = $(ConvertTo-TomlString $BaseUrl)"
    wire_api = 'wire_api = "responses"'
}
$authOwned = @{
    command = 'command = "powershell.exe"'
    args = "args = [`"-NoProfile`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", $(ConvertTo-TomlString $fullHelperPath)]"
    timeout_ms = 'timeout_ms = 45000'
    refresh_interval_ms = 'refresh_interval_ms = 300000'
}

$providerPath = @('model_providers', 'ghcp')
$authPath = @('model_providers', 'ghcp', 'auth')
$replacements = @{}
$deletions = [System.Collections.Generic.HashSet[int]]::new()
$foundRoot = @{}
$foundProvider = @{}
$foundAuth = @{}
$providerTable = $null
$authTable = $null
$firstTableLine = $document.Lines.Count

foreach ($statement in $document.Statements) {
    if ($statement.Type -ne 'Assignment' -and $firstTableLine -eq $document.Lines.Count) { $firstTableLine = $statement.Start }
    [string[]]$path = @($statement.Path | ForEach-Object { $_ })
    if ($statement.Type -eq 'ArrayTable') {
        $touchesGhcp = $path.Count -ge 2 -and $path[0] -ceq 'model_providers' -and $path[1] -ceq 'ghcp'
        if ($touchesGhcp) { throw "Codex config uses an array-of-tables inside model_providers.ghcp on line $($statement.Start + 1); it was not changed." }
    }
    if ($statement.Type -eq 'Table') {
        if ((($path -join ([char]31)) -ceq ("model_providers$([char]31)ghcp"))) { $providerTable = $statement }
        elseif ((($path -join ([char]31)) -ceq ("model_providers$([char]31)ghcp$([char]31)auth"))) { $authTable = $statement }
        elseif ($path.Count -ge 2 -and $path[0] -ceq 'model_providers' -and $path[1] -ceq 'ghcp') {
            throw "Codex config contains unsupported nested GHCP table [$($path -join ([char]31))] on line $($statement.Start + 1); it was not changed."
        }
        elseif ($path.Count -eq 1 -and $rootOwned.ContainsKey($path[0])) {
            throw "Codex config defines '$($path[0])' as a table; it was not changed."
        }
        continue
    }

    [string[]]$keyPath = @($statement.KeyPath | ForEach-Object { $_ })
    if ($statement.Path.Count -eq 0 -and $statement.KeyPath.Count -eq 1 -and $rootOwned.ContainsKey($keyPath[0])) {
        $replacements[$statement.Start] = $rootOwned[$keyPath[0]]
        for ($line = $statement.Start + 1; $line -le $statement.End; $line++) { $null = $deletions.Add($line) }
        $foundRoot[$keyPath[0]] = $true
    }
    elseif ((($path -join ([char]31)) -ceq ("model_providers$([char]31)ghcp")) -and $keyPath.Count -eq 1 -and $providerOwned.ContainsKey($keyPath[0])) {
        $replacements[$statement.Start] = $providerOwned[$keyPath[0]]
        for ($line = $statement.Start + 1; $line -le $statement.End; $line++) { $null = $deletions.Add($line) }
        $foundProvider[$keyPath[0]] = $true
    }
    elseif ((($path -join ([char]31)) -ceq ("model_providers$([char]31)ghcp$([char]31)auth")) -and $keyPath.Count -eq 1 -and $authOwned.ContainsKey($keyPath[0])) {
        $replacements[$statement.Start] = $authOwned[$keyPath[0]]
        for ($line = $statement.Start + 1; $line -le $statement.End; $line++) { $null = $deletions.Add($line) }
        $foundAuth[$keyPath[0]] = $true
    }
    elseif ($path.Count -eq 0 -and $keyPath.Count -gt 0 -and ($rootOwned.ContainsKey($keyPath[0]) -or $keyPath[0] -ceq 'model_providers')) {
        throw "Codex config uses a dotted or inline assignment for owned setting '$($keyPath -join '.')' on line $($statement.Start + 1); it was not changed."
    }
    elseif ($path.Count -eq 1 -and $path[0] -ceq 'model_providers' -and $keyPath.Count -gt 0 -and $keyPath[0] -ceq 'ghcp') {
        throw "Codex config defines model_providers.ghcp inline on line $($statement.Start + 1); it was not changed."
    }
    elseif ((($path -join ([char]31)) -ceq ("model_providers$([char]31)ghcp")) -and $keyPath.Count -gt 0 -and $keyPath[0] -ceq 'auth') {
        throw "Codex config defines model_providers.ghcp.auth inline on line $($statement.Start + 1); it was not changed."
    }
}
$newline = "`r`n"
foreach ($line in $document.Lines) { if ($line.Eol) { $newline = $line.Eol; break } }
$insertBefore = @{}
function Add-Insertion {
    param([int]$Index, [string[]]$Bodies)
    if (-not $insertBefore.ContainsKey($Index)) { $insertBefore[$Index] = [System.Collections.Generic.List[string]]::new() }
    foreach ($body in $Bodies) { $insertBefore[$Index].Add($body) }
}
function Get-SectionEnd {
    param($Table)
    foreach ($statement in $document.Statements) {
        if ($statement.Start -gt $Table.Start -and $statement.Type -ne 'Assignment') { return $statement.Start }
    }
    return $document.Lines.Count
}

$missingRoot = @($rootOwned.Keys | Where-Object { -not $foundRoot.ContainsKey($_) } | Sort-Object { @('model', 'model_provider', 'model_catalog_json').IndexOf($_) })
if ($missingRoot.Count) { Add-Insertion $firstTableLine @($missingRoot | ForEach-Object { $rootOwned[$_] }) }

if ($providerTable) {
    $missing = @($providerOwned.Keys | Where-Object { -not $foundProvider.ContainsKey($_) } | Sort-Object { @('name', 'base_url', 'wire_api').IndexOf($_) })
    if ($missing.Count) { Add-Insertion (Get-SectionEnd $providerTable) @($missing | ForEach-Object { $providerOwned[$_] }) }
}
else {
    $at = if ($authTable) { $authTable.Start } else { $document.Lines.Count }
    Add-Insertion $at @('', '[model_providers.ghcp]', $providerOwned.name, $providerOwned.base_url, $providerOwned.wire_api)
}

if ($authTable) {
    $missing = @($authOwned.Keys | Where-Object { -not $foundAuth.ContainsKey($_) } | Sort-Object { @('command', 'args', 'timeout_ms', 'refresh_interval_ms').IndexOf($_) })
    if ($missing.Count) { Add-Insertion (Get-SectionEnd $authTable) @($missing | ForEach-Object { $authOwned[$_] }) }
}
else {
    Add-Insertion $document.Lines.Count @('', '[model_providers.ghcp.auth]', $authOwned.command, $authOwned.args, $authOwned.timeout_ms, $authOwned.refresh_interval_ms)
}

$builder = [System.Text.StringBuilder]::new()
for ($lineIndex = 0; $lineIndex -le $document.Lines.Count; $lineIndex++) {
    if ($insertBefore.ContainsKey($lineIndex)) {
        if ($builder.Length -gt 0 -and -not ($builder.ToString().EndsWith("`n") -or $builder.ToString().EndsWith("`r"))) { $null = $builder.Append($newline) }
        foreach ($body in $insertBefore[$lineIndex]) { $null = $builder.Append($body).Append($newline) }
    }
    if ($lineIndex -eq $document.Lines.Count -or $deletions.Contains($lineIndex)) { continue }
    $body = if ($replacements.ContainsKey($lineIndex)) { $replacements[$lineIndex] } else { $document.Lines[$lineIndex].Body }
    $null = $builder.Append($body).Append($document.Lines[$lineIndex].Eol)
}
$newContent = $builder.ToString()

if ($newContent -ceq $content) {
    Write-Output "Codex config is already up to date: $fullConfigPath"
    return
}

$directory = Split-Path -Parent $fullConfigPath
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$backupPath = $null
if ($hadFile) {
    do { $backupPath = "$fullConfigPath.$(Get-Date -Format 'yyyyMMdd-HHmmssfff').bak" } while (Test-Path -LiteralPath $backupPath)
    Copy-Item -LiteralPath $fullConfigPath -Destination $backupPath
}

$encoding = [System.Text.UTF8Encoding]::new($hadBom)
$temporaryPath = "$fullConfigPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [System.IO.File]::WriteAllText($temporaryPath, $newContent, $encoding)
    Move-Item -LiteralPath $temporaryPath -Destination $fullConfigPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}

if ($backupPath) { Write-Output "Updated Codex config; backup: $backupPath" }
else { Write-Output "Created Codex config: $fullConfigPath" }
