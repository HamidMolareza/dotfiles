# Agent Helpers

This directory is the git-backed source of truth for agent-specific helpers.

Layout:

- `AGENTS.md`: shared default instructions linked into agent homes.
- `prompts/<agent>/`: prompts exposed only to that agent.
- `skills/shared/`: skills that can be linked into multiple agents.
- `skills/<agent>/`: skills exposed only to that agent.

Current convention:

- Codex receives links from `prompts/codex`, `skills/shared`, and `skills/codex`.
- GapCode receives links from `prompts/gapcode`, `skills/shared`, and `skills/gapcode`.
- `gapcodex` is treated as a Codex profile, not a separate agent home.
- Codex built-in skills under `~/.codex/skills/.system` are left untouched.
- `skills/context7` is reserved for Context7 skills you choose to curate under git after installation.
- Third-party installers should be treated as staging tools; move curated skills here and link them back out.
