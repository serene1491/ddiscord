module full_bot;

import core.time : dur;
import ddiscord;
import std.conv : to;
import std.format : format;
import std.stdio : writeln;

@HybridCommand("greet", "Greet a user in a channel")
@RequirePermissions(Permissions.SendMessages)
void handleGreet(
    CommandContext ctx,
    User target,
    Channel targetChannel,
    string reason = "Welcome aboard"
)
{
    auto seen = ctx.state.user(ctx.user.id).getOr!int("greet-count", 0);
    ctx.state.user(ctx.user.id).set("greet-count", seen + 1);
    ctx.reply("Greeted " ~ target.mention ~ " in " ~ targetChannel.mention ~ " | " ~ reason, ephemeral: ctx.source == CommandSource.Slash).await();
}

@Command("dashboard", description: "Render a components dashboard", routes: CommandRoute.Prefix)
@RateLimit(1, dur!"seconds"(30), bucket: RateLimitBucket.User)
void handleDashboard(CommandContext ctx)
{
    auto container = Container()
        .accentColor(0x57F287)
        .addComponent(
            Section()
                .addText(TextDisplay("**Dashboard**"))
                .addText(TextDisplay("Stateful, rate-limited, and component-aware."))
                .accessory(Thumbnail("https://cdn.discordapp.com/embed/avatars/0.png"))
        )
        .addComponent(Separator(SeparatorSpacing.Medium));

    MessageCreate payload;
    payload = payload.withContent("dashboard");
    payload = payload.addComponent(container);
    payload = payload.setFlag(MessageFlags.IsComponentsV2);
    ctx.reply(payload).await();
}

@Command("counter", description: "Increment a per-user counter", routes: CommandRoute.Prefix)
void handleCounter(CommandContext ctx)
{
    auto current = ctx.state.user(ctx.user.id).getOr!int("counter", 0) + 1;
    ctx.state.user(ctx.user.id).set("counter", current);
    ctx.reply("counter => " ~ current.to!string).await();
}

void main()
{
    auto env = loadEnv("examples");

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.registerCommands!(handleGreet, handleDashboard, handleCounter);
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "server tools"));

    client.run();
    writeln("[full] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
