# dDiscord <img src="logo.svg" width="24">

A Discord bot library for D-lang.

> [!NOTE]
`ddiscord` is an early-stage project (pre-`1.0.0`) developed in the open with AI assistance.  
This library is also used in personal projects, so changes may be frequent and occasionally breaking until a stable release.

## Key Features

- UDA-first command API for prefix, slash, and hybrid commands
- Command middleware pipeline with global and named `@UseMiddleware(...)` hooks
- Real Discord REST and gateway connectivity
- Typed events, typed models, and typed command inputs
- Interaction helpers for replies, follow-ups, modals, autocomplete, and deferred responses
- Message-focused command helpers (`ctx.react`, `ctx.pin`, `ctx.crosspost`, `ctx.messageRef`)
- Multipart attachment uploads across message and interaction response flows
- Message lifecycle helpers (create/edit/delete/bulk delete/crosspost/pin flows) and reaction endpoints
- Guild moderation, thread management, and webhook execution REST surfaces
- Components V2 coverage with runnable examples
- State, cache, rate limiting, services, tasks, and Lua/plugin support
- Production-minded runtime controls (dispatch backpressure, error surfacing, and telemetry)
  with built-in queue health and real uptime tracking
- Runtime safety guardrails for large bots (worker-loop crash isolation, stricter REST validation, and configurable retry controls)
- Input hardening for production REST usage (safer token routing, emoji validation, and audit-log reason sanitization)

## Philosophy

`ddiscord` is being built as a production runtime for D bots: typed APIs, explicit failure
handling, bounded backpressure, and modular internals that scale past small toy projects.
More detail is in [`manual/philosophy.md`](manual/philosophy.md).

## Installing

Recommended toolchains:

- DMD `>= 2.106`
- LDC `>= 1.36`
- `liblua5.4` when you want Lua/plugin features

You can install `ddiscord` directly with DUB:

```sh
dub add ddiscord
```

Or add it manually to `dub.json`:

```json
{
  "dependencies": {
    "ddiscord": "~>0.2.0"
  }
}
```

If you want the current development head instead, work from the repository directly:

```sh
git clone https://github.com/soloverdrive/ddiscord.git
cd ddiscord
dub test
```

Runnable example consoles live under [`examples/`](examples/README.md).

## Quick Example

```d
import ddiscord;
import std.path : buildPath;

@Command("ping", description: "Check the bot latency", routes: CommandRoute.Prefix)
void handlePing(CommandContext ctx)
{
    ctx.send("Pong!").await();
}

void main()
{
    auto env = loadEnv(buildPath("examples"));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.GuildTextCommands,
        prefix: "!"
    ));

    client.registerCommands();
    client.run();
    client.wait();
}
```

## More Examples

### Slash command with an ephemeral response

```d
@Command("userinfo", description: "Show information about a user", routes: CommandRoute.Slash)
void handleUserInfo(CommandContext ctx, Nullable!User target = Nullable!User.init)
{
    auto resolved = target.isNull ? ctx.user : target.get;
    ctx.send("User: " ~ resolved.mention, ephemeral: true).await();
}
```

### Native message reply versus normal send

```d
@HybridCommand("hello", "Reply to the caller")
void handleHello(CommandContext ctx)
{
    if (ctx.source == CommandSource.Prefix)
        ctx.reply("Hello there.", mentionAuthor: true).await();
    else
        ctx.send("Hello there.", ephemeral: true).await();
}
```

### Long-running interaction flow

```d
@Command("build", description: "Run a longer task", routes: CommandRoute.Slash)
void handleBuild(CommandContext ctx)
{
    ctx.think(ephemeral: true).await();
    ctx.edit("Finished the build.").await();
}
```

### Opening a modal

```d
@Command("report", description: "Open a report modal", routes: CommandRoute.Slash)
void handleReport(CommandContext ctx)
{
    auto modal = Modal("report_modal", "Report User")
        .addTextInput(TextInput("reason", "Reason"));

    ctx.showModal(modal).await();
}
```

### Event handlers with `@Event`

```d
@Event
void handleReady(ReadyEventContext ctx)
{
    import std.stdio : writeln;
    writeln("Ready as ", ctx.selfUser.username);
}
```

`@Event` handlers can receive either the event itself, such as `ReadyEvent`, or its richer
context type, such as `ReadyEventContext`.

`@Event` is the event-side UDA entrypoint, matching the same registration style used for commands.
Each shipped event has its own context companion so follow-up work stays fluent without
throwing away the smaller payload structs. Those contexts expose `rest`, `cache`, `services`,
`state`, `logger`, and current cached entities like `ctx.user`, `ctx.guild`, `ctx.channel`,
`ctx.message`, or `ctx.interaction` when they are available.

```d
@Event
void auditMessage(MessageCreateEventContext ctx)
{
    import std.stdio : writeln;

    auto guildText = ctx.guild.isNull ? "DM" : ctx.guild.get.name;
    writeln("[", guildText, "] ", ctx.message.content);
}
```

### Hybrid command contexts

```d
@HybridCommand("where", "Show how the command was invoked")
void handleWhere(HybridCommandContext ctx)
{
    if (ctx.fromPrefix)
        ctx.reply("You used the prefix route.").await();
    else
        ctx.send("You used the slash route.", ephemeral: true).await();
}
```

## Auto Registration

The simplest path is module-local registration:

```d
client.registerCommands();
client.registerAllCommands();
```

- `registerCommands()` scans the current module and registers command handlers only
- `registerAllCommands()` scans the current module and also wires `@Event` handlers, stateful command groups, and plugin descriptor types

Both helpers accept filters, so you can keep registration short without giving up control:

```d
auto filter = CommandRegistrationFilter
    .modules("app")
    .exceptNames("debug")
    .exceptCategories("Internal");

client.registerAllCommands(filter);
```

Useful filter targets include module names, owner types, command names, and `@CommandCategory`
values.

## Built-in Help and Error Surfacing

The client ships a built-in `help` command by default. It uses embeds or Components V2,
supports pagination, and can be fully customized by swapping how entries and pages are rendered.

```d
@CommandCategory("Utility")
@HybridCommand("ping", "Check the bot latency")
void handlePing(CommandContext ctx)
{
    ctx.send("Pong!").await();
}

@HideFromHelp
@Command("debug-cache", routes: CommandRoute.Prefix)
void debugCache(CommandContext ctx)
{
    ctx.send("cache ok").await();
}

void main()
{
    auto client = new Client(ClientConfig(token: "...", intents: 0));

    client.registerCommands();
    client.helpBehavior.pageSize = 4;
    client.errorBehavior.surfaceUnknownCommand = true;
    client.errorBehavior.surfaceArgumentErrors = true;
}
```

Out of the box, the client can surface things like unknown commands, missing arguments, invalid
arguments, and handler failures. That behavior is also customizable through `client.errorBehavior`.
For quick profiles, use `CommandErrorBehavior.nonVerbose()` or `CommandErrorBehavior.verbose()`.

## Library Status

| Area | Status | Notes |
| --- | --- | --- |
| REST core | usable | real HTTP transport, command sync, message lifecycle + multipart attachments, reactions, moderation, threads, webhooks, users, apps, and interaction callbacks |
| Gateway | usable | live sessions, heartbeat, resume/reconnect basics, typed dispatch integration |
| Commands | active | prefix, slash, hybrid, permissions, rate limits, and service-backed handlers |
| Components and modals | usable | buttons, selects, modals, and Components V2 builders |
| State, cache, tasks | available | cache store, scoped state, and scheduled tasks are already shipped |
| Lua and plugins | active | file-based plugins, capability-gated host APIs, and runtime sandbox controls |
| Voice / calls | early | surface-level groundwork only |

## Examples

- [`examples/start-bot`](examples/start-bot/source/app.d): minimal env-driven startup
- [`examples/basic-bot`](examples/basic-bot/source/app.d): prefix + slash basics
- [`examples/events-bot`](examples/events-bot/source/app.d): typed event handling in isolation
- [`examples/interactions-bot`](examples/interactions-bot/source/app.d): button + modal interaction flow
- [`examples/services-bot`](examples/services-bot/source/app.d): `@Stateful` groups with injected services
- [`examples/tasks-bot`](examples/tasks-bot/source/app.d): scheduled reminders and recurring task loops
- [`examples/full-bot`](examples/full-bot/source/app.d): state, permissions, rate limits, and components
- [`examples/plugin-bot`](examples/plugin-bot/source/app.d): Lua host APIs and file-based plugins
- [`examples/test-bot`](examples/test-bot/source/app.d): integration-oriented validation bot with startup REST checks
- [`examples/help-bot`](examples/help-bot/source/app.d): built-in help customization and error behavior
- [`examples/filter-bot`](examples/filter-bot/source/app.d): module auto-registration filters in practice
- [`examples/lua-scripting-bot`](examples/lua-scripting-bot/source/app.d): persisted user scripts with SQLite + Dorm
- [`examples/rest-ops-bot`](examples/rest-ops-bot/source/app.d): reactions, moderation, threads, webhooks, and message lifecycle operations

## Documentation

- [`manual/client.md`](manual/client.md) for the runtime/client guide
- [`manual/philosophy.md`](manual/philosophy.md) for project direction and engineering principles
- [`examples/README.md`](examples/README.md) for the runnable consoles
- [`CHANGELOG.md`](CHANGELOG.md) for release notes in progress

## Lua and Plugins Notes

Lua host APIs include:

- state helpers: `state_get`, `state_set`, `state_has`, `state_del`
- plugin-scoped logging helpers: `log_info`, `log_warn`, `log_error`
- plugin context metadata: `plugin_name`, `plugin_version`, `plugin_api_version`, `plugin_entrypoint`, `plugin_sandbox`

For file-based plugins with `sandbox: "untrusted"` and no explicit `permissions`, the default
capability set is intentionally minimal (`context.read`) to reduce accidental overexposure.
Production hardening can be enabled with `ClientConfig` flags:
`requireExplicitPluginPermissions`, `allowLoosePlugins`, and `allowPluginEntrypointEscape`.

## Current API Direction

The public naming is being tightened before `1.0.0`:

- `ctx.send(...)` is the normal response helper
- `ctx.reply(...)` is the native reply helper
- `ctx.edit(...)` edits the original interaction response
- `client.registerCommands()` and `client.registerAllCommands()` scan the current module by default
- `CommandRegistrationFilter` narrows auto-registration by module, owner, name, or category
- built-in `help` is enabled by default and can render through embeds or Components V2
- `@CommandCategory` and `@HideFromHelp` shape the default help output
- `client.errorBehavior` controls how command failures are surfaced back to users
- events have typed context companions such as `ReadyEventContext` and `MessageCreateEventContext`
- gateway-driven `GuildMemberAddEvent` and `PresenceUpdateEvent` are emitted with typed contexts
- `GuildCreateEvent` and `GuildDeleteEvent` are emitted from live gateway dispatches for cache/runtime sync flows
- typed gateway coverage includes channel/message lifecycle, member removal, and typing-start dispatches
- command outcome events expose route-aware helpers like `prefix`, `slash`, `contextMenu`, and `hybrid`
- `@Event` handlers can be wired through `client.registerAllCommands()`
- `ClientConfig.logUnhandledGatewayDispatchEvents` can sample-log unknown dispatch names without typed coverage

That means pre-`1.0.0` consistency wins over keeping older aliases around.
