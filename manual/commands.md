# Commands Guide

`ddiscord` uses UDAs as the primary command API.

## Prefix command

```d
@PrefixCommand("ping", "Reply with Pong")
void ping(PrefixContext ctx)
{
    ctx.reply("Pong!").await();
}
```

## Slash command

```d
@SlashCommand("info", "Show info")
void info(SlashContext ctx, Nullable!User target = Nullable!User.init)
{
    auto user = target.isNull ? ctx.user : target.get;
    ctx.reply(user.username, ephemeral: true).await();
}
```

## Hybrid command

```d
@HybridCommand("roll", "Roll a dice")
void roll(HybridContext ctx, long sides = 6)
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

`@RequirePermissions(...)` works for slash commands directly from the interaction payload and, for prefix commands, the client resolves permissions from guild, member, role, and channel overwrite data when needed.

Compatibility aliases are also available:

- `@RequirePermission(...)` as singular alias of `@RequirePermissions(...)`
- `@CooldownRate(...)` as alias of `@RateLimit(...)`

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

Additional UDA policies are also available:

- `@GuildOnly` for server-only commands
- `@DirectMessageOnly` for DM-only commands
- `@UseMiddleware("name")` for named middleware hooks

## Install targets and interaction contexts

Discord application commands also support:

- install targets (`integration_types`)
- interaction contexts (`contexts`)

You can configure both directly with UDAs:

```d
@SlashCommand("profile", "Inspect profile")
@CommandInstallTypes(
    ApplicationIntegrationType.GuildInstall,
    ApplicationIntegrationType.UserInstall
)
@CommandContexts(
    InteractionContextType.Guild,
    InteractionContextType.PrivateChannel
)
void profile(CommandContext ctx)
{
    ctx.reply("profile").await();
}
```

Convenience UDAs:

- install targets: `@GuildInstalled`, `@UserInstalled`
- contexts: `@GuildContextOnly`, `@BotDmOnly`, `@PrivateChannelOnly`
- context combo: `@DmContextOnly`
- install/context combos: `@UserInstalledDmOnly`, `@UserInstalledPrivateOnly`, `@GuildInstalledGuildOnly`, `@UserInstalledEverywhere`
- install combo: `@InstalledEverywhere`

Example:

```d
@SlashCommand("inbox", "Open personal inbox")
@UserInstalledDmOnly
void inbox(SlashContext ctx)
{
    ctx.reply("inbox ready", ephemeral: true).await();
}
```

## Context types by route

Use typed context aliases to keep handler signatures explicit:

- `CommandContext`: route-agnostic handlers (`@Command`)
- `PrefixContext`: prefix-only (`@PrefixCommand`)
- `SlashContext`: slash-only (`@SlashCommand`)
- `HybridContext`: prefix/slash (`@HybridCommand`)
- `ContextMenuContext`: message/user context menu

`ddiscord` validates route/context mismatches during registration (for example, `SlashContext` on a hybrid route).
For explicit route UDAs, typing is strict:
`@PrefixCommand` -> `PrefixContext`, `@SlashCommand` -> `SlashContext`, `@HybridCommand` -> `HybridContext`.

Route-specific fluent helpers are available:

- `PrefixContext.respond(...)` and `PrefixContext.replyToSource(...)`
- `SlashContext.respond(...)`, `SlashContext.respondEphemeral(...)`, `SlashContext.deferEphemeral(...)`, `SlashContext.thinkEphemeral(...)`
- `HybridContext.respond(...)` with optional `ephemeralOnSlash` behavior

Safety guardrail: `ephemeral: true` fails fast on non-interaction routes (prefix).

## Typed autocomplete

Attach autocomplete handlers directly with `@Autocomplete`:

```d
AutocompleteChoice[] searchSongs(string partial, CommandContext ctx)
{
    auto _ = ctx;
    return [
        AutocompleteChoice("Song " ~ partial, partial ~ "-1"),
        AutocompleteChoice("Song " ~ partial ~ " 2", partial ~ "-2")
    ];
}

@SlashCommand("play", "Play a song")
@Autocomplete!searchSongs("song")
void play(SlashContext ctx, string song)
{
    auto _ = ctx;
    auto __ = song;
}
```

Supported autocomplete handler signatures:

- `AutocompleteChoice[] handler(string partial)`
- `AutocompleteChoice[] handler(string partial, CommandContext ctx)`
- `AutocompleteChoice[] handler(AutocompleteContext ctx)`
- `AutocompleteChoice[] handler(AutocompleteContext ctx, CommandContext command)`
- same signatures returning `void`, using `AutocompleteContext.respond(...)`

If a slash command has only one non-context parameter, `@Autocomplete!handler` can omit the option name.

When no explicit command context UDA is provided, `@GuildOnly` and `@DirectMessageOnly`
are projected to Discord `contexts` automatically for slash/context-menu sync:

- `@GuildOnly` -> `contexts = [Guild]`
- `@DirectMessageOnly` -> `contexts = [BotDM, PrivateChannel]`

Example:

```d
@Command("cleanup", routes: CommandRoute.Prefix)
@GuildOnly
@UseMiddleware("owner_only")
void cleanup(CommandContext ctx)
{
    ctx.reply("cleanup started").await();
}
```

Register named and global middleware in the client:

```d
client.registerMiddleware("must-be-guild", guildOnlyMiddleware());
client.useMiddleware((CommandContext ctx) {
    return Result!(bool, string).ok(true); // allow
});
```

## Registration

Free functions:

```d
client.registerAllCommands();
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

If you want explicit registration paths, `registerCommands!`, `registerCommandGroup!`, and `registerPlugin!` still exist. `registerAllCommands!` is useful when you want a specific compile-time registration list.

## What `CommandContext` gives you

- `ctx.reply(...)`
- `ctx.defer(...)`
- `ctx.followup(...)`
- `ctx.edit(...)`
- `ctx.showModal(...)`
- `ctx.sendFile(...)`
- `ctx.followupFile(...)`
- `ctx.editFile(...)`
- `ctx.messageRef` (bound message helper with `react`, `unreact`, `pin`, `unpin`, `crosspost`, `edit`, `deleteMessage`)
- `ctx.react(...)`
- `ctx.unreact(...)`
- `ctx.pin(...)`
- `ctx.unpin(...)`
- `ctx.crosspost(...)`
- `ctx.editMessage(...)`
- `ctx.deleteMessage(...)`
- `ctx.user`
- `ctx.channel`
- `ctx.cache`
- `ctx.state`
- `ctx.services`

If the command came from an interaction, `reply` sends the initial interaction response. After `defer()`, use `followup()` or `edit()`.

Slash and context-menu commands can also open a modal:

```d
@Command("report", routes: CommandRoute.Slash)
void report(CommandContext ctx)
{
    auto modal = Modal("bug_report", "Bug Report")
        .addTextInput(TextInput("summary", "Summary"))
        .addTextInput(TextInput("details", "Details", TextInputStyle.Paragraph));

    ctx.showModal(modal).await();
}
```
