# Fabric Capacity Cockpit - WinForms GUI

A standalone Windows window (PowerShell 5.1 + WinForms) to control **pay-as-you-go
Fabric capacities (F-SKU)** across all your Azure subscriptions: pick a capacity,
see **status / SKU / month-to-date cost**, **Pause** / **Resume** with live progress,
optional **auto-pause** after cockpit inactivity, and direct links to the portal,
cost analysis and the Metrics app.

> Designed for F-SKUs with pay-as-you-go billing. Pausing saves the compute cost;
> OneLake storage is still billed. With an existing reservation, pausing yields no
> savings - this tool cannot detect reservations.

## Prerequisites

1. **Azure CLI** installed and in `PATH` (`az --version`). If missing: https://aka.ms/installazurecli
   The `microsoft-fabric` extension is installed automatically on first start.
2. **Permissions on the capacity**: Reader for viewing; Pause/Resume need a role with
   `Microsoft.Fabric/capacities/suspend/action` and `.../resume/action`
   (e.g. **Contributor** on the capacity or resource group).
   The cost figure additionally needs **Cost Management Reader** (or higher).
3. **Windows PowerShell 5.1** (present on every Windows). The GUI runs in STA mode;
   the launcher already passes `-STA`. PowerShell 7 is untested.

No credentials are stored anywhere - sign-in is delegated to `az login`.

## Start

Double-click `Start-Cockpit.cmd`.

## What the window does

**Sign-in header** - shows `user - Tenant <id>` or `Not signed in`. When not signed
in, everything except **Sign in** is disabled. **Sign in** runs `az login` (a browser
window opens); once signed in, the button reads **Switch account** for a tenant/account
change. If a call fails because the token expired, the cockpit falls back to
*Sign-in expired* and disables the actions until you sign in again.

**Capacity picker** - lists all Fabric capacities of all enabled subscriptions
(`Name - Subscription / Resource group`, sorted by name). The list is cached in
`settings.json`, so the window is usable immediately; a fresh list loads in the
background. **Reload list** forces a re-query. The last selection is restored on
the next start.

**Capacity Info** - name, subscription, resource group, region, SKU, status,
provisioning state and the **month-to-date cost of this capacity** (Cost Management
query at resource level, cached 10 minutes, 429 retry). Refreshes every 30 s
(checkbox) or via **Refresh**.

**Resume / Pause** - confirmation dialog (the pause dialog repeats the storage hint),
then the command is sent with `--no-wait` and the state is **polled every 5 s**:
progress bar, `Resuming ... (00:42)` counter and a **Stop waiting** button. *Stop
waiting* only stops the polling in this window - the operation in Azure continues.
After 10 minutes without reaching the target state the cockpit gives up polling and
points you to the portal.

**Auto-pause on inactivity** - `Off | 15 | 30 | 60 | 120 minutes`, default *Off*,
persisted. *Inactivity* means **no interaction with this window** (button clicks,
capacity change, manual refresh, settings changes). It does **not** detect load on
the capacity - a running refresh or notebook is not seen. Two minutes before the
deadline a yellow banner appears with **Pause now**, **Extend** and **Disable for
today**; without a reaction the capacity is paused (no further dialog) and the
trigger is logged. The automatic 30 s refresh does not count as interaction.

**Open** - **Capacity Overview** (Azure portal), **Cost Analysis (RG)** (cost analysis
scoped to the capacity's resource group) and **Metrics App** (`metricsAppUrl` from
`settings.json`, or the Power BI Apps page).

**Status line + Log** - every action, error and state change is logged with a
timestamp; **Copy log** puts the log on the clipboard.

## Settings - `%APPDATA%\FabricCockpit\settings.json`

Created on first start; no secrets.

```json
{
  "lastCapacity": { "subscriptionId": "", "resourceGroup": "", "name": "" },
  "autoRefreshSeconds": 30,
  "autoPauseMinutes": 0,
  "metricsAppUrl": "",
  "capacityCache": [],
  "capacityCacheUpdated": ""
}
```

- `metricsAppUrl` - optional direct link to your Fabric Capacity Metrics app report;
  the only value you may want to set by hand.
- `autoPauseMinutes` - any positive number works (the UI offers 15/30/60/120; a
  custom value from the file is shown as `n minutes (custom)`).

## Layout

| Path | Purpose |
|------|---------|
| `Fabric-Cockpit.ps1` | The WinForms window (UI, background runspaces, polling, auto-pause) |
| `Start-Cockpit.cmd` | Launcher (PowerShell 5.1, STA, hidden console) |
| `lib/Fabric-Common.ps1` | Settings, `az` calls (account, capacity list/status/suspend/resume), auth-error detection, links |
| `lib/Fabric-Cost.ps1` | `Invoke-FabricCostQuery` (Cost Management REST, cache + 429 retry) |
| `docs/` | Specification v2 incl. verification results |

## Notes

- **Cost** data in Azure has latency (up to ~24-48h). For the authoritative view use
  **Cost Analysis (RG)**.
- **Consumption (CU / utilization)** lives in the *Fabric Capacity Metrics app*
  (Power BI) - use the **Metrics App** button.
- **Pause & reports**: workspaces assigned to a paused capacity are unavailable
  until it is resumed.
- The scripts are ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less
  files as ANSI); special glyphs are built with `[char]`.

## Related

The same core actions as VS Code tasks / status-bar buttons live in the separate
`FabricCockpit-VSCode` project (own repository, own configuration).
