# Client Guide

`Client` is the runtime hub of the library. It owns:

- the REST surface
- the gateway session
- the command registry
- the event dispatcher
- state, cache, services, tasks, plugins, and scripting

## Building a client

```d
auto client = new Client(ClientConfig(
    token: env.require!string("TOKEN"),
    intents: cast(uint) GatewayIntent.GuildTextCommands,
    prefix: "!"
));
```

The most important `ClientConfig` fields are:

- `token`: required for real startup
- `intents`: gateway intents
- `prefix`: used for prefix command parsing
- `pluginsDir`: folder scanned for file-based Lua plugins
- `allowLoosePlugins`: allows standalone `.lua` files without a manifest (`true` by default)
- `allowPluginEntrypointEscape`: allows manifest entrypoints outside the plugin directory (`false` by default)
- `requireExplicitPluginPermissions`: disables implicit host permissions for untrusted plugins without a `permissions` list (`false` by default)
- `ownerId`: used by `@RequireOwner`; if owner-only commands are registered and this is unset, startup logs a warning and those commands deny every invoker until you configure an owner ID
- `autoSyncCommands`: keeps slash commands in sync during startup
- `logLevel`: optional minimum log level, defaults to `Information`
- `logUnhandledGatewayDispatchEvents`: emits sampled logs for dispatch events that still have no typed handler (`false` by default)
- `gatewayUnhandledDispatchLogEvery`: sampling interval for repeated unhandled dispatch logs (`100` by default, `0` behaves like `1`)
- `maxDispatchQueueSize`: upper bound for pending gateway dispatch work (default `4096`, `0` = unbounded)
- `dropOldestDispatchOnOverflow`: when queue pressure is high, keep latest events by dropping oldest pending items (`true` by default)
- `dispatchOverflowLogEvery`: overflow warning cadence (`100` by default, `0` disables warning logs)

Common intent presets:

- `GatewayIntent.GuildTextCommands`: guild text command bots
- `GatewayIntent.GuildTextCommandsWithReactions`: guild text + reactions
- `GatewayIntent.DirectTextCommands`: DM command bots
- `GatewayIntent.DefaultCommandBot`: guild + DM command flows
- `GatewayIntent.NonPrivileged`: all currently surfaced non-privileged intents

## Runtime lifecycle

`run()` does real startup work:

1. calls `/users/@me`
2. calls `/gateway/bot`
3. loads plugins from `pluginsDir`
4. activates Lua plugins
5. syncs application commands when enabled
6. starts the gateway thread
7. starts the dispatch and task loops

Use `wait()` to keep the process running and `stop()` to shut it down cleanly.

## Production Backpressure

`Client` now has bounded dispatch queue controls so long traffic spikes do not grow memory
without limits.

```d
auto client = new Client(ClientConfig(
    token: env.require!string("TOKEN"),
    intents: cast(uint) GatewayIntent.NonPrivileged,
    maxDispatchQueueSize: 8192,
    dropOldestDispatchOnOverflow: true,
    dispatchOverflowLogEvery: 50
));
```

You can inspect queue pressure at runtime:

```d
auto health = client.dispatchQueueHealth;
// health.queued
// health.peakQueued
// health.maxQueued
// health.droppedTotal
```

This keeps bots responsive under bursts while still exposing enough telemetry to tune limits.

## Uptime

`client.uptime` now tracks real process uptime instead of a placeholder value.

```d
import std.stdio : writeln;

writeln("uptime: ", client.uptime.toString());
writeln("uptime ms: ", client.uptime.milliseconds);
```

## Logging

The client now creates a console logger by default. Without extra setup you get:

- startup and sync information
- plugin activation and lifecycle failures
- command failures
- gateway disconnect errors

Successful command timing logs are still available at `Debug` level.

This makes it much easier to tell whether a bot is failing before `READY`, failing policy checks, or failing inside the handler itself.

## Registration

The shortest entrypoints now auto-scan the calling module:

```d
client.registerCommands();
client.registerAllCommands();
```

- `registerCommands()` registers only command handlers from the current module
- `registerAllCommands()` also includes `@Event` handlers, stateful command groups, and plugin descriptor types

Explicit template registration still works:

```d
client.registerAllCommands!(ping, onReady, AdminCommands, CounterPlugin);
```

Automatic registration accepts filters when you want something between “everything here” and
fully manual registration:

```d
auto filter = CommandRegistrationFilter
    .owners("AdminCommands")
    .exceptNames("debug")
    .exceptCategories("Internal");

client.registerAllCommands(filter);
```

Available filter targets include:

- source module names
- owner/group type names
- command names
- `@CommandCategory` values
- whether free functions, types, events, or plugins should be considered

## Events

Register handlers with `on!EventType`:

```d
client.on!ReadyEvent((event) {
    import std.stdio : writeln;
    writeln("Ready as ", event.selfUser.username);
});
```

Or declare them with `@Event` and let `registerAllCommands!` wire them:

```d
@Event
void onReady(ReadyEventContext ctx)
{
    import std.stdio : writeln;
    writeln("Ready as ", ctx.selfUser.username);
}
```

`@Event` is the UDA form of event registration. It is useful when you want command handlers and
event handlers to live under the same `registerAllCommands!` flow, including stateful groups.
Handlers may accept either the raw event struct or the matching context type.

Useful events include:

- `ReadyEvent`
- `ResumedEvent`
- `MessageCreateEvent`
- `InteractionCreateEvent`
- `GuildMemberAddEvent`
- `PresenceUpdateEvent`
- `AutocompleteInteractionEvent`
- `MessageComponentEvent`
- `ModalSubmitEvent`
- `CommandExecutedEvent`
- `CommandFailedEvent`

`ReadyEvent` now also includes `gatewayVersion`, the placeholder guild list carried by the initial `READY`, and `resumeGatewayUrl`.
Each shipped event now also carries a typed `context` field with cached/current entities and
runtime services for fluent follow-up work.

For example:

- `MessageCreateEventContext` carries `message`, `user`, `guild`, `member`, `channel`, plus `cache`, `state`, `services`, `rest`, and `logger`
- `InteractionCreateEventContext` carries `interaction` and the same shared runtime surface
- `CommandExecutedEventContext` and `CommandFailedEventContext` also expose the originating command context and route-aware helpers such as `prefix`, `slash`, `contextMenu`, and `hybrid`

## Built-in help

The client registers a built-in `help` command by default unless you already provide your own
command with the same name on prefix or slash routes.

Its defaults are meant to be useful immediately:

- paginated output
- embeds or Components V2 rendering
- case-insensitive query matching
- visibility checks against owner-only and permission-gated commands
- support for `@CommandCategory` and `@HideFromHelp`

Customize it through `client.helpBehavior`:

```d
client.helpBehavior.pageSize = 4;
client.helpBehavior.useComponentsV2 = true;
client.helpBehavior.includeCommand = (descriptor) => descriptor.category != "Internal";
client.helpBehavior.buildEntry = (descriptor, usage) {
    CommandHelpEntry entry;
    entry.name = descriptor.displayName;
    entry.description = descriptor.description;
    entry.usage = usage;
    entry.category = descriptor.category;
    return entry;
};
```

## Command errors

Prefix and interaction failures can now be surfaced back to the caller by default instead of only
showing up in logs.

The default renderer keeps user-facing output concise (summary + short actionable hint) while full
failure details remain in bot logs.

The built-in behavior can report:

- unknown commands
- missing command names
- missing or invalid arguments
- handler failures
- other library-side command execution failures

Control it through `client.errorBehavior`:

```d
client.errorBehavior.surfaceUnknownCommand = false;
client.errorBehavior.surfaceArgumentErrors = true;
client.errorBehavior.shouldSurface = (error) => error.commandName != "eval";
client.errorBehavior.render = (error) {
    return MessageCreate("command error: " ~ error.error);
};
```

## Presence

```d
client.setPresence(
    StatusType.Online,
    Activity(ActivityType.Playing, "with D")
);
```

This updates both local state and the live gateway session.

## REST helpers

The `Client` exposes the common REST groups directly, so normal usage does not need
`client.rest`:

```d
auto me = client.users.me().await();

ModifyCurrentApplication update;
update.description = Nullable!string.of("New bot description");
client.apps.update(update).await();
```

Useful additions include:

- `client.users.update(...)` for `PATCH /users/@me`
- `client.apps.me()` / `client.apps.current()` and `client.apps.update(...)`
- `client.channels.typing(channelId)`
- `client.messages.create(...)`
- `client.slash.sync(...)` when you want direct command-manifest sync

## Sending and thinking helpers

`CommandContext` now has three helpers for common UX flows:

```d
ctx.think().await();
ctx.send("Done.").await();
ctx.reply("Working on it...", true).await();
```

- `think()` defers interaction commands and triggers channel typing for prefix/message commands
- `send(...)` sends the normal response for the current context and automatically switches to
  interaction follow-up messages when the interaction was already acknowledged
- `reply(...)` sends a native Discord reply when the context came from a message

The command layer now also exposes route-specific context shapes when you want tighter typing:

- `PrefixCommandContext`
- `SlashCommandContext`
- `ContextMenuCommandContext`
- `HybridCommandContext`

You can also annotate commands for the default help system:

- `@CommandCategory("Utility")` to group/filter commands
- `@HideFromHelp` to keep a command registered but absent from built-in help
