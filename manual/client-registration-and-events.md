# Registration and Events

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

## Registration

The shortest entrypoints auto-scan the calling module:

```d
client.registerCommands();
client.registerTasks();
client.registerAllCommands();
```

- `registerCommands()` registers only command handlers from the current module
- `registerTasks()` registers only `@Task` handlers from the current module
- `registerAllCommands()` also includes `@Event`, `@Task`, stateful groups, and plugin types

Template registration is also available:

```d
client.registerAllCommands!(ping, onReady, AdminCommands, CounterPlugin);
```

`@Task` can be registered explicitly too:

```d
client.registerTasks!(cleanupTask);
client.registerTaskGroup!BackgroundTasks();
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
- whether free functions, types, events, plugins, or tasks should be considered

## Events

Register handlers with `on!EventType`:

```d
client.on!ReadyEvent((event) {
    import std.stdio : writeln;
    writeln("Ready as ", event.selfUser.username);
});
```

Or declare them with `@Event` and let registration wire them:

```d
@Event
void onReady(ReadyEventContext ctx)
{
    import std.stdio : writeln;
    writeln("Ready as ", ctx.selfUser.username);
}
```

`@Event` is the UDA form of event registration. It is useful when you want command handlers and
event handlers to live under the same `registerAllCommands` flow, including stateful groups.
Handlers may accept either the raw event struct or the matching context type.

Useful events include:

- `ReadyEvent`
- `ResumedEvent`
- `GuildCreateEvent`
- `GuildDeleteEvent`
- `GuildMemberRemoveEvent`
- `GuildBanAddEvent`
- `GuildBanRemoveEvent`
- `ChannelCreateEvent`
- `ChannelUpdateEvent`
- `ChannelDeleteEvent`
- `MessageCreateEvent`
- `MessageUpdateEvent`
- `MessageDeleteEvent`
- `InteractionCreateEvent`
- `GuildMemberAddEvent`
- `PresenceUpdateEvent`
- `TypingStartEvent`
- `AutocompleteInteractionEvent`
- `MessageComponentEvent`
- `ModalSubmitEvent`
- `CommandExecutedEvent`
- `CommandFailedEvent`

`ReadyEvent` includes `gatewayVersion`, the placeholder guild list carried by the initial `READY`,
and `resumeGatewayUrl`. Each shipped event also carries a typed `context` field with cached/current
entities and shared services for follow-up work.

For example:

- `MessageCreateEventContext` carries `message`, `user`, `guild`, `member`, `channel`, plus `cache`, `state`, `services`, `rest`, and `logger`
- `InteractionCreateEventContext` carries `interaction` and the same shared app surface
- `CommandExecutedEventContext` and `CommandFailedEventContext` also expose the originating command context and route-aware helpers such as `prefix`, `slash`, `contextMenu`, and `hybrid`
