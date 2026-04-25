module app;

import ddiscord;
import std.conv : to;
import std.format : format;
import std.path : buildPath;
import std.random : uniform;
import std.stdio : writeln;

@Event
void handleReady(ReadyEventContext ctx)
{
    writeln("[basic] ready as ", ctx.selfUser.username);
}

@Command("ping", description: "Check the bot latency", routes: CommandRoute.Prefix)
void handlePing(CommandContext ctx)
{
    auto embed = EmbedBuilder()
        .title("Pong")
        .description(
            "Gateway receive lag: " ~ ctx.receiveLatencyMilliseconds.to!string ~ "ms\n" ~
            "REST latency: " ~ ctx.rest.latency.total!"msecs".to!string ~ "ms"
        )
        .color(0x5865F2)
        .build();

    MessageCreate payload;
    payload = payload.withEmbed(embed);
    ctx.send(payload).await();
}

@Command("info", description: "Show information about a user", routes: CommandRoute.Slash)
@GuildInstalled
@UserInstalled
void handleInfo(CommandContext ctx, Nullable!User target = Nullable!User.init)
{
    auto resolved = target.isNull ? ctx.user : target.get;

    auto embed = EmbedBuilder()
        .title(resolved.globalName.getOr(resolved.username))
        .addField("Username", resolved.username, true)
        .addField("ID", resolved.id.toString, true)
        .addField("Bot", resolved.bot ? "yes" : "no", true)
        .color(0x57F287)
        .build();

    MessageCreate payload;
    payload = payload.withEmbed(embed);
    ctx.send(payload, ephemeral: true).await();
}

@HybridCommand("roll", "Roll a dice")
void handleRoll(HybridContext ctx, long sides = 6)
{
    auto result = uniform(1L, sides + 1L);
    auto response = format!"Rolled %d on a d%d."(result, sides);

    if (ctx.source == CommandSource.Slash)
        ctx.send(response, ephemeral: true).await();
    else
        ctx.send(response).await();
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
    client.setPresence(StatusType.Online, Activity(ActivityType.Watching, "your commands"));

    client.run();
    writeln("[basic] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
