# Start Bot

This console shows the minimum runnable `ddiscord` setup.

For a normal D project, install the library directly with:

```sh
dub add ddiscord
```

This example directory exists when you want a runnable repository checkout instead of adding the
dependency to an existing project.

It reads shared env values from `../.env` and `../.env.local`.

## Run

```sh
cd examples/start-bot
dub run
```
