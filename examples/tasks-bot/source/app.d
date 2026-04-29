module app;

import core.time : dur;
import ddiscord;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;

@Command("timer", description: "Schedule a reminder in seconds", routes: CommandRoute.Prefix)
void timer(CommandContext ctx, long seconds = 5)
{
    if (seconds < 1 || seconds > 600)
    {
        ctx.send("Pick a delay between 1 and 600 seconds.").await();
        return;
    }

    auto scheduler = ctx.services.get!TaskScheduler();
    auto rest = ctx.services.get!RestClient();

    auto sequence = ctx.state.global.getOr!int("tasks-sequence", 0) + 1;
    ctx.state.global.set("tasks-sequence", sequence);

    auto label = "timer:" ~ sequence.to!string;
    auto channelId = ctx.channel.id;
    auto mention = ctx.user.mention;

    scheduler.schedule(label, dur!"seconds"(seconds), {
        auto message = MessageCreate("Timer `" ~ label ~ "` finished for " ~ mention ~ ".");
        auto sent = rest.messages.create(channelId, message).awaitResult();
        if (sent.isErr)
            writeln("[tasks] reminder send failed: ", sent.error);
    });

    auto created = ctx.state.user(ctx.user.id).getOr!int("timers-created", 0) + 1;
    ctx.state.user(ctx.user.id).set("timers-created", created);

    ctx.send(
        "Scheduled `" ~ label ~ "` for " ~ seconds.to!string ~ "s. total timers=" ~
        created.to!string
    ).await();
}

@Command("timers", description: "Show your created timer count", routes: CommandRoute.Prefix)
void timers(CommandContext ctx)
{
    auto created = ctx.state.user(ctx.user.id).getOr!int("timers-created", 0);
    ctx.send("you created " ~ created.to!string ~ " timer(s)").await();
}

@Event
void onReady(ReadyEventContext ctx)
{
    writeln("[tasks] ready as ", ctx.selfUser.username);
}

@Stateful
struct BackgroundTasks
{
    @Task(dur!"minutes"(30), label: "tasks-heartbeat")
    void heartbeat()
    {
        // Example recurring task intentionally keeps a low-noise no-op body.
    }
}

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.GuildTextCommands,
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.registerAllCommands();
    client.registerTaskGroup!BackgroundTasks();
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "task reminders"));

    client.run();
    client.wait();
}
