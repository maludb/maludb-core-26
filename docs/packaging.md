# MaluDB Debian packaging

Four binary packages ship from a single `dpkg-buildpackage` invocation:

| Package | Contents |
|---|---|
| `postgresql-16-maludb-core` | The PGXS extension built for PostgreSQL 16. |
| `postgresql-17-maludb-core` | The PGXS extension built for PostgreSQL 17. |
| `postgresql-18-maludb-core` | The PGXS extension built for PostgreSQL 18. |
| `maludb-mc2dbd` | The MC2DB listener daemon (`maludb_mc2dbd`) + systemd unit, with the four implementation_type dispatchers wired (`sql_function`, `external_exec`, `mcp_proxy`, `http_endpoint`). |

Each `postgresql-N-maludb-core` package carries `maludb_core.so`,
`maludb_core.control`, and every `maludb_core--X.Y--X.Z.sql`
migration script (72 SQL extension scripts in v0.71.0) under
`/usr/lib/postgresql/N/` and `/usr/share/postgresql/N/extension/`.
Operators install exactly the per-version package matching their
PG major.

The build host MUST be Ubuntu 24.04 (LTS noble) with PGDG installed.
See [docs/install.md §0](install.md) for the base-host requirements.

## Build

```bash
# From the source tree root:
dpkg-buildpackage -us -uc -b -nc
```

Flags:
- `-us -uc` — unsigned source + changes (CI / local builds).
- `-b` — binary only.
- `-nc` — no clean before build; `dh_auto_clean` runs anyway via the
  rules, but skipping the top-level clean avoids re-pulling
  `third_party/llama.cpp`.

Output lands in the parent directory:

```
../postgresql-16-maludb-core_0.71.0-1_amd64.deb
../postgresql-17-maludb-core_0.71.0-1_amd64.deb
../postgresql-18-maludb-core_0.71.0-1_amd64.deb
../maludb-mc2dbd_0.71.0-1_amd64.deb
../maludb_0.71.0-1_amd64.changes
../maludb_0.71.0-1_amd64.buildinfo
```

The `-dbgsym` debug-symbol packages (.ddeb) are produced too if
`dh_strip` ran; they're useful when investigating crashes but
optional.

## Install

```bash
sudo dpkg -i ../postgresql-17-maludb-core_*.deb ../maludb-mc2dbd_*.deb
sudo apt-get -f install   # pull dependencies if any are missing
```

The `maludb-mc2dbd` package's `postinst` creates the `maludb-mc2dbd`
system user and group. The systemd unit (`/lib/systemd/system/
maludb-mc2dbd.service`) is *not* enabled or started — operators do
so after configuring `/etc/maludb/maludb-mc2dbd.conf`.

## What the rules do

[debian/rules](../debian/rules):

1. `override_dh_auto_build` — runs the top-level PGXS Makefile
   targeting PG 17, then builds `mc2dbd/` (the listener).
2. `override_dh_auto_install` — installs both into a shared
   `debian/tmp/` staging directory. `dh_install` then routes paths
   into each binary package using
   `debian/postgresql-17-maludb-core.install` and
   `debian/maludb-mc2dbd.install`. Helper scripts
   (`maludb-validate`, `maludb-gpu-check`,
   `maludb-model-runtime-check`) land under
   `/usr/share/maludb/scripts/` in the listener package.
3. `override_dh_installsystemd` — rewrites the source systemd unit's
   path + user/group to match the Debian convention
   (`/usr/sbin/maludb_mc2dbd`, `maludb-mc2dbd` user with a
   per-binary group) and installs it for the `maludb-mc2dbd` package
   only. The upstream unit in `mc2dbd/systemd/` stays untouched so
   the source-clone bootstrap path keeps working.
4. `override_dh_auto_test` — explicitly skipped. pg_regress requires
   a live PG cluster; operators run `make installcheck` after
   installing the packages.

## Multi-version support

`debian/pgversions` lists the PG majors to build for (currently
`16 17 18`). `debian/rules`'s `override_dh_auto_build` and
`override_dh_auto_install` loop over the list, invoking the PGXS
Makefile once per version with the correct `PG_CONFIG`. The
artifacts land under `/usr/lib/postgresql/N/lib/` and
`/usr/share/postgresql/N/extension/` and are routed into the
matching `postgresql-N-maludb-core` package by per-version
`debian/postgresql-N-maludb-core.install` files.

To narrow the build to a single PG version (e.g., a constrained
operator who only runs PG 17), edit `debian/pgversions` before
running `dpkg-buildpackage`. Build-deps include
`postgresql-server-dev-{16,17,18}`; runtime-deps in each per-version
`Depends:` stanza pin the matching pgvector/pgaudit/partman build.

## Acceptance after install

```bash
sudo -u postgres createdb acc
sudo -u postgres psql -d acc -c "CREATE EXTENSION maludb_core CASCADE"
sudo -u postgres psql -d acc -c "SELECT maludb_core.maludb_core_version()"
# expected: 0.71.0
```

Then run a full regression in the source tree against the installed
extension to confirm nothing slipped:

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
# expected: All 74 tests passed.
```

## Known issues

- The two PGDG dependency packages (`postgresql-17-pgaudit`,
  `postgresql-17-partman`) are declared as `Depends:` on
  `postgresql-17-maludb-core` even though only pgvector is strictly
  required for the extension to load. The other two are required at
  *runtime* for the doctrine guarantees (audit + partitioning) to
  hold. Operators that don't want them must remove the dep
  explicitly.
- `lintian` warnings exist for the source tree's mixed C/SQL
  layout. They don't block the build but the package isn't lintian-
  clean enough for an apt repo upload; that's a Stage 7-final
  cleanup task.
