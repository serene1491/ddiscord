# Basic Bot

This console shows the minimum runnable `ddiscord` setup:

- one prefix command
- one slash command
- one hybrid command
- a live gateway session

## Run

```sh
cd examples/start-bot
dub run
```

It loads the shared environment from `../.env` and `../.env.local`.

Try these commands after startup:

- `!ping`
- `!roll`
- `/info`
- `/roll`
