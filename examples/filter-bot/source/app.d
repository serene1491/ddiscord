module app;

import ddiscord;
import std.path : buildPath;
import std.stdio : writeln;

@CommandCategory("Public")
@Command("hello", description: "Visible public command", routes: CommandRoute.Prefix)
void hello(CommandContext ctx)
{
    ctx.send("hello from filter-bot").await();
}

@CommandCategory("Internal")
@Command("debug", description: "Internal command excluded by filters", routes: CommandRoute.Prefix)
void debugCommand(CommandContext ctx)
{
    ctx.send("debug route").await();
}

@Event
void onReady(ReadyEventContext ctx)
{
    writeln("[filter] ready as ", ctx.selfUser.username);
}

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    auto filter = CommandRegistrationFilter
        .categories("Public")
        .withoutPlugins();
    client.registerAllCommands(filter);

    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "filter checks"));
    client.run();
    writeln("[filter] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
