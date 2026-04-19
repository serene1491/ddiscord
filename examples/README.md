# Examples

`ddiscord` ships some runnable console examples as separate DUB packages. Try them:

- `basic-bot/`: prefix + slash commands with a live Discord session
- `plugin-bot/`: plugin descriptors, service injection, `@LuaExpose`, and owner-only command flow
- `full-bot/`: permissions, rate limits, state, components, prefix + slash orchestration
- `test-bot/`: integration-focused gateway, REST, prefix, slash, and event validation
- `lua-scripting-bot/`: Dorm + SQLite-backed saved Lua scripts with slash management and prefix execution

Each example builds its executable into its own directory:

- `examples/basic-bot/basic-bot`
- `examples/plugin-bot/plugin-bot`
- `examples/full-bot/full-bot`
- `examples/test-bot/test-bot`
- `examples/lua-scripting-bot/lua-scripting-bot`

## Run

```sh
cd examples/basic-bot && dub run
cd examples/plugin-bot && dub run
cd examples/full-bot && dub run
cd examples/test-bot && dub run
cd examples/lua-scripting-bot && dub run
```

The consoles load shared environment values from `examples/.env` and `examples/.env.local`.

Accepted token variables for the examples:

- `DISCORD_TOKEN`
- `TOKEN`
- `BOT_OWNER_ID` or `OWNER_ID` for the owner-only Lua eval command in `plugin-bot`
- `PLUGINS_DIR` to override the default plugin directory used by `plugin-bot`
- `TEST_CHANNEL_ID` to let `test-bot` send a startup validation message after `READY`
