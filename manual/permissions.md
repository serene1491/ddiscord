# Permissions Guide

`ddiscord` now exposes a public permission calculator so command checks and custom moderation logic can share the same rules.

## What it covers

- base guild permissions from `@everyone` plus member roles
- `Administrator` short-circuit
- channel overwrite application in Discord order
- missing-permission introspection for better errors

## Main helpers

```d
import ddiscord;

auto base = computeBasePermissions(member, guild, roles);
auto effective = computeEffectivePermissions(member, guild, channel, roles);

if (!hasPermission(effective, cast(ulong) Permissions.ManageMessages))
{
    auto missing = missingPermissions(effective, cast(ulong) Permissions.ManageMessages);
    throw new MissingPermissionsException(missing);
}
```

## Prefix commands

For prefix commands using `@RequirePermissions(...)`, the client now resolves permissions from:

1. cached member permissions when available
2. guild member data
3. guild roles
4. channel overwrites

That keeps prefix permission behavior much closer to slash-command behavior.

## When to use this directly

- custom moderation checks
- command preconditions outside the built-in UDA policies
- REST actions that should fail before making the network request
