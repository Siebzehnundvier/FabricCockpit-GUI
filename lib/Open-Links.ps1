# Opens portal / cost / metrics links.
#  portal  -> Azure portal overview of the Fabric capacity
#  cost    -> saved cost view (config 'costAnalysisUrl') or RG-scoped cost analysis
#  metrics -> Metrics app (config 'metricsAppUrl') or the Power BI Apps list page
param([ValidateSet('portal','cost','metrics','all')][string]$Target = 'all')
. "$PSScriptRoot/Fabric-Common.ps1"
$cfg = Get-FabricConfig
Assert-Az

if (-not [string]::IsNullOrWhiteSpace($cfg.subscription)) {
    $subId = az account show --subscription $cfg.subscription --query id -o tsv 2>$null
} else {
    $subId = az account show --query id -o tsv 2>$null
}

$resId   = "/subscriptions/$subId/resourceGroups/$($cfg.resourceGroup)/providers/Microsoft.Fabric/capacities/$($cfg.capacityName)"
$rgScope = "/subscriptions/$subId/resourceGroups/$($cfg.resourceGroup)"
$encRg   = [uri]::EscapeDataString($rgScope)

$portal = "https://portal.azure.com/#@/resource$resId/overview"

if (-not [string]::IsNullOrWhiteSpace($cfg.costAnalysisUrl)) {
    $cost = $cfg.costAnalysisUrl
} else {
    $cost = "https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/scope/$encRg"
}

if (-not [string]::IsNullOrWhiteSpace($cfg.metricsAppUrl)) {
    $metrics = $cfg.metricsAppUrl
} else {
    $metrics = "https://app.powerbi.com/groups/me/apps"
}

function Open-Url([string]$u) { Start-Process $u }

switch ($Target) {
    'portal'  { Open-Url $portal }
    'cost'    { Open-Url $cost }
    'metrics' { Open-Url $metrics }
    'all'     { Open-Url $portal; Open-Url $cost; Open-Url $metrics }
}
Write-Host 'Links opened.' -ForegroundColor Green
