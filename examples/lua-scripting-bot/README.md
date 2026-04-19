# Lua Scripting Bot

This example keeps a small library of user and server Lua scripts in SQLite through Dorm.

It demonstrates:

- slash management commands for saving, showing, updating, listing, and deleting scripts
- a hybrid `/run` / `!run` command for executing a saved script by name
- direct prefix execution of saved scripts like `!hello`
- real Lua runtime execution through `ddiscord.scripting`
- persistent storage in `scripts.sqlite3`

## Run

```sh
cd examples/lua-scripting-bot
dub run
```

The example loads Discord configuration from `examples/.env` and `examples/.env.local`.

On the first run it creates the SQLite schema with Dorm migrations, then starts the bot normally.

## Commands

- `/save-script name:<name> scope:<user|server> source:<lua>`
- `/show-script name:<name> scope:<user|server>`
- `/update-script name:<name> scope:<user|server> source:<lua>`
- `/delete-script name:<name> scope:<user|server>`
- `/list-scripts`
- `/run name:<name> [args]`
- `!run <name> [args]`
- `!<saved-script-name> [args]`

## Example Script

```lua
reply("hello from " .. script_name())
```
