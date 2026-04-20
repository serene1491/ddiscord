# Troubleshooting

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

The current library now separates gateway reading from command dispatch, which helps keep incoming events from being stalled by reply work.

Useful checks:

- run `!ping` and compare gateway receive lag against REST latency
- compare prefix and slash command latency
- try with `autoSyncCommands: false`
- log before and after expensive command code
- if only owner-only commands are affected, confirm `ClientConfig.ownerId` is set to the expected bot-owner user ID

The client prints `Information`, `Warning`, and `Error` logs by default, so startup, sync, plugin activation, owner-configuration warnings, command failures, and gateway disconnects should already be visible without extra logger setup. Successful command timing logs move to `Debug`.

If startup still stalls before `READY`, the client now emits a warning after 20 seconds so you can distinguish "slow" from "never became ready".

## Slash commands do not show up

- confirm the bot has `applications.commands`
- confirm `client.registerAllCommands!` or the explicit registration helpers ran before `run()`
- check command names and option names are valid lowercase slash names
- if needed, restart once after a fresh sync

## Lua plugin does not load

- verify `plugin.json`
- verify `ddiscordApiVersion` matches the current library
- verify the `scripts` entry points to a real `.lua` file
- verify the requested permissions match what the plugin actually uses
