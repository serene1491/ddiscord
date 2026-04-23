# Examples

`ddiscord` ships some runnable console examples as separate DUB packages. Try them:

- `start-bot/`: smallest env-driven startup flow
- `basic-bot/`: prefix + slash commands with a live Discord session
- `basic-bot/` also shows `@Event` registration through `registerAllCommands!`
- `events-bot/`: focused typed event handling (`READY`, message create, command outcomes)
- `interactions-bot/`: button + modal interaction flow
- `services-bot/`: `@Stateful` command groups with `@Inject` service usage
- `tasks-bot/`: one-shot and recurring scheduler usage from real commands
- `plugin-bot/`: plugin descriptors, service injection, `@LuaExpose`, and owner-only command flow
- `full-bot/`: permissions, rate limits, state, components, prefix + slash orchestration
- `test-bot/`: integration-focused gateway, REST, prefix, slash, and event validation
- `help-bot/`: built-in help customization, categories, hidden commands, and user-facing error behavior
- `filter-bot/`: module auto-registration with category filters
- `lua-scripting-bot/`: Dorm + SQLite-backed saved Lua scripts with slash management and prefix execution
- `rest-ops-bot/`: reactions, moderation (with audit reasons), threads, webhook execution, and message lifecycle/pin/crosspost REST usage

Most examples now use module-local registration helpers such as `client.registerCommands();` or
`client.registerAllCommands();`, so the console `main()` stays short even as commands grow.
They also use `GatewayIntent` presets like `GatewayIntent.GuildTextCommands` to keep startup
configuration concise.

Each example builds its executable into its own directory:

- `examples/start-bot/start-bot`
- `examples/basic-bot/basic-bot`
- `examples/events-bot/events-bot`
- `examples/interactions-bot/interactions-bot`
- `examples/services-bot/services-bot`
- `examples/tasks-bot/tasks-bot`
- `examples/plugin-bot/plugin-bot`
- `examples/full-bot/full-bot`
- `examples/test-bot/test-bot`
- `examples/help-bot/help-bot`
- `examples/filter-bot/filter-bot`
- `examples/lua-scripting-bot/lua-scripting-bot`
- `examples/rest-ops-bot/rest-ops-bot`

## Run

```sh
cd examples/start-bot && dub run
cd examples/basic-bot && dub run
cd examples/events-bot && dub run
cd examples/interactions-bot && dub run
cd examples/services-bot && dub run
cd examples/tasks-bot && dub run
cd examples/plugin-bot && dub run
cd examples/full-bot && dub run
cd examples/test-bot && dub run
cd examples/help-bot && dub run
cd examples/filter-bot && dub run
cd examples/lua-scripting-bot && dub run
cd examples/rest-ops-bot && dub run
```

The consoles load shared environment values from `examples/.env` and `examples/.env.local`.

Accepted token variables for the examples:

- `DISCORD_TOKEN`
- `TOKEN`
- `BOT_PREFIX` for prefix-based examples
- `GREETING_PREFIX` to customize the greeting text used by `services-bot`
- `BOT_OWNER_ID` or `OWNER_ID` for the owner-only Lua eval command in `plugin-bot`
- `PLUGINS_DIR` to override the default plugin directory used by `plugin-bot`
- `TEST_CHANNEL_ID` to let `test-bot` send a startup validation message after `READY`
- `TEST_SERVER_ID` to let `test-bot` run extra guild/member/roles startup checks
