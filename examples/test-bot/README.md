# Test Bot

This console is the integration-focused validation bot for `ddiscord`.

It exercises:

- gateway startup through `READY` and `RESUMED`
- command sync and manifest update checks
- message create event handling
- prefix commands
- slash commands
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
- `BOT_PREFIX` to override the default `!`

Useful things to try after startup:

- `!ping`
- `!roll`
- `!echo hello`
- `/status`
- `/echo hello`
