# Quickstart

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

This page is the fastest path to a real bot with `ddiscord`.

## Before you start

Checklist:

1. D compiler + `dub` installed and working
2. Bot token created in Discord Developer Portal
3. Bot invited with `applications.commands` and message permissions
4. Intent plan decided (`MessageContent` is needed for prefix text parsing)

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

    client.registerAllCommands();
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

Smoke test:

1. Wait for `ReadyEvent` output.
2. Send prefix command (`!ping` by default).
3. Confirm bot reply in the same channel.

## 4. What is happening here

1. `loadEnv` reads `.env` values.
2. `ClientConfig` defines token, intents, and prefix.
3. `registerAllCommands()` scans the current module, reads UDA metadata, and prepares the command list.
4. `run()` authenticates over REST, discovers the gateway, syncs commands, loads plugins, and starts the live session.
5. `wait()` keeps the process alive.

Common mistakes at this stage:

1. Wrong token in `.env`
2. Missing `GatewayIntent.MessageContent` for prefix commands
3. Prefix mismatch between `.env` and test messages
4. Running from a directory without the expected `.env`

## 5. Next steps

- Pick a project layout in [Bot Structures](bot-structures.md).
- Read [Client Guide](client.md) to understand the main `Client` APIs.
- Read [Commands Guide](commands.md) to add slash, hybrid, and policy-driven commands.
- Read [Plugins and Lua](plugins-and-lua.md) if you want scripting.

Common first tasks:

1. Add a `/health` slash command and a prefix `!ping`.
2. Add a `ReadyEvent` log so startup is visible.
3. Add one service (for example a repository) and inject it into a command group.

Related guides:

- Runtime details: [Client Config and Lifecycle](client-config-and-lifecycle.md)
- Command routing and policies: [Commands Guide](commands.md)
- Project organization: [Bot Structures](bot-structures.md)
