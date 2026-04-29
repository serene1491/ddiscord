module app;

import ddiscord;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;

@Event
void handleReady(ReadyEventContext ctx)
{
    writeln("[events] ready as ", ctx.selfUser.username);
}

@Event
void handleMessage(MessageCreateEventContext ctx)
{
    if (ctx.message.author.bot)
        return;

    writeln(
        "[events] message user=",
        ctx.message.author.username,
        " channel=",
        ctx.message.channelId.toString,
        " content=",
        ctx.message.content
    );
}

@Event
void handleCommandExecuted(CommandExecutedEvent event)
{
    writeln(
        "[events] command executed name=",
        event.commandName,
        " replies=",
        event.replyCount.to!string
    );
}

@HybridCommand("ping-events", "Trigger command + event logs")
void handlePingEvents(HybridContext ctx)
{
    auto route = ctx.source == CommandSource.Slash ? "slash" : "prefix";
    ctx.send("events alive from `" ~ route ~ "`", ctx.source == CommandSource.Slash).await();
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
    client.setPresence(StatusType.Online, Activity(ActivityType.Watching, "event traffic"));

    client.run();
    client.wait();
}
