# Commands Guide

`ddiscord` uses UDAs as the primary command API.

## Prefix command

```d
@Command("ping", description: "Reply with Pong", routes: CommandRoute.Prefix)
void ping(CommandContext ctx)
{
    ctx.reply("Pong!").await();
}
```

## Slash command

```d
@Command("info", description: "Show info", routes: CommandRoute.Slash)
void info(CommandContext ctx, Nullable!User target = Nullable!User.init)
{
    auto user = target.isNull ? ctx.user : target.get;
    ctx.reply(user.username, ephemeral: true).await();
}
```

## Hybrid command

```d
@HybridCommand("roll", "Roll a dice")
void roll(CommandContext ctx, long sides = 6)
{
    ctx.reply("Rolling d" ~ sides.to!string).await();
}
```

## Policies

Policies stay next to the handler:

```d
@Command("secure", routes: CommandRoute.Prefix)
@RequireOwner
void secure(CommandContext ctx)
{
    ctx.reply("owner only").await();
}
```

`@RequirePermissions(...)` works for slash commands directly from the interaction payload and, for prefix commands, the client now resolves permissions from guild, member, role, and channel overwrite data when needed.

`@RequireOwner` checks `ClientConfig.ownerId`. If owner-only commands are registered without an owner ID, startup logs a warning and those commands deny every invoker until `ownerId` is configured.

If you need the same logic outside the command UDA path, use the public helpers from [Permissions Guide](permissions.md).

```d
@Command("dashboard", routes: CommandRoute.Prefix)
@RateLimit(1, dur!"seconds"(30), bucket: RateLimitBucket.User)
void dashboard(CommandContext ctx)
{
    ctx.reply("cooldown active").await();
}
```

## Registration

Free functions:

```d
client.registerAllCommands!(ping, info, roll);
```

Stateful groups:

```d
@Stateful
struct AdminCommands
{
    @Command("reload", routes: CommandRoute.Prefix)
    void reload(CommandContext ctx)
    {
        ctx.reply("reloaded").await();
    }
}

client.registerAllCommands!AdminCommands();
```

If you want explicit registration paths, `registerCommands!`, `registerCommandGroup!`, and `registerPlugin!` still exist. `registerAllCommands!` is the recommended convenience API because it accepts handlers, command groups, and Lua plugin descriptor types in one place.

## What `CommandContext` gives you

- `ctx.reply(...)`
- `ctx.defer(...)`
- `ctx.followup(...)`
- `ctx.editOriginal(...)`
- `ctx.user`
- `ctx.channel`
- `ctx.cache`
- `ctx.state`
- `ctx.services`

If the command came from an interaction, `reply` sends the initial interaction response. After `defer()`, use `followup()` or `editOriginal()`.
