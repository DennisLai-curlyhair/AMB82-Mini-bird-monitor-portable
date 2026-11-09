# 0.15.1-manual-calibration

- Manual ZERO/MASS/TARE no longer depend on camera or bird gating.
- TARE uses its own stable calibration window; regular monitoring protections remain.
- Firmware upgrade required; data, photos and settings preserved.

# 0.15.0-robust-weight

- Default and minimum bird confidence are 20%; grouping similarity remains 76%.
- Median-of-five measurements and five-second confirmation for large stable changes.
- Rolling trimmed calibration windows wait up to 30 seconds, with bounded adaptive zero-noise tolerance.
- Added calibration wait reasons, raw diagnostics and old-firmware warning.
- Portable update preserves data, records, settings and runtime. Requires new firmware upload.

# 0.14.1-portable

- Added a Windows x64 portable distribution with embedded Python and Pillow.
- Included independent SQLite snapshot, images, event records and firmware backup.
- Added single-instance, port-conflict checks, explicit offline mode and graceful stop request.
- Migrated event cursors from absolute paths to stable record filenames to prevent replay after relocation.
- Hardware firmware and visual/weight algorithms are unchanged.
