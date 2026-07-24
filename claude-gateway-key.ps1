$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $root 'gateway-key.ps1')
