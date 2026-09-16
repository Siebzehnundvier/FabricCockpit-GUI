# Changelog

All notable changes to the Fabric Capacity Cockpit (GUI). The version number
lives in `$CockpitVersion` at the top of `Fabric-Cockpit.ps1`.

## 0.52.0 - 2026-09-16

- Card value fields (Cost, Status, Provisioning, ...) now span the full card
  width and grow with the window. Previously they were cut off at 300 px, so
  the cost line ended in `(cached 14:`.
- Added this changelog; it ships with the release zip.

## 0.51.0 - 2026-09-16

- Cost (MTD) is split into compute and OneLake storage:
  `12.34 EUR (of which storage 0.87 EUR)`. The Cost Management query groups by
  `ResourceId` and `Meter`; stored-data meters count as storage, everything
  billed in CU (including OneLake read/write operations) as compute. The
  tooltip explains that the storage share keeps accruing while paused.
- Cost cache files renamed to `fabcost_cache_v2_*.json` so responses from
  older versions (without the meter column) are not reused.
- Version reset from 1.0.0 to 0.51.0 - the 1.0 tag was premature.
