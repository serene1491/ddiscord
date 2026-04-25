# REST Shortcuts and Command Context

## Presence

```d
client.setPresence(
    StatusType.Online,
    Activity(ActivityType.Playing, "with D")
);
```

This updates both local state and the live gateway session.

## REST shortcuts

The `Client` exposes common REST groups directly, so normal usage does not need `client.rest`:

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
- `client.messages.create(...)`, `client.messages.edit(...)`, `client.messages.delete(...)`, `client.messages.bulkDelete(...)`, `client.messages.crosspost(...)`, `client.messages.pin(...)`, `client.messages.unpin(...)`, and `client.messages.pins(...)`
- `client.reactions.add(...)`, `client.reactions.removeSelf(...)`, `client.reactions.removeUser(...)`, `client.reactions.clear(...)`, and `client.reactions.clearEmoji(...)`
- `client.guilds.timeoutMember(...)`, `client.guilds.clearMemberTimeout(...)`, `client.guilds.kick(...)`, `client.guilds.ban(...)`, and `client.guilds.unban(...)` (all with optional audit-log reason)
- `client.threads.createFromMessage(...)`, `client.threads.create(...)`, `client.threads.join(...)`, `client.threads.leave(...)`, and `client.threads.archive(...)`
- `client.webhooks.execute(...)` for webhook-token message dispatch
- `client.slash.sync(...)` when you want direct command-manifest sync

## Service container shortcuts

`Client` now exposes thin wrappers around `client.services` for cleaner setup:

```d
client.addService!GreetingService(new GreetingService("Hello"));
client.addServices(
    new GreetingService("Hello"),
    new MetricsService()
);
client.addServiceFactory!Database(() => new Database("bot.db"));

auto db = client.service!Database();
Database maybeDb;
if (client.tryService!Database(maybeDb))
{
    // use maybeDb
}
```

Available helpers:

- `addService!T(instance)`
- `addServices(instanceA, instanceB, ...)`
- `addService!T()` for default construction
- `addServiceFactory!T(factory)`
- `service!T()`
- `tryService!T(out value)`
- `removeService!T()`

## Sharding controls

`Client` now supports runtime shard management without restarting the bot process:

```d
client.reshard(4);                 // force 4 shards now
client.refreshShardTopology();     // pull recommended shard count from Discord
auto running = client.activeShardCount;
```

For automatic topology adjustment, configure `ClientConfig`:

```d
auto client = new Client(ClientConfig(
    // ...
    enableSharding: true,
    autoSharding: true,
    autoReshard: true
));
```

## Sending and thinking helpers

`CommandContext` has helpers for common UX flows:

```d
ctx.think().await();
ctx.send("Done.").await();
ctx.reply("Working on it...", true).await();
ctx.sendFile("report.json", cast(const(ubyte)[]) reportBytes, "Attached report", "application/json").await();
```

- `think()` defers interaction commands and triggers channel typing for prefix/message commands
- `send(...)` sends the normal response for the current context and automatically switches to
  interaction follow-up messages when the interaction was already acknowledged
- `reply(...)` sends a native Discord reply when the context came from a message
- `sendFile(...)`, `followupFile(...)`, and `editFile(...)` are shortcuts for multipart attachment uploads

Message-target helpers are also available to avoid verbose REST chaining:

```d
ctx.react("✅").await();
ctx.pin(Nullable!string.of("important")).await();
ctx.crosspost().await();

if (!ctx.messageRef.isNull)
{
    ctx.messageRef.get.edit("updated text").await();
}
```

These map to the same REST endpoints with thin wrappers, so you keep ergonomics without extra runtime overhead.

The command layer also exposes route-specific context shapes when you want tighter typing:

- `PrefixContext`
- `SlashContext`
- `ContextMenuContext`
- `HybridContext`

You can annotate commands for the default help system:

- `@CommandCategory("Utility")` to group/filter commands
- `@HideFromHelp` to keep a command registered but absent from built-in help
