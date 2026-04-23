# Plugin Bot

This console demonstrates the Lua and plugin side of `ddiscord`:

- file-based Lua plugin loading
- owner-only Lua eval from a command
- host APIs exposed with `@LuaExpose`

## Run

```sh
cd examples/plugin-bot
dub run
```

It loads the shared token from `../.env` and reads plugins from `./plugins` by default.
For production-style hardening, this console can toggle:
`allowLoosePlugins`, `allowPluginEntrypointEscape`, and `requireExplicitPluginPermissions`.

Useful things to try:

- `!plugin-status`
- `!eval return author().username`
- `!eval send("hello from lua")`

The bundled `counter` plugin demonstrates host APIs available from Lua:

- `state_get(key)` / `state_set(key, value)` / `state_has(key)` / `state_del(key)`
- `log_info(message)` / `log_warn(message)` / `log_error(message)`
- `plugin_name()` / `plugin_version()` / `plugin_api_version()` / `plugin_entrypoint()` / `plugin_sandbox()`
