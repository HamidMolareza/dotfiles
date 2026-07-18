# Configuration Policy

Tracked configuration is limited to reusable defaults and inactive samples. Local
profiles, absolute paths, manual checklists, collector selections, and restore-handler
registrations are intentionally ignored by Git.

## Tracked files

- `profiles/*.conf.sample`: inactive profile templates with placeholder paths
- `excludes/common.exclude`: generally safe build and cache exclusions
- `excludes/*.sample`: inactive machine-specific exclusion suggestions
- `manual/*.sample`: inactive checklist examples
- `collectors/*.sample`: inactive collector examples
- `docker-recovery/*.sample`: inactive application-layout examples
- `credentials-recovery/*.sample`: inactive credential-group examples
- `codex-mcp-recovery/*.sample`: inactive SQLite classification examples
- `browser-recovery/*.sample`: inactive targeted-browser examples
- `github-recovery/*.sample`: inactive account/cache policy examples
- `server-recovery/*.sample`: inactive SSH/server coverage examples
- `restore/*.sample`: inactive trusted-handler examples
- `retention/default.conf`: reusable default retention policy

## Local files

Create local files from the samples and review every entry before use:

```bash
cp config/profiles/home.conf.sample config/profiles/home.conf
cp config/excludes/local.exclude.sample config/excludes/local.exclude
cp config/manual/home.manual.sample config/manual/home.manual
cp config/collectors/enabled.conf.sample config/collectors/enabled.conf
cp config/docker-recovery/local.conf.sample config/docker-recovery/local.conf
cp config/credentials-recovery/local.conf.sample config/credentials-recovery/local.conf
cp config/codex-mcp-recovery/local.conf.sample config/codex-mcp-recovery/local.conf
cp config/browser-recovery/local.conf.sample config/browser-recovery/local.conf
cp config/github-recovery/local.conf.sample config/github-recovery/local.conf
cp config/server-recovery/local.conf.sample config/server-recovery/local.conf
cp config/restore/handlers.local.conf.sample config/restore/handlers.local.conf
```

Each application recovery file is needed only when its collector or restore handler
is enabled. Samples are intentionally inactive and contain placeholders. Account
names, SSH aliases, absolute helper paths, database paths, extension choices, and
credential selections belong only in ignored `local.conf` files.

Files ending in `.conf`, `.exclude`, or `.manual` in the corresponding local config
directories are ignored unless explicitly declared as a reusable tracked default.
Never put secrets, tokens, passwords, or connection strings in a sample.
