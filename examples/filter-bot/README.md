# Filter Bot

This console demonstrates module auto-registration filters.

It registers only commands categorized as `Public` while keeping `@Event` handlers wired through
`registerAllCommands(filter)`.

## Run

```sh
cd examples/filter-bot
dub run
```
