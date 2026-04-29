# Troubleshooting

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

## Quick triage flow

Run this order to isolate issues fast:

1. Is the bot reaching `ReadyEvent`?
2. Do prefix commands work?
3. Do slash commands sync and appear?
4. Are failures only in Lua/plugin flows?
5. Do logs show policy rejection vs runtime errors?

## The bot starts slowly

A real `ddiscord` startup does several network steps before the gateway is fully live:

1. `/users/@me`
2. `/gateway/bot`
3. command sync when `autoSyncCommands` is enabled
4. plugin activation when Lua plugins are enabled

If startup time matters more than automatic sync, disable it:

```d
auto client = new Client(ClientConfig(
    token: env.require!string("TOKEN"),
    intents: cast(uint) GatewayIntent.Guilds,
    autoSyncCommands: false
));
```

## The bot responds slowly after it is online

Common causes:

- slow local DNS/TLS on the machine
- command handlers doing blocking work before replying
- many commands hitting REST in sequence
- prefix commands that trigger extra permission lookups because the needed guild/member/channel data is not cached yet
- large startup manifests being synced every run

The library separates gateway reading from command dispatch, which helps keep incoming events from being stalled by reply work.

Useful checks:

- run `!ping` and compare gateway receive lag against REST latency
- compare prefix and slash command latency
- try with `autoSyncCommands: false`
- log before and after expensive command code
- if only owner-only commands are affected, confirm `ClientConfig.ownerId` is set to the expected bot-owner user ID

The client prints `Information`, `Warning`, and `Error` logs by default, so startup, sync, plugin activation, owner-configuration warnings, command failures, and gateway disconnects should already be visible without extra logger setup. Successful command timing logs move to `Debug`.

If startup still stalls before `READY`, the client emits a warning after 20 seconds so you can distinguish "slow" from "never became ready".

## Slash commands do not show up

- confirm the bot has `applications.commands`
- confirm `client.registerAllCommands()` (or explicit registration helpers) ran before `run()`
- check command names and option names are valid lowercase slash names
- if needed, restart once after a fresh sync

If still missing:

1. Disable `autoSyncCommands` and run explicit sync workflow
2. Verify command contexts/install targets are compatible with where you test
3. Check command registration path was called before `run()`

## Lua plugin does not load

- verify `plugin.json`
- verify `ddiscordApiVersion` matches the current library
- verify the `scripts` entry points to a real `.lua` file
- verify the requested permissions match what the plugin actually uses

## Lua script behavior is confusing

If you expose custom Lua APIs from D:

1. list available exports (`runtime.exports`) and compare with script usage
2. show capability names (`luaCapabilityName`) for each export
3. validate source syntax before persisting user scripts
4. include hints in Lua error responses (for example how to inspect available APIs)

Practical bot commands that help:

- `/lua-apis`: show available symbols, mode, permission, and host signature
- `/lua-help`: show quick examples
- `/lua-check`: syntax-check a snippet without saving

## Prefix command parsed wrong input

Symptoms:

1. Quoted strings are split unexpectedly
2. Multiline source is flattened
3. Greedy trailing argument misses expected text

Checks:

1. Confirm final free-text parameter is modeled for greedy capture
2. Confirm command content is read as raw tail where intended
3. Use a minimal repro payload and compare sent vs received text

## Related guides

- [Commands Guide](commands.md)
- [Client Help and Errors](client-help-and-errors.md)
- [Plugins and Lua](plugins-and-lua.md)
