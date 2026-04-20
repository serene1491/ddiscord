# State and Tasks

Two small systems make a big difference in real bots:

- `StateStore` for scoped bot state
- `TaskScheduler` for delayed and recurring work

## State scopes

```d
ctx.state.global.set("version", "1");
ctx.state.user(ctx.user.id).set("counter", 3);
ctx.state.channel(ctx.channel.id).set("last-topic", "status");
```

Reading values:

```d
auto count = ctx.state.user(ctx.user.id).getOr!int("counter", 0);
```

Available scopes:

- `global`
- `guild(guildId)`
- `channel(channelId)`
- `user(userId)`
- `member(guildId, userId)`

## Scheduled tasks

```d
client.tasks.schedule("one-shot", dur!"seconds"(10), {
    import std.stdio : writeln;
    writeln("ran once");
});

client.tasks.every("heartbeat", dur!"minutes"(5), {
    client.setPresence(StatusType.Online, Activity(ActivityType.Watching, "the server"));
});
```

The scheduler runs in its own loop after `client.run()`. Callback errors are captured so one failing task does not kill the bot.
