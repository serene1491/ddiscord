module app;

import ddiscord;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;

final class GreetingService
{
    private string _prefix;

    this(string prefix)
    {
        _prefix = prefix;
    }

    string greeting(User user, string target)
    {
        return _prefix ~ ", " ~ target ~ " — from " ~ user.username;
    }
}

@Stateful
struct GreetingCommands
{
    @Inject GreetingService greeter;

    @HybridCommand("hello-service", "Greet through an injected service")
    void hello(HybridContext ctx, string target = "friend")
    {
        auto message = greeter.greeting(ctx.user, target);
        ctx.send(message, ctx.source == CommandSource.Slash).await();
    }

    @Command("hello-count", description: "Show your service command usage", routes: CommandRoute.Prefix)
    void count(CommandContext ctx)
    {
        auto current = ctx.state.user(ctx.user.id).getOr!int("service-hello-count", 0) + 1;
        ctx.state.user(ctx.user.id).set("service-hello-count", current);
        ctx.send("service hello count=" ~ current.to!string).await();
    }
}

@Event
void onReady(ReadyEventContext ctx)
{
    writeln("[services] ready as ", ctx.selfUser.username);
}

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) GatewayIntent.GuildTextCommands,
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.services.add!GreetingService(new GreetingService(env.get!string("GREETING_PREFIX", "Hello")));

    client.registerEvents!onReady();
    client.registerCommandGroup!GreetingCommands();
    client.setPresence(StatusType.Online, Activity(ActivityType.Playing, "service injection"));

    client.run();
    writeln("[services] synced commands: ", client.commands.applicationCommands.length);
    client.wait();
}
