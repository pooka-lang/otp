# Changelog

## Unreleased

### Fixed

- Store typed keys in owner-scoped ETS slots rather than persistent terms. Keys remain shareable across processes, and storage is reclaimed when their creating process exits (#1).

## 1.0.0 - 2026-11-15

- Initial release.
