# maludb_skills

First-party [Claude Agent Skill](https://agentskills.io) bundles for working
with MaluDB. Each subdirectory is one skill bundle — a `SKILL.md` (YAML
frontmatter + markdown instructions) plus optional `scripts/`, `references/`,
and `assets/`.

These are the same SKILL.md bundles MaluDB itself stores and distributes (see
[`docs/agent-skills.md`](../docs/agent-skills.md)): a bundle can be pushed into
a `maludb_core` database with `maludb_skill_register`, discovered with
`maludb_skill_search`, and pulled back with `maludb_skill_get`. The
[`using-maludb-skills`](using-maludb-skills/SKILL.md) skill below documents that
load → find → query lifecycle.

## Skills

| Skill | What it covers |
|---|---|
| [using-maludb-skills](using-maludb-skills/SKILL.md) | How to load a skill into a MaluDB database, how it becomes findable, and how to query and pull it back so it can be used. |
