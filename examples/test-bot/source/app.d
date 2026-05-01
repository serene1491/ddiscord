module app;

import core.thread : Thread;
import core.time : dur;
import ddiscord;
import std.array : join;
import std.conv : ConvException, to;
import std.format : format;
import std.path : buildPath;
import std.random : uniform;
import std.stdio : writeln;
import std.string : indexOf, strip;

private Nullable!Snowflake optionalSnowflake(EnvLoader env, string key)
{
    auto value = env.get!string(key, "");
    if (value.length == 0)
        return Nullable!Snowflake.init;
    return Nullable!Snowflake.of(Snowflake(value.to!ulong));
}

private ulong parseAutoStopSeconds(EnvLoader env)
{
    auto raw = env.get!string("TEST_BOT_RUN_SECONDS", "0").strip;
    if (raw.length == 0)
        return 0;

    try
    {
        return raw.to!ulong;
    }
    catch (ConvException)
    {
        writeln("[test] invalid TEST_BOT_RUN_SECONDS=", raw, " (expected integer); running continuously");
        return 0;
    }
}

private string formatLatency(CommandContext ctx)
{
    return "gateway receive lag=" ~ ctx.receiveLatencyMilliseconds.to!string ~ "ms, rest=" ~
        ctx.rest.latency.total!"msecs".to!string ~ "ms";
}

private string shortError(string error)
{
    static string detailPrefix = "Detail: ";
    static string hintPrefix = "Hint: ";

    auto detailStart = error.indexOf(detailPrefix);
    if (detailStart != -1)
    {
        auto detail = error[detailStart + cast(ptrdiff_t) detailPrefix.length .. $];
        auto hintStart = detail.indexOf(hintPrefix);
        if (hintStart != -1)
            detail = detail[0 .. hintStart];

        detail = detail.strip;
        if (detail.length != 0)
            error = detail;
    }

    if (error.length > 160)
        return error[0 .. 160] ~ "...";
    return error;
}

private void appendCheck(ref string[] lines, string label, bool ok, string detail)
{
    auto status = ok ? "ok" : "fail";
    lines ~= "[" ~ status ~ "] " ~ label ~ " - " ~ detail;
}

private string[] runStartupChecks(
    Client client,
    User selfUser,
    Nullable!Snowflake startupChannelId,
    Nullable!Snowflake testServerId
)
{
    string[] lines;

    auto me = client.users.me().awaitResult();
    if (me.isOk)
        appendCheck(lines, "users.me", true, me.value.username ~ " (" ~ me.value.id.toString ~ ")");
    else
        appendCheck(lines, "users.me", false, shortError(me.error));

    auto manifest = client.slash.list().awaitResult();
    if (manifest.isOk)
        appendCheck(lines, "slash.list", true, "commands=" ~ manifest.value.length.to!string);
    else
        appendCheck(lines, "slash.list", false, shortError(manifest.error));

    if (!startupChannelId.isNull)
    {
        auto channel = client.channels.get(startupChannelId.get).awaitResult();
        if (channel.isOk)
            appendCheck(lines, "channels.get(TEST_CHANNEL_ID)", true, channel.value.id.toString);
        else
            appendCheck(lines, "channels.get(TEST_CHANNEL_ID)", false, shortError(channel.error));
    }

    if (!testServerId.isNull)
    {
        auto guild = client.guilds.get(testServerId.get).awaitResult();
        if (guild.isOk)
            appendCheck(lines, "guilds.get(TEST_SERVER_ID)", true, guild.value.name);
        else
            appendCheck(lines, "guilds.get(TEST_SERVER_ID)", false, shortError(guild.error));

        auto member = client.guilds.member(testServerId.get, selfUser.id).awaitResult();
        if (member.isOk)
            appendCheck(lines, "guilds.member(self)", true, member.value.user.getOr(selfUser).username);
        else
            appendCheck(lines, "guilds.member(self)", false, shortError(member.error));

        auto roles = client.guilds.roles(testServerId.get).awaitResult();
        if (roles.isOk)
            appendCheck(lines, "guilds.roles", true, "roles=" ~ roles.value.length.to!string);
        else
            appendCheck(lines, "guilds.roles", false, shortError(roles.error));
    }

    return lines;
}

@Command("ping", description: "Check prefix command latency", routes: CommandRoute.Prefix)
void handlePing(CommandContext ctx)
{
    ctx.send("pong | " ~ formatLatency(ctx)).await();
}

@Command("status", description: "Check slash command handling", routes: CommandRoute.Slash)
void handleStatus(CommandContext ctx)
{
    auto content = "slash status ok | user=" ~ ctx.user.username ~ " | " ~ formatLatency(ctx);
    ctx.send(content, ephemeral: true).await();
}

@HybridCommand("echo", "Echo text through prefix or slash")
void handleEcho(HybridContext ctx, string text = "hello from ddiscord")
{
    auto route = ctx.source == CommandSource.Slash ? "slash" : "prefix";
    auto content = "echo (" ~ route ~ "): " ~ text;

    if (ctx.source == CommandSource.Slash)
        ctx.send(content, ephemeral: true).await();
    else
        ctx.send(content).await();
}

@Command("roll", description: "Roll a dice from a prefix command", routes: CommandRoute.Prefix)
void handleRoll(CommandContext ctx, long sides = 6)
{
    if (sides < 2)
    {
        ctx.send("sides must be >= 2").await();
        return;
    }

    auto result = uniform(1L, sides + 1L);
    ctx.send(format!"rolled %d on d%d"(result, sides)).await();
}

@Command("dashboard", description: "Render a Components V2 diagnostics card", routes: CommandRoute.Prefix)
@CommandCategory("Diagnostics")
void handleDashboard(CommandContext ctx)
{
    MessageCreate payload;
    payload = payload.addComponent(
        Container()
            .accentColor(0x5865F2)
            .addComponent(TextDisplay("### ddiscord diagnostics"))
            .addComponent(TextDisplay("Runtime checks, command routes, and component callbacks are active."))
            .addComponent(Separator(SeparatorSpacing.Large))
            .addComponent(ActionRow().addComponent(Button("test:ack", "Acknowledge", ButtonStyle.Success)))
    );
    ctx.send(payload).await();
}

@MessageCommand("Inspect Message")
void handleInspectMessage(CommandContext ctx)
{
    ctx.send("Message context menu reached by `" ~ ctx.user.username ~ "`.").await();
}

@UserCommand("Inspect User")
void handleInspectUser(CommandContext ctx)
{
    ctx.send("User context menu reached by `" ~ ctx.user.username ~ "`.").await();
}

void main()
{
    auto env = loadEnv(buildPath(".."));
    auto startupChannelId = optionalSnowflake(env, "TEST_CHANNEL_ID");
    auto testServerId = optionalSnowflake(env, "TEST_SERVER_ID");
    auto autoStopSeconds = parseAutoStopSeconds(env);

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.GuildTextCommands,
        prefix: env.get!string("BOT_PREFIX", "!"),
        autoSyncCommands: true
    ));

    client.on!ReadyEvent((event) {
        writeln("[test] ready as ", event.selfUser.username, " session=", event.sessionId);

        auto lines = runStartupChecks(client, event.selfUser, startupChannelId, testServerId);
        foreach (line; lines)
            writeln("[test] ", line);

        if (!startupChannelId.isNull)
        {
            auto report = "test-bot ready | synced=" ~ client.commands.applicationCommands.length.to!string ~
                "\n" ~ lines.join("\n");
            if (report.length > 1800)
                report = report[0 .. 1800] ~ "\n... truncated ...";

            auto sent = client.messages.create(startupChannelId.get, MessageCreate(report)).awaitResult();
            if (sent.isOk)
                writeln("[test] startup report sent to channel ", startupChannelId.get.toString);
            else
                writeln("[test] startup report failed: ", shortError(sent.error));
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

    client.on!MessageComponentEvent((event) {
        if (event.context.customId != "test:ack")
            return;

        auto actor = event.context.user;
        auto username = actor.isNull ? "unknown" : actor.get.username;
        auto sent = client.interactions.send(
            event.interaction.id,
            event.interaction.token,
            MessageCreate("component ack by `" ~ username ~ "`")
        ).awaitResult();

        if (sent.isErr)
            writeln("[test] component response failed: ", shortError(sent.error));
        else
            writeln("[test] component response sent for ", username);
    });

    client.on!CommandExecutedEvent((event) {
        writeln("[test] command executed name=", event.commandName, " replies=", event.replyCount);
    });

    client.on!CommandFailedEvent((event) {
        writeln("[test] command failed name=", event.attemptedName, " error=", event.error);
    });

    client.registerCommands();
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "gateway integration checks"));

    client.run();

    if (autoStopSeconds > 0)
    {
        writeln("[test] auto-stop armed for ", autoStopSeconds, "s");
        Thread.sleep(dur!"seconds"(cast(long) autoStopSeconds));
        writeln("[test] exiting after ", autoStopSeconds, "s");
        return;
    }

    client.wait();
}
