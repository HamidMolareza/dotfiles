# codex-auth

`codex-auth` switches the active Codex auth file in `~/.codex` and shows quota,
email, and account metadata for each candidate.

## Quota And Reset Counts

For each uncached account, the picker sends one read-only request to the existing
Codex usage endpoint. The `Resets` column is populated from
`rate_limit_reset_credits.available_count` in that same response; the separate
reset-credit details endpoint is not requested.

Quota data and the reset count share the same five-minute cache. Cache schema
version 2 forces a one-time refresh of older entries that do not contain the
reset count. A missing or invalid count is rendered as an empty cell, while a
stale fallback value is marked with `*` like the existing quota columns.

## Sort Priority

The picker sorts accounts in this order:

1. Accounts whose metadata says they are expired, but whose quota was confirmed
   by the server. These are treated as active because the server response is the
   source of truth.
2. Accounts with a complete, non-expired account expiration date
   (`purchased_on + valid_for_days`), nearest expiration first.
3. Accounts without a complete expiration date, ordered by quota reset urgency.
4. Accounts whose metadata says they are expired and whose quota was not
   confirmed by the server. These are shown last and rendered in a neutral gray.

Within each group, quota urgency is sorted by:

1. Nearest 7d reset.
2. Nearest 5h reset.
3. Lower remaining 7d percentage.
4. Lower remaining 5h percentage.
5. File order: active `auth.json`, then `auth.json<number>` ascending.

Fresh cached quota with usable quota data counts as server-confirmed. Stale
fallback quota marked with `*` does not, because it may no longer reflect the
current server state.
