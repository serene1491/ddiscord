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
    intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
    prefix: "!"
));
```

The most important `ClientConfig` fields are:

- `token`: required for real startup
- `intents`: gateway intents
- `prefix`: used for prefix command parsing
- `pluginsDir`: folder scanned for file-based Lua plugins
- `ownerId`: used by `@RequireOwner`; if owner-only commands are registered and this is unset, startup logs a warning and those commands deny every invoker until you configure an owner ID
- `autoSyncCommands`: keeps slash commands in sync during startup
- `logLevel`: optional minimum log level, defaults to `Information`

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

## Logging

The client now creates a console logger by default. Without extra setup you get:

- startup and sync information
- plugin activation and lifecycle failures
- command failures
- gateway disconnect errors

Successful command timing logs are still available at `Debug` level.

This makes it much easier to tell whether a bot is failing before `READY`, failing policy checks, or failing inside the handler itself.

## Registration

`registerAllCommands!` is the recommended public entrypoint:

```d
client.registerAllCommands!(ping, AdminCommands, CounterPlugin);
```

It accepts:

- free command handlers
- stateful command groups
- Lua plugin descriptor types

## Events

Register handlers with `on!EventType`:

```d
client.on!ReadyEvent((event) {
    import std.stdio : writeln;
    writeln("Ready as ", event.selfUser.username);
});
```

Useful events include:

- `ReadyEvent`
- `ResumedEvent`
- `MessageCreateEvent`
- `InteractionCreateEvent`
- `CommandExecutedEvent`
- `CommandFailedEvent`

## Presence

```d
client.setPresence(
    StatusType.Online,
    Activity(ActivityType.Playing, "with D")
);
```

This updates both local state and the live gateway session.
