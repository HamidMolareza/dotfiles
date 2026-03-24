# AGENTS.md — Global Defaults

These conventions apply to all work under this home directory unless a more specific `AGENTS.md` in a subdirectory overrides them.

## Developer Profile

- **OS:** Ubuntu 24.04
- **Shell:** zsh (oh-my-zsh)
- **Primary stack:** .NET (C#), ASP.NET Core, EF Core
- **Editor:** JetBrain IDEs like Rider, VS Code
- **Languages:** Persian (Farsi) is native; English for all code, comments, commits, and documentation. English is the default language unless another language (e.g., Persian) is explicitly requested.

## Language & Locale

- **Default language is English** for all code, variable names, comments, commit messages, and technical documentation.
- Use another language (e.g., Persian) **only when explicitly requested**.
- Personal notes, knowledge base entries, or user-facing content **may be in Persian** if requested.
- Do not translate existing content between languages unless explicitly asked.

## Git Conventions

- Commits are **GPG-signed** — But you can bypass signing.
- Commit messages: **ConventionalCommits** format (e.g., `feat:`, `fix:`, `chore:`, `docs:`) by default.
- Default branch: `main`.
- Pull strategy: merge (not rebase) unless the project specifies otherwise.
- Do **not** commit secrets, tokens, or `.env` files.
- Do **not** commit or push unless explicitly asked.

## C# / .NET Conventions

- **Target frameworks:** Use whatever the project already targets (net8.0, net9.0, net10.0). Do not upgrade without asking.
- **Architecture:** Respect the existing project structure. Prefer Clean Architecture layering when starting new projects.

## Docker Conventions

- Use `docker compose` (V2 syntax), not `docker-compose`.
- Keep secrets in environment variables or `.env` (never committed).
- Include health checks in compose services.

## Package Mirrors (Iran Network)

Due to network restrictions, prefer these mirrors when configuring package sources:

- **pip:** `https://package-mirror.liara.ir/repository/pypi/simple`
- **NuGet:** `https://package-mirror.liara.ir/repository/nuget/index.json` (with `https://api.nuget.org/v3/index.json` as fallback)
- **npm:** If registry is unreachable, try `https://registry.npmmirror.com` as fallback.

## General Coding Principles

- Fix root causes, not symptoms.
- Keep changes minimal and focused — do not refactor unrelated code.
- Respect existing code style in each project; match what's already there.
- Do not add copyright/license headers unless asked.
- Do not add inline comments unless they explain **why**, not **what**.
- Prefer simple, readable solutions over clever ones.

## File & Project Hygiene

- Do not modify files outside the scope of the current task unless explicitly asked.
- Log files (`logs/`), build outputs (`bin/`, `obj/`), `node_modules/`, IDE folders (`.vscode`, `.idea`) are never committed and should added into `.gitignore`.
- When creating new files, use clear, descriptive names. For dated files: `YYYY-MM-DD-short-title.ext`.

## Security

- Never log or expose secrets, tokens, connection strings, or API keys.
- Redact sensitive data in tool/API responses.
- Use environment variables or user-secrets for sensitive configuration.
