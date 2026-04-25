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

## `@Task` registration

For recurring/background jobs tied to your bot modules, use `@Task` and register the group:

```d
@Stateful
struct BackgroundTasks
{
    @Inject Logger logger;

    @Task(dur!"minutes"(5), label: "status-heartbeat", runOnRegister: true)
    void heartbeat()
    {
        logger.information("tasks", "heartbeat");
    }
}

client.registerTaskGroup!BackgroundTasks();
```

`@Task` supports:

- recurring tasks (`TaskMode.Every`, default)
- delayed one-shot tasks (`TaskMode.Delay`)
- cron-style `@every:<seconds>s` expressions via string constructor (`TaskMode.Cron`)
- loop-style helper constructor inspired by discord.py:
  `@Task.loop(seconds: ..., minutes: ..., hours: ..., label: "...", count: ..., reconnect: ...)`
- explicit helpers for readability:
  `@Task.every(...)`, `@Task.delay(...)`, and `@Task.cron(...)`

You can also trigger any registered task label manually:

```d
client.runTaskNow("status-heartbeat");
```
