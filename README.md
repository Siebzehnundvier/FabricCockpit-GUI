# Fabric Capacity Cockpit - WinForms GUI

A standalone Windows window (PowerShell 5.1 + WinForms) to control **pay-as-you-go
Fabric capacities (F-SKU)** across all your Azure subscriptions: pick a capacity,
see **status / SKU / month-to-date cost**, **Pause** / **Resume** with live progress,
an **auto-pause timer**, a **tray icon** with state colour and menu, and direct
links to the portal, cost analysis and the Metrics app.

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

Double-click `Start-Cockpit.cmd` (or `Start-Cockpit.vbs`). No console window stays
open: the `.cmd` hands over to the VBScript launcher, which starts PowerShell without
a console, and the script hides any console it might still have inherited.

The cockpit puts an icon into the notification area (tray). On Windows 11 new tray
icons land in the **overflow** first - click the `^` arrow next to the clock to see
it, or drag it onto the taskbar (Settings > Personalization > Taskbar > *Other system
tray icons* to pin it permanently).

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

**Capacity Info** - name, subscription, resource group, region, SKU, status (with
the time of the last refresh next to it), provisioning state and the **month-to-date
cost of this capacity** (Cost Management query at resource level, cached 10 minutes,
429 retry). Refreshes every 30 s (checkbox) or via **Refresh**.

**Resume / Pause** - confirmation dialog (the pause dialog repeats the storage hint),
then the command is sent with `--no-wait` and the state is **polled every 5 s**:
progress bar, `Resuming ... (00:42)` counter and a **Stop waiting** button. *Stop
waiting* only stops the polling in this window - the operation in Azure continues.
After 10 minutes without reaching the target state the cockpit gives up polling and
points you to the portal.

**Auto-pause** (under *Capacity actions*) - `Off | in 15 | 30 | 60 | 120 minutes`.
Picking a span starts a countdown; when it elapses the selected capacity is paused
- regardless of what happens in the cockpit or on the capacity (a running refresh
or notebook is not detected). The cockpit only has to keep running (window or
tray). The countdown is shown next to the selector (`pauses at 16:06 (in 14:57)`).
Two minutes before the deadline a yellow banner appears with **Pause now**,
**Extend** (postpones by the chosen span) and **Cancel**; in the tray a balloon
notification is shown as well. Without a reaction the capacity is paused (no
further dialog) and the trigger is logged. The timer is one-shot: afterwards the
selector returns to *Off*. It is not persisted across restarts.

**Tray icon** - the cockpit always has a tray icon whose colour follows the
capacity state (green *Active*, amber *Paused*, blue while pausing/resuming, grey
unknown, red not signed in); the tooltip shows capacity, state and a running
auto-pause deadline. Right-click menu: **Open cockpit**, **Resume**, **Pause**,
**Exit**. Closing the window with **X** only hides it to the tray - the cockpit
(auto-refresh, auto-pause, polling) keeps running; **Exit** in the tray menu quits.
Double-click the icon to bring the window back. Resume/Pause from the tray ask
for the same confirmation as the buttons.

**Click here for details** - **Capacity Overview** (Azure portal), **Cost Analysis
(RG)** (cost analysis scoped to the capacity's resource group) and **Metrics App**
(`metricsAppUrl` from `settings.json`, or the Power BI Apps page).

**Log** - every action, error and state change is logged with a timestamp;
**Copy log** puts the log on the clipboard.

## Settings - `%APPDATA%\FabricCockpit\settings.json`

Created on first start; no secrets.

```json
{
  "lastCapacity": { "subscriptionId": "", "resourceGroup": "", "name": "" },
  "autoRefreshSeconds": 30,
  "metricsAppUrl": "",
  "capacityCache": [],
  "capacityCacheUpdated": ""
}
```

- `metricsAppUrl` - optional direct link to your Fabric Capacity Metrics app report;
  the only value you may want to set by hand.

## Layout

| Path | Purpose |
|------|---------|
| `Fabric-Cockpit.ps1` | The WinForms window (UI, background runspaces, polling, auto-pause, tray icon) |
| `Start-Cockpit.cmd` | Launcher for double-click; delegates to the `.vbs` |
| `Start-Cockpit.vbs` | Launcher without a console window (PowerShell 5.1, STA) |
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
- PowerShell variable names are **case-insensitive**: `$st` and `$ST` are the same
  variable. The GUI therefore uses multi-letter names for its containers (`$ST`
  state, `$UI` controls, `$TM` timers, `$ICO` icons) and avoids single-letter
  loop variables that could collide. A quick collision check:
  `grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' Fabric-Cockpit.ps1 | sort -u | awk '{k=tolower($0); if (k in s && s[k]!=$0) print s[k]" <-> "$0; s[k]=$0}'`

## Related

The same core actions as VS Code tasks / status-bar buttons live in the separate
`FabricCockpit-VSCode` project (own repository, own configuration).
