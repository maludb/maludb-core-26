# MIST end-to-end test — runnable scripts

These are the exact, **executed-live** scripts behind [`../../end-to-end.md`](../../end-to-end.md)
(the "MIST" project walkthrough). Verified against `maludb_core` **0.86.1** on
PostgreSQL 17, 2026-05-31.

## Files

| File | What it does |
|------|--------------|
| `00-bootstrap-0.86.1.sh` | **Obsolete for ≥ 0.92.0** (its delta list stops at 0.86.1) — on a current install just `CREATE DATABASE` + `CREATE EXTENSION maludb_core CASCADE`. Historical: drops/creates the `mist_e2e` database, `CREATE EXTENSION maludb_core CASCADE`, then applies the repo's delta scripts up to 0.86.1. |
| `01-part1.sql` | Part I — project + first-day team (subjects, verbs, role statements with edge-attribute titles, project attributes, kickoff episode) and the Q1–Q7 query gauntlet. |
| `02-part2.sql` | Part II — sprints/tasks as episodes, `part_of` hierarchy, a review meeting + generated document, staffing changes (Joe leaves / Priya joins via valid-time), HR reference attribute, and the temporal re-gauntlet Q8–Q12. |

## Run

```bash
# 1. (only if needed) bring the extension up to 0.86.1 in a throwaway DB
bash 00-bootstrap-0.86.1.sh

# 2. load + query Part I, then Part II
psql -d mist_e2e -f 01-part1.sql
psql -d mist_e2e -f 02-part2.sql
```

If your server already advertises 0.86.1, skip step 1 and just
`CREATE DATABASE mist_e2e; psql -d mist_e2e -c 'CREATE EXTENSION maludb_core CASCADE;'`
before running the two SQL files.

## Notes / gotchas these scripts encode

- Subjects/verbs are written by inserting into the `maludb_subject` / `maludb_verb`
  **views**; use a *bare* `ON CONFLICT DO NOTHING` (the views don't expose
  `owner_schema`, so a column-targeted conflict clause fails).
- The document write facade is **`maludb_upload_document`** (not
  `maludb_register_document`).
- `part_of` and `assigned` are seeded verb *types*, not seeded *verbs* — the
  scripts register them.

See `end-to-end.md` §10 and §18 for the full findings.
