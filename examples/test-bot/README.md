# Test Bot

This console is the integration-focused validation bot for `ddiscord`.

It exercises:

- gateway startup through `READY` and `RESUMED`
- command sync and manifest update checks
- startup REST checks (`users`, `commands`, optional `guilds`, `members`, `roles`, `channels`)
- message create event handling
- prefix commands
- slash commands
- context menu commands
- Components V2 message flow and button interaction callbacks
- reply/send flows
- optional startup REST send to a configured channel

## Run

```sh
cd examples/test-bot
dub run
```

It loads the shared environment from `../.env` and `../.env.local`.

Optional environment values:

- `TEST_CHANNEL_ID` to send a startup validation message after `READY`
- `TEST_SERVER_ID` to run additional guild/member/roles checks after `READY`
- `BOT_PREFIX` to override the default `!`
- `TEST_BOT_RUN_SECONDS` to stop the bot automatically after N seconds (`0` = keep running)

Useful things to try after startup:

- `!ping`
- `!roll`
- `!echo hello`
- `!dashboard`
- `Inspect Message` (message context menu)
- `Inspect User` (user context menu)
- `/status`
- `/echo hello`
