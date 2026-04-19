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

Useful things to try:

- `!plugin-status`
- `!eval return author().username`
- `!eval send("hello from lua")`
