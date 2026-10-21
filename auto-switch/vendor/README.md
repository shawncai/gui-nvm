# Vendored node-semver 7.7.3

The auto-switch resolver uses the exact `semver@7.7.3` package from the official
npm registry. It has no runtime dependencies and supports Node.js >= 10. The
original package files, including the ISC license, are kept unchanged in
`node-semver/`. The upstream package scripts are metadata only: installation and
execution of this fork do not run them or install its development dependencies.

## Review completed on 2026-10-21 (Asia/Shanghai)

- Official source: <https://github.com/npm/node-semver>, commit
  `a25789b09b1192fa8414c35f2cd679ae2e1d5192`.
- Release: <https://github.com/npm/node-semver/releases/tag/v7.7.3>. This release
  includes the fix for x-ranges with build metadata; it is pinned intentionally.
- Registry metadata: <https://registry.npmjs.org/semver/7.7.3>.
- Archive: <https://registry.npmjs.org/semver/-/semver-7.7.3.tgz>.
- Verified archive SHA-512 against the registry `dist.integrity`; independently
  recorded SHA-256, SHA-512 and legacy SHA-1 in `semver-7.7.3.provenance.json`.
- Verified the package declares ISC licensing, retained the complete `LICENSE`,
  and confirmed that it has no runtime dependencies.
- Inspected the package's runtime imports: they are relative to this package,
  with no project-local dependency lookup, network client, or installation hook.
- Queried the [OSV API](https://google.github.io/osv.dev/post-v1-query/) for the
  exact npm package/version; it returned `{}` (no matching advisories).
- Queried the [GitHub Advisory API](https://api.github.com/advisories?ecosystem=npm&affects=semver%407.7.3&per_page=100)
  for the exact package/version; it returned `[]`.
- Reviewed [CVE-2022-25883](https://github.com/advisories/GHSA-c2qf-rxjj-qqgw)
  (fixed in 7.x at 7.5.2) and
  [CVE-2015-8855](https://github.com/advisories/GHSA-x6fg-f45m-jf5q) (older
  versions). Neither includes 7.7.3 in its affected range.

These are point-in-time checks, not a guarantee against future advisories.
Registry metadata lists signing/provenance information; this review verified
archive integrity over HTTPS, and does not claim independent verification of
the registry signature or SLSA attestation.

## Maintenance

Updates require explicit review and an exact version change; there is no
runtime download or automatic dependency update. Repeat the source, license,
integrity, imports and advisory checks before replacing the package. Preserve
the upstream license and refresh the per-file SHA-256 inventory. Then run:

```sh
python3 auto-switch/verify-vendor.py
node auto-switch/test-resolve.cjs
```

`verify-vendor.py` is offline and checks the complete vendored inventory. It
does not fetch or update packages. The resolver reads project manifests with
`JSON.parse`, rejects oversized or invalid input, and never requires a project
manifest, entry point, or dependency. The zsh caller runs an installed Node by
absolute path with `NODE_OPTIONS` and `NODE_PATH` removed from the child
environment.
