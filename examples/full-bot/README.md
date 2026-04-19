# Full Bot

This console pulls together the higher-level pieces of the library:

- hybrid commands
- permission checks
- rate limiting
- scoped state
- components V2 payloads

## Run

```sh
cd examples/full-bot
dub run
```

It loads the shared token from `../.env`.

Useful things to try:

- `!counter`
- `!dashboard`
- `/greet`
