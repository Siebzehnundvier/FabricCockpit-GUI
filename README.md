# Fabric Capacity Cockpit - WinForms GUI

A standalone Windows window (PowerShell + WinForms) to control an Azure Fabric
capacity (`Microsoft.Fabric/capacities`): **Status**, **Pause**, **Resume**,
**month-to-date cost** and **direct links** - with auto-refresh.

## Prerequisites

1. **Azure CLI** installed (`az --version`). If missing: https://aka.ms/installazurecli
   The `microsoft-fabric` extension is installed automatically on first use.
2. **Signed in**: `az login` (once per session/machine).
3. **Permissions on the resource**: Pause/Resume require a role with
   `Microsoft.Fabric/capacities/suspend/action` and `.../resume/action`
   (e.g. **Contributor** on the capacity or resource group).
   The cost figure additionally needs **Cost Management Reader** (or higher).
4. **Windows PowerShell 5.1** (always present on Windows). The GUI must run in
   STA mode; the launcher already passes `-STA`.

## Configuration - `config.json`

`config.json` is **not** versioned (it holds subscription / tenant details).
Copy `config.example.json` to `config.json` once and fill in your values:

```json
{
  "subscription": "My Azure subscription",   // empty = current default subscription from az login
  "resourceGroup": "MyFabric",
  "capacityName": "meinefabrik",
  "sku": "F2",
  "location": "Germany West Central",
  "costAnalysisUrl": "",                     // optional: saved cost view in the Azure portal
  "metricsAppUrl": ""                        // optional: direct link to the Fabric Capacity Metrics app
}
```

Leave `subscription` empty to use the default chosen via `az account set`, or
enter a fixed subscription id or name (a name with spaces is fine).

## Usage

- **Start:** double-click `Start-Cockpit.cmd`.
- The status card shows name, subscription, resource group, region, SKU, status,
  provisioning state and the **month-to-date cost** of the capacity - all refreshed
  together every 30s (toggle with the checkbox) or on demand via **Refresh**.
- **Resume** / **Pause** ask for confirmation; Azure calls run in the background so the
  window stays responsive.
- Three link buttons: **Capacity Overview** (Azure portal overview of the capacity),
  **Accumulated Cost (RG)** (`costAnalysisUrl` from config.json, or the RG-scoped cost
  analysis) and **Metrics App** (`metricsAppUrl` from config.json, or the Power BI
  Apps list page).

## Layout

| Path | Purpose |
|------|---------|
| `Fabric-Cockpit.ps1` | The WinForms window (UI, background runspaces, handlers) |
| `Start-Cockpit.cmd` | Launcher (PowerShell 5.1, STA, hidden console) |
| `lib/Fabric-Common.ps1` | Config loading, `az` / login checks |
| `lib/Fabric-Cost.ps1` | `Invoke-FabricCostQuery` (Cost Management REST, cache + 429 retry) |
| `lib/Open-Links.ps1` | Builds and opens the portal / cost / metrics URLs |
| `config.json` | Capacity settings (see above) - local, not versioned |
| `config.example.json` | Template for `config.json` |
| `docs/` | Specification documents |

## Notes

- **Cost** data in Azure has latency (up to ~24-48h) and the value is an
  approximation at the resource-group level. For the authoritative view use the
  **Accumulated Cost (RG)** button.
- **Consumption (CU / utilization)** lives in the *Fabric Capacity Metrics app*
  (Power BI) - use the **Metrics App** button.
- **Pause & reports**: if a Power BI report runs on this capacity it is
  unavailable while paused.

## Related

The same actions as VS Code tasks / status-bar buttons live in the separate
`FabricCockpit-VSCode` project (own repository, own `config.json`).
