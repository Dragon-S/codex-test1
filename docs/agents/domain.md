# Domain Docs

## Before exploring, read these

- `CONTEXT.md` at the repository root.
- `CONTEXT-MAP.md` if it exists.
- Relevant ADRs under `docs/adr/`.

If these files do not exist, proceed silently. Domain-modeling skills create them lazily when terminology or decisions are resolved.

## File structure

This repository uses a single-context layout:

```
/
├── CONTEXT.md
├── docs/adr/
└── src/
```

## Use the glossary's vocabulary

Use terms defined in `CONTEXT.md` when naming domain concepts. Avoid synonyms that the glossary explicitly rejects.

If a needed concept is absent, reconsider whether the term belongs or note the gap for `/domain-modeling`.

## Flag ADR conflicts

Explicitly identify output that conflicts with an existing ADR instead of silently overriding it.
