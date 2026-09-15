# Fabric Capacity Cockpit - WinForms GUI

A standalone Windows window (PowerShell 5.1 + WinForms) to control **pay-as-you-go
Fabric capacities (F-SKU)** across all your Azure subscriptions: pick a capacity,
see **status / SKU / month-to-date cost**, **Pause** / **Resume** with live progress,
an **auto-pause timer**, a **tray icon** with state colour and menu, and direct
links to the portal, cost analysis and the Metrics app.

> Designed for F-SKUs with pay-as-you-go billing. Pausing saves the compute cost;
> OneLake storage is still billed. With an existing reservation, pausing yields no
> savings - this tool cannot detect reservations.

**Read [Before you pause anything](#before-you-pause-anything) first.** The tool
does exactly what the Azure portal would do - including making every workspace on
a paused capacity unavailable.

---

## Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [First start](#first-start)
4. [What the window does](#what-the-window-does)
5. [Before you pause anything](#before-you-pause-anything)
6. [Settings](#settings---appdatafabriccockpitsettingsjson)
7. [Troubleshooting](#troubleshooting)
8. [Security and privacy](#security-and-privacy)
9. [Uninstall](#uninstall)
10. [Files](#files)
11. [Distributing the tool](#distributing-the-tool)
12. [License and disclaimer](#license-and-disclaimer)

---

## Requirements

| What | Detail |
|------|--------|
| **Windows 10 / 11** | Uses WinForms (.NET Framework, part of Windows) and Windows PowerShell 5.1 (present on every Windows). PowerShell 7 is untested. |
| **Azure CLI** | `az --version` must work in a terminal. Install: https://aka.ms/installazurecli - no admin rights needed for the MSI per-user install. |
| **Internet access** | To Azure (`management.azure.com`, `login.microsoftonline.com`). On first start the CLI extension `microsoft-fabric` is downloaded once from the Azure CLI extension index. |
| **Azure account** | A user account that can see the Fabric capacity. Sign-in happens in the browser via `az login`; the tool never sees your password. |
| **Permissions** | Reader on the capacity or resource group: view only. **Pause / Resume** additionally need `Microsoft.Fabric/capacities/suspend/action` and `.../resume/action` - e.g. **Contributor** on the capacity. The cost figure needs **Cost Management Reader** on the subscription or resource group; without it the field shows `n/a` and everything else still works. |
| **Script execution** | The launcher passes `-ExecutionPolicy Bypass` for its own process only; no machine-wide policy change. If your organisation blocks `wscript.exe` or unsigned scripts, see [Troubleshooting](#troubleshooting). |

No credentials are stored by the tool - it delegates sign-in and token handling
entirely to the Azure CLI.

## Installation

1. Unzip (or copy) the folder to any location, e.g. `C:\Tools\FabricCockpit-GUI`.
   No installer, no admin rights, no registry entries.
2. If the zip came from the internet, Windows may mark the files as "downloaded":
   right-click `Start-Cockpit.cmd`, `Start-Cockpit.vbs` and `Fabric-Cockpit.ps1`
   > *Properties* > tick **Unblock** (or unblock the zip before extracting). Without
   that, SmartScreen may show "Windows protected your PC" - *More info* > *Run anyway*
   works as well.
3. Make sure `az` works: open a terminal and run `az --version`.

Optional: create a shortcut to `Start-Cockpit.cmd` on the desktop or in the Start
menu; the shortcut can be set to *Run: Minimized* - it has no effect on the cockpit
window itself.

## First start

1. Double-click **`Start-Cockpit.cmd`** (or `Start-Cockpit.vbs`). No console window
   stays open.
2. The first start takes 20-40 s longer: the Azure CLI installs the
   `microsoft-fabric` extension. The log shows what is happening.
3. If you are not signed in, the header reads `Not signed in`. Click **Sign in** - a
   browser window opens for the Microsoft sign-in (device / work account as usual).
   Back in the cockpit the header turns green and the capacity list loads.
4. Pick a capacity in the dropdown. The card fills, the cost figure follows a moment
   later.
5. A **tray icon** (coloured dot) appears in the notification area. On Windows 11 new
   icons land in the **overflow** first - click the `^` arrow next to the clock, or
   drag the icon onto the taskbar to keep it visible.

## What the window does

**Sign-in header** - shows `user - Tenant <id>` (full tenant id and default
subscription in the tooltip) or `Not signed in`. When not signed in, everything
except **Sign in** is disabled. Once signed in, the button reads **Switch account**
for a tenant/account change (runs `az login` again). If a call fails because the
token expired, the cockpit falls back to *Sign-in expired* and disables the actions
until you sign in again.

**Capacity picker** - lists all Fabric capacities of all enabled subscriptions
(`Name - Subscription / Resource group`, sorted by name). The list is cached in
`settings.json`, so the window is usable immediately; a fresh list loads in the
background. **Reload list** forces a re-query. The last selection is restored on
the next start.

**Capacity Info** - name, subscription, resource group, region, SKU, status with the
time of the last refresh in brackets, provisioning state and the **month-to-date
cost of this capacity** (Cost Management query at resource level, cached 10 minutes,
retried on throttling). Refreshes every 30 s (checkbox) or via **Refresh**.

**Resume / Pause** - confirmation dialog (the pause dialog repeats the storage and
workspace hint), then the command is sent with `--no-wait` and the state is
**polled every 5 s**: progress bar, `Resuming ... (00:42)` counter and a
**Stop waiting** button. *Stop waiting* only stops the polling in this window - the
operation in Azure continues. After 10 minutes without reaching the target state
the cockpit gives up polling and points you to the portal.

**Auto-pause** (next to Resume / Pause) - `Off | in 15 | 30 | 60 | 120 minutes`.
Picking a span starts a countdown; when it elapses the selected capacity is paused
- regardless of what happens in the cockpit or on the capacity (a running refresh
or notebook is **not** detected). The cockpit only has to keep running (window or
tray). The countdown is shown next to the selector. Two minutes before the deadline
a yellow banner appears with **Pause now**, **Extend** (postpones by the chosen
span) and **Cancel**; in the tray a balloon notification is shown as well. Without a
reaction the capacity is paused (no further dialog) and the trigger is logged. The
timer is one-shot: afterwards the selector returns to *Off*. It does not survive a
restart of the cockpit.

**Tray icon** - colour follows the capacity state (green *Active*, amber *Paused*,
blue while pausing/resuming, grey unknown, red not signed in); the same dot is the
window icon. The tooltip shows capacity, state and a running auto-pause deadline.
Right-click menu: **Open cockpit**, **Resume**, **Pause**, **Exit**. Closing the
window with **X** only hides it to the tray - the cockpit (auto-refresh, auto-pause,
polling) keeps running; **Exit** in the tray menu quits. Double-click the icon to
bring the window back. Resume/Pause from the tray ask for the same confirmation as
the buttons.

**Click here for details** - **Capacity Overview** (Azure portal), **Cost Analysis
(RG)** (cost analysis scoped to the capacity's resource group) and **Metrics App**
(`metricsAppUrl` from `settings.json`, or the Power BI Apps page).

**Log** - every action, error and state change is logged with a timestamp;
**Copy log** puts the log on the clipboard (useful when asking for help).

## Before you pause anything

The tool issues the same ARM calls as the Azure portal. Consequences are the same:

- **Pausing makes every workspace assigned to the capacity unavailable** - reports,
  semantic models, lakehouses, pipelines, notebooks. Users see errors until the
  capacity is resumed. Scheduled refreshes and pipeline runs that are due while
  paused fail.
- **Pausing interrupts running work.** A refresh, notebook or Spark job that is in
  progress is aborted. The **auto-pause timer does not check for running work** - it
  pauses when the time is up. Use it only for capacities where you know nothing
  will be running (personal / dev / test capacities).
- **Resuming starts billing again immediately.** Pay-as-you-go compute is charged
  per second while the capacity is active - a resumed capacity that nobody pauses
  costs money until someone does.
- **OneLake storage is billed while paused.** Pausing removes the compute charge
  only.
- **Reservations are not detected.** If the capacity is covered by a reservation,
  pausing saves nothing and the tool cannot tell you.
- **The cost figure is approximate.** Azure cost data lags 24-48 h and the query is
  a best-effort read of Cost Management. For invoices use the portal.
- **Your permissions apply.** The tool can only do what your Azure account is
  allowed to do; nothing is elevated. Use a Reader-only account if you just want
  to watch.

Confirmation dialogs guard every manual pause/resume; the auto-pause warns two
minutes ahead. Nothing in the tool deletes, scales or creates resources.

## Settings - `%APPDATA%\FabricCockpit\settings.json`

Created on first start; no secrets. Delete the file to reset the cockpit.

```json
{
  "lastCapacity": { "subscriptionId": "", "resourceGroup": "", "name": "" },
  "autoRefreshSeconds": 30,
  "metricsAppUrl": "",
  "capacityCache": [],
  "capacityCacheUpdated": ""
}
```

- `metricsAppUrl` - optional direct link to your Fabric Capacity Metrics app report
  (open the report in the browser and copy the address); the only value you may
  want to set by hand. Empty = the Power BI Apps page opens instead.
- `autoRefreshSeconds` - interval of the auto-refresh checkbox (minimum 5).
- `capacityCache` - the last capacity list (names, ids, resource groups, SKUs,
  states); maintained by the tool.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Header says **Azure CLI (az) not found** | Install the Azure CLI (link above) and restart the cockpit. If it is installed but not found: open a new terminal and check `az --version` - the PATH change of the installer needs a new process. |
| **Not signed in** although `az login` was done in a terminal | The cockpit uses the same CLI profile (`%USERPROFILE%\.azure`). If you use a custom `AZURE_CONFIG_DIR`, start the cockpit from an environment that has it set. Otherwise just click **Sign in**. |
| **Sign in** opens the browser, but nothing happens afterwards | Complete the sign-in in the browser; the CLI waits for the redirect. If a corporate policy blocks the local redirect, run `az login --use-device-code` in a terminal once, then click **Refresh**. |
| Log: *Warning: az extension 'microsoft-fabric' could not be installed* | No internet access to the extension index, or a proxy. Install it manually in a terminal: `az extension add --name microsoft-fabric`. |
| **No Fabric capacities found** | The signed-in account has no Reader access to any capacity, or you are in the wrong tenant - use **Switch account**. Trial capacities and Power BI Premium (P-SKU) are not Azure resources and never appear here. |
| Cost shows **n/a** | Missing *Cost Management Reader* role, or the query failed - see the log. Everything else works without it. |
| Cost shows **rate-limited (429)** | Cost Management throttles; the last cached value is kept and the query retries on the next refresh. |
| Cost shows **no data yet** | Normal for a capacity created in the last 1-2 days. |
| **Sign-in expired** during use | Token lifetime reached (typically after a day or a password/MFA policy change). Click **Sign in**; the cockpit resumes where it was. Timers are on hold until then. |
| Pause / Resume fails with an authorization error | Your account lacks `suspend/action` / `resume/action` on the capacity. Ask for Contributor on the capacity. |
| *Target state not reached after 10 minutes* | Azure is slow or the operation failed silently. Open **Capacity Overview** and check there; the cockpit keeps refreshing the state. |
| Tray icon not visible | Windows 11 hides new tray icons in the overflow: click `^` next to the clock. To pin it: *Settings > Personalization > Taskbar > Other system tray icons* > enable *Windows PowerShell*. |
| Double-click on `.cmd`/`.vbs` does nothing or shows a SmartScreen / "blocked" message | Files carry the download mark - see [Installation](#installation) step 2. If `wscript.exe` is blocked by policy, run instead: `powershell -NoProfile -ExecutionPolicy Bypass -STA -File Fabric-Cockpit.ps1` (a console window stays open in that case). |
| Window shows garbled characters | The scripts are ASCII-only on purpose; if you edited them with an editor that saved as UTF-8 **with** BOM or as UTF-16, restore the files from the zip. |
| Something else | **Copy log** and send the log along with your question - it contains the exact `az` command and error text, no secrets. |

## Security and privacy

- **What it stores:** `%APPDATA%\FabricCockpit\settings.json` (settings and the
  capacity list cache - names, resource ids, subscription ids, SKUs, states) and
  cost-query cache files `%TEMP%\fabcost_cache_*.json` (the raw Cost Management
  answer for the resource group). No tokens, no passwords.
- **Where it talks to:** only to Azure via the Azure CLI (`az` calls to the ARM
  and Cost Management REST APIs) and to the browser for the links you click. There
  is no telemetry, no update check, no other outbound connection.
- **How it runs:** as your Windows user, with your Azure permissions, in a normal
  PowerShell process. The launcher bypasses the execution policy for that one
  process only. All code is plain text - review it before use if your policy
  requires that.
- **What it can do:** read capacity metadata and cost, and issue *suspend* /
  *resume* on the selected capacity. It never deletes, scales or creates anything.

## Uninstall

1. **Exit** the cockpit via the tray menu.
2. Delete the program folder.
3. Delete `%APPDATA%\FabricCockpit` and `%TEMP%\fabcost_*.json`.
4. Optional: `az extension remove --name microsoft-fabric` if nothing else uses it;
   `az logout` if the machine is shared.

## Files

| Path | Purpose |
|------|---------|
| `Fabric-Cockpit.ps1` | The WinForms window (UI, background runspaces, polling, auto-pause, tray icon) |
| `Start-Cockpit.cmd` | Launcher for double-click; delegates to the `.vbs` |
| `Start-Cockpit.vbs` | Launcher without a console window (PowerShell 5.1, STA) |
| `lib/Fabric-Common.ps1` | Settings, `az` calls (account, capacity list/status/suspend/resume), auth-error detection, links |
| `lib/Fabric-Cost.ps1` | `Invoke-FabricCostQuery` (Cost Management REST, cache + 429 retry) |
| `LICENSE` | MIT license incl. warranty disclaimer |
| `README.md` | This file |
| `tools/Build-Release.ps1` | Packs the distributable files into a versioned zip (development only) |
| `docs/` | Internal specification and verification notes (development only, not shipped) |

## Distributing the tool

Ship the zip produced by `tools/Build-Release.ps1` - it contains exactly:
`Fabric-Cockpit.ps1`, `Start-Cockpit.cmd`, `Start-Cockpit.vbs`, `lib\*.ps1`,
`README.md`, `LICENSE`. The script refuses to build if any file contains something
that looks like a tenant/subscription id or a local user path. `docs/`, `tools/`,
`.git` and your `settings.json` are never included. The version number lives in
`$CockpitVersion` at the top of `Fabric-Cockpit.ps1` and is written to the log on
every start - bump it before you build.

Notes for the recipient are all in this README; nothing else is required. If you
hand the tool to people outside your organisation, keep the license file with it.

## License and disclaimer

MIT License - see [LICENSE](LICENSE). In short: free to use, copy and modify, no
warranty of any kind, no liability of the authors for any damage arising from the
use of the software.

The tool talks to your Azure subscription with your permissions. **You are
responsible for what it does on your behalf** - in particular for pausing a
capacity that others rely on and for the cost of a capacity left running. Read
[Before you pause anything](#before-you-pause-anything). This is not a Microsoft
product and is not affiliated with or endorsed by Microsoft.

## Development notes

- The scripts are ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less
  files as ANSI); special glyphs are built with `[char]`.
- PowerShell variable names are **case-insensitive**: `$st` and `$ST` are the same
  variable. The GUI therefore uses multi-letter names for its containers (`$ST`
  state, `$UI` controls, `$TM` timers, `$ICO` icons) and avoids single-letter
  loop variables that could collide. A quick collision check:
  `grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' Fabric-Cockpit.ps1 | sort -u | awk '{k=tolower($0); if (k in s && s[k]!=$0) print s[k]" <-> "$0; s[k]=$0}'`
- Verified 2026-09-13 against az 2.90.0 / microsoft-fabric 1.0.0b1: capacity
  states `Paused -> Resuming -> Active`, `Active -> Pausing -> Paused`; the CLI
  blocks without `--no-wait`. Details in `docs/`.
- The same core actions as VS Code tasks / status-bar buttons live in the separate
  `FabricCockpit-VSCode` project (own repository, own configuration).
