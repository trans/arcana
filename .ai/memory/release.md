# Releasing

*Updated 2026-10-08*

- Order: arcana-core, then arcana-ai, then arcana (which depends on both).
  arcana-ai has no arcana-core dependency.
- Each release: bump `shard.yml` and the `VERSION` constant, run the specs,
  commit as `Bump to X.Y.Z — summary` (body says what and why), tag
  `vX.Y.Z`, push `main` and the tag, then `gh release create`.
- arcana also needs `pkg/PKGBUILD` (`pkgver`) and a new
  `pkg/debian/changelog` entry, plus `shards update <dep>` for a
  dependency bump.
- Publishing the GitHub release runs `.github/workflows/package.yml`,
  which builds the .deb and Arch packages **from the tag**: a packaging fix
  committed after tagging doesn't reach that release. Cut a new patch
  version instead.
- Installing on an Arch machine: `pacman -U` the release's
  `.pkg.tar.zst`, run `arcana setup`, restart the `arcana` service.
- `bin/arcana.cr` builds tool schemas from `JSON.parse(%(...))` literals
  that only run when the matching provider key is set, so no spec used to
  load them; 0.31.0 and 0.31.1 crashed at startup with `OPENAI_API_KEY` set.
  `spec/bin_schemas_spec.cr` now parses every literal.
