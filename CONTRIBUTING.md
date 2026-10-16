# Contributing to MaluDB

Thanks for your interest in MaluDB. This document covers how to send a
patch in a way that lands cleanly.

## Developer Certificate of Origin (DCO)

Every commit must be signed off under the [Developer Certificate of
Origin 1.1](https://developercertificate.org/). Sign-off asserts that
you wrote the change (or have the right to submit it under the project
license).

Add a sign-off line by committing with `-s`:

```
git commit -s -m "fix: do the thing"
```

The trailer must read exactly:

```
Signed-off-by: Your Name <your.email@example.com>
```

Pull requests without DCO sign-off on every commit will not be merged.

## Commit messages

- Subject line in the imperative mood: "add", "fix", "refactor",
  "remove" — not "added" / "adding".
- Keep the subject under ~70 characters.
- The body explains *why*, not *what*. The diff already shows what.
- When implementing a specific requirement, reference its section
  number in `requirements.md` (e.g. "see §S4-3").

## Branch naming

- `phase-N/<topic>` — roadmap work tied to a stage in `requirements.md` §9
- `fix/<topic>` — bug fixes
- `spike/<topic>` — exploration / proof-of-concept

## Before you open a PR

1. `make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config`
   passes (74/74 pg_regress on PG 17).
2. For driver / service changes, the corresponding smoke suite passes
   (see the suite tallies in `README.md`).
3. New behaviour has a `pg_regress` test under `sql/` and `expected/`,
   or a smoke test in the relevant service / driver tree.
4. `requirements.md` and `docs/` reflect any user-visible change.

## Reporting bugs

Use [GitHub Issues](https://github.com/edward-honour/maludb-core/issues)
with the bug-report template. Security-sensitive reports follow
`SECURITY.md` instead — please do not open a public issue for those.

## Code of conduct

Participation in this project is governed by `CODE_OF_CONDUCT.md`.
