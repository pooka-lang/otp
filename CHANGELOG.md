# Changelog

## Unreleased

- Add typed `gen_statem` processes with supervisor integration, postponed events, and OTP timers.
- Add typed ETS tables with access modes, atomic updates, bounded scans, and ownership transfer.

## 1.1.0 - 2026-11-20

### Fixed

- Allow typed calls to remote subjects and server handles. Resolve remote process addresses without a local-only liveness check; monitors report process exits and node disconnections.

- Store typed keys in owner-scoped ETS slots rather than persistent terms. Keys remain shareable across processes, and storage is reclaimed when their creating process exits (#1).

## 1.0.0 - 2026-11-15

- Initial release.
