module app;

import ddiscord;
import std.stdio : writeln;

void main()
{
    auto client = new Client(ClientConfig(
        "YOUR_BOT_TOKEN",
        GatewayIntent.GuildMessages,
        "!"
    ));

    client.on!ReadyEvent((event) {
        writeln("[basic] ready as ", event.selfUser.username);
    });

    client.run();
    client.wait();
}
