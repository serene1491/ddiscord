# Services Bot

This console focuses on service injection for stateful command groups.

It demonstrates:

- `@Stateful` command group
- `@Inject` service usage inside handlers
- small per-user state tracking alongside injected logic

## Run

```sh
cd examples/services-bot
dub run
```

Try:

- `!hello-service`
- `/hello-service target:world`
- `!hello-count`
