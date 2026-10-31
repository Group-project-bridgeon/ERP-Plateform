#Requires -Version 7.4
[CmdletBinding()]
param()

$platform = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path $platform -Parent
$localEnv = Join-Path $workspace "security-work\opening-stock-local\20261026-121217\local.env"

if (!(Test-Path -LiteralPath $localEnv -PathType Leaf)) {
    throw "Required local.env file not found at: $localEnv"
}

& (Join-Path $PSScriptRoot "opening-local-compose.ps1") -LocalEnvFile $localEnv -Action Validate
