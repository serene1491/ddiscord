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
- command sync, prefix handling, slash-command handling, interaction replies, rate limits, cache/state, and scheduled tasks
- file-based Lua plugin loading with sandboxed execution and capability-gated host APIs
- runnable example bots in `examples/`

## Example

```d
module examples.basic_bot.commands.roll;

import ddiscord.commands        : Command, Option;
import ddiscord.context.command : CommandContext, CommandSource;
import std.format               : format;
import std.random               : uniform;

@Command("roll", description: "Roll a dice")
void handleRoll(
    CommandContext ctx,
    @Option("sides", "Number of sides", min: 2, max: 1000) long sides = 6L
)
{
    const result = uniform(1L, sides + 1L);
    const response = format!"🎲 You rolled a **%d** (d%d)"(result, sides);

    if (ctx.source == CommandSource.Slash)
        ctx.reply(response, ephemeral: true).await();
    else
        ctx.reply(response).await();
}
```

```d
import examples.basic_bot.commands.roll : handleRoll;

client.registerCommands!handleRoll();
```

## Lua

Lua integrations are also attribute-driven:

- `@LuaPlugin` declares the host-side descriptor for a Lua bundle
- `@LuaExpose` marks D functions or methods that may be injected into Lua
- sandbox profile and permission grants decide what is actually visible at runtime
- untrusted scripts only receive safe proxy tables and capability-gated functions
- file-based plugins can be loaded from `plugin.json` + `.lua` entrypoints and executed during client startup
