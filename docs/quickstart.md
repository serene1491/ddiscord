# Quickstart

This page is the fastest path to a real bot with `ddiscord`.

## 1. Create a bot token

Create a Discord bot application and copy the bot token from the Discord developer portal.

Then create `examples/.env` or your own `.env` file:

```env
TOKEN=your_bot_token
BOT_PREFIX=!
```

## 2. Minimal bot

```d
import ddiscord;

@Command("ping", description: "Reply with Pong", routes: CommandRoute.Prefix)
void handlePing(CommandContext ctx)
{
    ctx.reply("Pong!").await();
}

void main()
{
    auto env = loadEnv(".");

    auto client = new Client(ClientConfig(
        token: env.require!string("TOKEN"),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: env.get!string("BOT_PREFIX", "!")
    ));

    client.on!ReadyEvent((event) {
        import std.stdio : writeln;
        writeln("Logged in as ", event.selfUser.username);
    });

    client.registerAllCommands!handlePing();
    client.run();
    client.wait();
}
```

## 3. Run it

If this is your own project, run it with DUB as usual:

```sh
dub run
```

If you just want to try the library immediately, use one of the bundled consoles:

```sh
cd examples/basic-bot && dub run
```

## 4. What is happening here

1. `loadEnv` reads `.env` values.
2. `ClientConfig` defines token, intents, and prefix.
3. `registerAllCommands!handlePing()` extracts UDA metadata and builds the command manifest.
4. `run()` authenticates over REST, discovers the gateway, syncs commands, loads plugins, and starts the live session.
5. `wait()` keeps the process alive.

## 5. Next steps

- Read [Client Guide](client.md) to understand the runtime surface.
- Read [Commands Guide](commands.md) to add slash, hybrid, and policy-driven commands.
- Read [Plugins and Lua](plugins-and-lua.md) if you want scripting.
