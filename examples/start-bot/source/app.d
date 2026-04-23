module app;

import ddiscord;
import std.path : buildPath;
import std.stdio : writeln;

void main()
{
    auto env = loadEnv(buildPath(".."));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.on!ReadyEvent((event) {
        writeln("[start] ready as ", event.selfUser.username);
    });

    client.run();
    client.wait();
}
