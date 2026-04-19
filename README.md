# ddiscord

`ddiscord` is a modular Discord bot engine for D with a UDA-first public API.

The refactored design in this repository treats UDAs as the primary way to declare:

- commands and command options
- hybrid or slash-only routing
- permission gates and rate limits
- stateful handler groups with service injection
- Lua plugin descriptors and host APIs exposed to Lua

## Current Status

The library currently ships a working core aimed at real bot usage:

- real Discord REST calls over `requests`
- real Discord gateway sessions over `aurora-websocket` + TLS sockets
- command sync, prefix handling, slash-command handling, follow-up/edit interaction replies, rate limits, cache/state, and scheduled tasks
- file-based Lua plugin loading with sandboxed execution and capability-gated host APIs
- runnable example bots in `examples/`

## Example

```d
import ddiscord;
import std.path : buildPath;

@Command("ping", description: "Check the bot latency", routes: CommandRoute.Prefix)
void handlePing(CommandContext ctx)
{
    ctx.reply("Pong!").await();
}

void main()
{
    auto env = loadEnv(buildPath("examples"));

    auto client = new Client(ClientConfig(
        token: env.get!string("DISCORD_TOKEN", env.require!string("TOKEN")),
        intents: cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent),
        prefix: "!"
    ));

    client.registerAllCommands!handlePing();
    client.run();
    client.wait();
}
```

## Lua

Lua integrations are also attribute-driven:

- `@LuaPlugin` declares the host-side descriptor for a Lua bundle
- `@LuaExpose` marks D functions or methods that may be injected into Lua
- sandbox profile and permission grants decide what is actually visible at runtime
- untrusted scripts only receive safe proxy tables and capability-gated functions
- file-based plugins can be loaded from `plugin.json` + `.lua` entrypoints and executed during client startup

## Docs

- [docs/index.md](docs/index.md) for user-facing guides
- [examples/README.md](examples/README.md) for runnable consoles

The client now ships with default console logging at `Information` level, so connection, sync, owner-configuration warnings, command failures, and plugin lifecycle problems are visible without extra setup. Successful command timing logs are available at `Debug`.
