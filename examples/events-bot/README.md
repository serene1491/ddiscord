# Events Bot

This console focuses on typed event handling.

It demonstrates:

- `@Event` handlers for `READY`, message create, and command outcome events
- `client.registerAllCommands()` wiring commands and events together
- a small hybrid command to trigger event flow

## Run

```sh
cd examples/events-bot
dub run
```

Try:

- `!ping-events`
- `/ping-events`
- normal chat messages to see message-create logs
