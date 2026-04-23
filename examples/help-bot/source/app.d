module app;

import ddiscord;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;

private Nullable!Snowflake optionalOwnerId(EnvLoader env)
{
    auto raw = env.get!string("BOT_OWNER_ID", env.get!string("OWNER_ID", ""));
    if (raw.length == 0)
        return Nullable!Snowflake.init;
    return Nullable!Snowflake.of(Snowflake(raw.to!ulong));
}

@CommandCategory("Utility")
@HybridCommand("ping", "Check bot connectivity")
void handlePing(CommandContext ctx)
{
    auto route = ctx.source == CommandSource.Slash ? "slash" : "prefix";
    ctx.send("pong from `" ~ route ~ "`", ctx.source == CommandSource.Slash).await();
}

@CommandCategory("Owner")
@RequireOwner
@Command("reload-cache", description: "Owner-only maintenance action", routes: CommandRoute.Prefix)
void reloadCache(CommandContext ctx)
{
    auto previous = ctx.state.global.getOr!int("cache-reloads", 0);
    ctx.state.global.set("cache-reloads", previous + 1);
    ctx.reply("cache reload count=" ~ (previous + 1).to!string, mentionAuthor: false).await();
}

@HideFromHelp
@Command("debug-runtime", description: "Hidden command for runtime checks", routes: CommandRoute.Prefix)
void debugRuntime(CommandContext ctx)
{
    auto commandCount = 0UL;
    CommandRegistry registry;
    if (ctx.services.tryGet!CommandRegistry(registry))
        commandCount = cast(ulong) registry.descriptors.length;

    auto details = "history=" ~ ctx.rest.messages.history.length.to!string ~
        " commands=" ~ commandCount.to!string;
    ctx.send(details).await();
}

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!"),
        ownerId: optionalOwnerId(env),
        autoSyncCommands: true
    ));

    client.helpBehavior.pageSize = 4;
    client.helpBehavior.showBuiltinCommands = false;
    client.helpBehavior.includeCommand = (descriptor) {
        return descriptor.category != "Internal";
    };

    client.errorBehavior.surfaceUnknownCommand = true;
    client.errorBehavior.surfaceArgumentErrors = true;
    client.errorBehavior.surfacePolicyErrors = true;

    client.on!ReadyEvent((event) {
        writeln("[help] ready as ", event.selfUser.username);
    });

    client.registerCommands();
    client.setPresence(StatusType.Online, Activity(ActivityType.Watching, "help pages"));
    client.run();
    writeln("[help] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
