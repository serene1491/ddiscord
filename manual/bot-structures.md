# Bot Structures

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

This page shows practical project layouts you can copy.

## Choose the right structure

Use this quick rule:

1. You are alone, validating features: start with minimal.
2. Small team, shared ownership: use recommended small bot.
3. Multi-domain bot, plugins/Lua, long-term maintenance: use full production layout.

## Minimal bot (fast start)

```text
my-bot/
├── dub.json
└── source/
    └── app.d
```

```d
module app;

import ddiscord;

@Command("ping", routes: CommandRoute.Prefix)
void ping(CommandContext ctx)
{
    ctx.reply("pong").await();
}

void main()
{
    auto client = new Client(ClientConfig(
        token: loadEnv(".").require!string("TOKEN"),
        intents: cast(uint) GatewayIntent.GuildTextCommands,
        prefix: "!"
    ));

    client.registerAllCommands();
    client.run();
    client.wait();
}
```

Use this when you want to validate token/intents/command wiring first.

When to leave this structure:

1. `app.d` starts mixing startup, services, and handlers.
2. You need tests around domain logic.
3. You add persistent storage or multiple command groups.

## Recommended small bot

```text
my-bot/
├── dub.json
└── source/
    ├── app.d
    ├── bot/
    │   ├── config.d
    │   └── services.d
    └── commands/
        ├── registry.d
        ├── moderation.d
        └── ...
```

Why this helps:

- `app.d`: startup only (run/wait/register hooks)
- `bot/config.d`: env/config parsing
- `bot/services.d`: dependency injection setup
- `commands/*`: command handlers grouped by domain

Suggested additions as the bot grows:

1. `views/` for response builders (embeds/messages/components)
2. `domain/` for pure logic and validation
3. `infra/` for repositories/adapters

## Full bot (production layout)

```text
my-bot/
├── dub.json
├── plugins/
│   └── ...
└── source/
    ├── app.d
    ├── bot/
    │   ├── config.d
    │   ├── lifecycle.d
    │   └── services.d
    ├── commands/
    │   ├── registry.d
    │   ├── admin/
    │   ├── utility/
    │   └── support/
    ├── domain/
    │   ├── tickets/
    │   └── moderation/
    ├── infra/
    │   ├── sqlite/
    │   └── redis/
    ├── scripting/
    │   ├── apis/
    │   └── runtime_factory.d
    └── views/
        └── ...
```

Use this when you need:

- clear domain boundaries
- testable repositories/services
- plugins or Lua scripting
- multiple command modules and event handlers

## File ownership model

A practical ownership split for teams:

1. `bot/*`: runtime wiring and lifecycle
2. `commands/*`: user-facing flows
3. `domain/*`: business behavior, no Discord calls
4. `infra/*`: DB/HTTP adapters
5. `scripting/*`: Lua exposure and runtime policy

This makes review boundaries clearer and avoids accidental coupling.

## Common flows

1. Add a new command group:
`commands/<group>.d` + register in `commands/registry.d`.
2. Add a new service:
define interface/impl, register in `bot/services.d`, inject with `@Inject`.
3. Add a new Lua API:
create `scripting/apis/<name>_api.d`, annotate with `@LuaApi`, expose members with `@LuaExpose`, include it in the Lua runtime setup.
4. Add troubleshooting hints:
create view helpers and surface guidance from command/script errors.

## Related guides

- Startup/runtime details: [Client Config and Lifecycle](client-config-and-lifecycle.md)
- Command patterns: [Commands Guide](commands.md)
- Lua/plugin integration: [Plugins and Lua](plugins-and-lua.md)
- Operational issues: [Troubleshooting](troubleshooting.md)
