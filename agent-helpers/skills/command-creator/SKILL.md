---
name: command-creator
description: Create or update Codex CLI custom commands stored as markdown prompt files in `${CODEX_HOME:-$HOME/.codex}/prompts/command-name.md`. Use when Codex needs to design a reusable command, define how `$1` and `$ARGUMENTS` should be handled, or apply best practices for concise prompt structure, scope, guardrails, and output format.
---

# Command Creator

Create or update one reusable Codex CLI command prompt file. Keep the command narrowly scoped, practical, and easy to invoke repeatedly.

## Workflow

1. Determine the command's job, expected inputs, and desired output.
2. Normalize the command name to lowercase kebab-case and use it as the filename without a leading slash.
3. Create or update `${CODEX_HOME:-$HOME/.codex}/prompts/<command-name>.md`.
4. Write a concise markdown prompt that tells Codex exactly how the command should behave.
5. Verify that the command handles missing inputs and edge cases clearly.

## Prompt Structure

Use the lightest structure that fits the command.

- Start with a one-line purpose statement.
- Add an `Arguments:` section only when the command accepts user input.
- Add an `Instructions:` section with numbered, imperative steps.
- Add a `Return:` section when the output shape must stay consistent.
- Add explicit fallback behavior when files, paths, or arguments are missing.

## Arguments Guidance

Use the built-in placeholders only when they help.

- Use `$1` for the primary positional argument.
- Use `$ARGUMENTS` for the full raw argument string.
- Mention both when the command benefits from a single primary target and full free-form text.
- Omit the `Arguments:` section entirely when the command always works from the current workspace context.

## Best Practices

- Keep one command focused on one repeatable job.
- Prefer clear verbs such as `summarize-project`, `review-diff`, or `draft-release-notes`.
- Make the output contract explicit when users will reuse the command often.
- Write concise instructions; do not restate general system behavior or broad coding rules unless the command truly overrides them.
- Prefer relative or environment-based paths over hardcoded machine-specific paths.
- State how to behave when the target does not exist, arguments are empty, or context is ambiguous.
- Add safety guardrails for destructive or high-impact actions.
- Preserve existing behavior when updating an existing command unless the user asked for a redesign.

## Quality Checks

Before finishing, confirm all of the following:

- The file path is `${CODEX_HOME:-$HOME/.codex}/prompts/<command-name>.md`.
- The filename exactly matches the normalized command name.
- The prompt is short enough to scan quickly.
- The instructions are specific enough that another Codex instance can follow them without extra explanation.
- The command's behavior for missing inputs is explicit.

## Reference

Read `references/command-patterns.md` when you need ready-to-adapt templates, naming guidance, or examples.
