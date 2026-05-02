# Client Config and Lifecycle

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

## Building a client

```d
auto client = new Client(ClientConfig(
    token: env.require!string("TOKEN"),
    intents: cast(uint) GatewayIntent.GuildTextCommands,
    prefix: "!"
));
```

The most important `ClientConfig` fields are:

- `token`: required for real startup
- `intents`: gateway intents
- `prefix`: used for prefix command parsing
- `pluginsDir`: folder scanned for file-based Lua plugins
- `allowLoosePlugins`: allows standalone `.lua` files without a manifest (`true` by default)
- `allowPluginEntrypointEscape`: allows manifest entrypoints outside the plugin directory (`false` by default)
- `requireExplicitPluginPermissions`: disables implicit host permissions for untrusted plugins without a `permissions` list (`false` by default)
- `ownerId`: used by `@RequireOwner`; if owner-only commands are registered and this is unset, startup logs a warning and those commands deny every invoker until you configure an owner ID
- `autoSyncCommands`: keeps slash commands in sync during startup
- `restTimeout`: per-request REST timeout (`15s` by default)
- `httpSessionPoolSize`: pooled HTTP session slots used by REST (`2` by default)
- `httpMaxSessionIdle`: refreshes stale pooled keep-alive sessions after this idle window (`55s` by default)
- `autoRetryRateLimits`: retries transient Discord `429` responses when `Retry-After` is present (`true` by default)
- `maxRateLimitRetries`: cap for automatic `429` retries (`3` by default)
- `autoRetryServerErrors`: retries transient `5xx`/timeout/transport failures (`true` by default)
- `maxServerErrorRetries`: cap for automatic server-side retries (`3` by default)
- `retryBaseDelay`: initial retry delay used for transient failures (`500ms` by default)
- `maxRetryDelay`: upper bound for exponential retry backoff (`30s` by default)
- `logLevel`: optional minimum log level, defaults to `Information`
- `logUnhandledGatewayDispatchEvents`: emits sampled logs for dispatch events that still have no typed handler (`false` by default)
- `gatewayUnhandledDispatchLogEvery`: sampling interval for repeated unhandled dispatch logs (`100` by default, `0` behaves like `1`)
- `maxDispatchQueueSize`: upper bound for pending gateway dispatch work (default `4096`, `0` = unbounded)
- `dropOldestDispatchOnOverflow`: when queue pressure is high, keep latest events by dropping oldest pending items (`true` by default)
- `dispatchOverflowLogEvery`: overflow warning cadence (`100` by default, `0` disables warning logs)

Common intent presets:

- `GatewayIntent.GuildTextCommands`: guild text command bots
- `GatewayIntent.GuildTextCommandsWithReactions`: guild text + reactions
- `GatewayIntent.DirectTextCommands`: DM command bots
- `GatewayIntent.DefaultCommandBot`: guild + DM command flows
- `GatewayIntent.NonPrivileged`: all available non-privileged intents

## Runtime lifecycle

`run()` does real startup work:

1. calls `/users/@me`
2. calls `/gateway/bot`
3. loads plugins from `pluginsDir`
4. activates Lua plugins
5. syncs application commands when enabled
6. starts the gateway thread
7. starts the dispatch and task loops

Use `wait()` to keep the process running and `stop()` to shut it down cleanly.

## Production backpressure

`Client` has bounded dispatch queue controls so long traffic spikes do not grow memory
without limits.

```d
auto client = new Client(ClientConfig(
    token: env.require!string("TOKEN"),
    intents: cast(uint) GatewayIntent.NonPrivileged,
    maxDispatchQueueSize: 8192,
    dropOldestDispatchOnOverflow: true,
    dispatchOverflowLogEvery: 50
));
```

You can inspect queue pressure at runtime:

```d
auto health = client.dispatchQueueHealth;
// health.queued
// health.peakQueued
// health.maxQueued
// health.droppedTotal
```

## Uptime

`client.uptime` tracks real process uptime.

```d
import std.stdio : writeln;

writeln("uptime: ", client.uptime.toString());
writeln("uptime ms: ", client.uptime.milliseconds);
```

## Logging

The client creates a console logger by default. Without extra setup you get:

- startup and sync information
- plugin activation and lifecycle failures
- command failures
- gateway disconnect errors

Successful command timing logs are available at `Debug` level.
