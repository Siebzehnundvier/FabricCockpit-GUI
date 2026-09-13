# Fabric-Common.ps1 - shared helper functions for the Fabric capacity cockpit.
# Dot-sourced by Fabric-Cockpit.ps1 and Open-Links.ps1.

$ErrorActionPreference = 'Stop'

function Get-FabricConfig {
    # lib/ lives under the project root -> root = parent directory
    $root = Split-Path -Parent $PSScriptRoot
    $configPath = Join-Path $root 'config.json'
    if (-not (Test-Path $configPath)) {
        throw "config.json not found at: $configPath"
    }
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    foreach ($k in 'resourceGroup','capacityName') {
        if ([string]::IsNullOrWhiteSpace($cfg.$k)) {
            throw "config.json: required field '$k' is missing or empty."
        }
    }
    return $cfg
}

function Assert-Az {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') was not found. Install it from: https://aka.ms/installazurecli"
    }
    $ext = az extension list --query "[?name=='microsoft-fabric'].name" -o tsv 2>$null
    if (-not $ext) {
        Write-Host "Installing az extension 'microsoft-fabric' (one-time) ..." -ForegroundColor Yellow
        az extension add --name microsoft-fabric --only-show-errors 2>&1 | Out-Null
    }
}

function Assert-LoggedIn {
    az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Not signed in to Azure. Please run 'az login' first."
    }
}

function Get-AzBaseArgs {
    param($cfg)
    $a = @('--resource-group', $cfg.resourceGroup, '--capacity-name', $cfg.capacityName)
    if (-not [string]::IsNullOrWhiteSpace($cfg.subscription)) {
        $a += @('--subscription', $cfg.subscription)
    }
    return $a
}

function Get-EffectiveSubscriptionName {
    param($cfg)
    if (-not [string]::IsNullOrWhiteSpace($cfg.subscription)) { return $cfg.subscription }
    $n = az account show --query name -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($n)) { return '(default from az login)' }
    return $n
}

function Confirm-Action {
    param([string]$Message)
    Write-Host ''
    $ans = Read-Host "$Message  [y/N]"
    return ($ans -match '^(y|yes)$')
}
