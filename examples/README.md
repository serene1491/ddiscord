# Examples

`ddiscord` now ships three runnable console examples:

- `basic_bot.d`: prefix + slash commands with a live Discord session
- `plugin_bot.d`: plugin descriptors, service injection, `@LuaExpose`, and owner-only command flow
- `full_bot.d`: permissions, rate limits, state, components, prefix + slash orchestration

The example executables are emitted directly into `examples/`:

- `examples/example-basic-bot`
- `examples/example-plugin-bot`
- `examples/example-full-bot`

## Run

```sh
dub run --config=example-basic-bot
dub run --config=example-plugin-bot
dub run --config=example-full-bot
```

The examples load environment values from `examples/.env` and `examples/.env.local`.

Accepted token variables for the examples:

- `DISCORD_TOKEN`
- `TOKEN`
- `BOT_OWNER_ID` or `OWNER_ID` for the owner-only Lua eval command in `plugin_bot.d`
- `PLUGINS_DIR` to override the default `examples/plugins` directory used by `plugin_bot.d`

All three examples start a real Discord REST + gateway session and stay online until you stop the process.
