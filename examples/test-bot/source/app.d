module app;

import ddiscord;
import std.conv : to;
import std.format : format;
import std.path : buildPath;
import std.random : uniform;
import std.stdio : writeln;

private Nullable!Snowflake optionalSnowflake(EnvLoader env, string key)
{
    auto value = env.get!string(key, "");
    if (value.length == 0)
        return Nullable!Snowflake.init;
    return Nullable!Snowflake.of(Snowflake(value.to!ulong));
}

private string formatLatency(CommandContext ctx)
{
    return "gateway receive lag=" ~ ctx.receiveLatencyMilliseconds.to!string ~ "ms, rest=" ~
        ctx.rest.latency.total!"msecs".to!string ~ "ms";
}

@Command("ping", description: "Check prefix command latency", routes: CommandRoute.Prefix)
void handlePing(CommandContext ctx)
{
    ctx.reply("pong | " ~ formatLatency(ctx)).await();
}

@Command("status", description: "Check slash command handling", routes: CommandRoute.Slash)
void handleStatus(CommandContext ctx)
{
    auto content = "slash status ok | user=" ~ ctx.user.username ~ " | " ~ formatLatency(ctx);
    ctx.reply(content, ephemeral: true).await();
}

@HybridCommand("echo", "Echo text through prefix or slash")
void handleEcho(CommandContext ctx, string text = "hello from ddiscord")
{
    auto route = ctx.source == CommandSource.Slash ? "slash" : "prefix";
    auto content = "echo (" ~ route ~ "): " ~ text;

    if (ctx.source == CommandSource.Slash)
        ctx.reply(content, ephemeral: true).await();
    else
        ctx.reply(content).await();
}

@Command("roll", description: "Roll a dice from a prefix command", routes: CommandRoute.Prefix)
void handleRoll(CommandContext ctx, long sides = 6)
{
    auto result = uniform(1L, sides + 1L);
    ctx.reply(format!"rolled %d on d%d"(result, sides)).await();
}

void main()
{
    auto env = loadEnv(buildPath(".."));
    auto startupChannelId = optionalSnowflake(env, "TEST_CHANNEL_ID");

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!"),
        autoSyncCommands: true
    ));

    client.on!ReadyEvent((event) {
        writeln("[test] ready as ", event.selfUser.username, " session=", event.sessionId);

        if (!startupChannelId.isNull)
        {
            auto sent = client.rest.messages.create(
                startupChannelId.get,
                MessageCreate("test-bot ready | synced=" ~ client.commands.applicationCommands.length.to!string)
            ).awaitResult();

            if (sent.isOk)
                writeln("[test] startup message sent to channel ", startupChannelId.get.toString);
            else
                writeln("[test] startup message failed: ", sent.error);
        }
    });

    client.on!ResumedEvent((_event) {
        writeln("[test] resumed gateway session");
    });

    client.on!MessageCreateEvent((event) {
        if (!event.message.author.bot)
        {
            writeln(
                "[test] message create user=",
                event.message.author.username,
                " channel=",
                event.message.channelId.toString,
                " content=",
                event.message.content
            );
        }
    });

    client.on!InteractionCreateEvent((event) {
        if (event.interaction.commandName.length != 0)
            writeln("[test] interaction create command=", event.interaction.commandName);
    });

    client.on!CommandExecutedEvent((event) {
        writeln("[test] command executed name=", event.commandName, " replies=", event.replyCount);
    });

    client.on!CommandFailedEvent((event) {
        writeln("[test] command failed name=", event.attemptedName, " error=", event.error);
    });

    client.registerAllCommands!(handlePing, handleStatus, handleEcho, handleRoll);
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "gateway integration checks"));

    client.run();
    writeln("[test] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
