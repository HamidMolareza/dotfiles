# Command Prompt Patterns

Use these patterns as starting points. Adapt them to the user's command instead of copying them blindly.

## Naming

- Use lowercase kebab-case.
- Keep names short and action-oriented.
- Match the filename to the command name exactly.
- Prefer names that describe the outcome, not the implementation.

## Template: No Arguments

```md
Describe the current workspace status for the requested purpose.

Instructions:
1. Inspect the current working directory.
2. Identify the most relevant files or components.
3. Return the requested output in a concise, practical format.
4. Call out risks, gaps, or recommended next steps when helpful.
```

## Template: Target Argument

```md
Analyze the given target and report the most useful findings.

Arguments:
- First arg: `$1`
- Full args: `$ARGUMENTS`

Instructions:
1. If `$1` is empty, explain what argument is required.
2. Treat `$1` as the target path, file, identifier, or topic.
3. Use `$ARGUMENTS` only if extra free-form context changes the analysis.
4. Return a concise result focused on the user's likely next action.

If the target does not exist, say so clearly and suggest the closest useful next step.
```

## Template: Structured Output

```md
Produce a repeatable review of the requested subject.

Arguments:
- Full args: `$ARGUMENTS`

Instructions:
1. Use `$ARGUMENTS` as the review target or review criteria.
2. Inspect the most relevant local context before answering.
3. Keep the response concise and practical.

Return:
- Summary
- Key findings
- Risks
- Recommended next steps
```

## Prompt Writing Checklist

- Start with the job to be done.
- Define arguments only if they are truly needed.
- Prefer numbered instructions over long prose.
- Specify the output shape only when consistency matters.
- Make failure and empty-input behavior explicit.
- Avoid duplicating global policies, coding standards, or tool descriptions.
