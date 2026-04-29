# Client Guide

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

`Client` is the main app object in `ddiscord`. This guide was split into focused pages to keep
maintenance simpler and reduce page size.

Use these sections:

- [Bot Structures](bot-structures.md)
- [Client Config and Lifecycle](client-config-and-lifecycle.md)
- [Registration and Events](client-registration-and-events.md)
- [Built-in Help and Errors](client-help-and-errors.md)
- [REST Shortcuts and Command Context](client-rest-and-context.md)

When to read each:

1. Starting a new bot: [Client Config and Lifecycle](client-config-and-lifecycle.md)
2. Wiring handlers and startup flow: [Registration and Events](client-registration-and-events.md)
3. Improving UX around failures/help: [Built-in Help and Errors](client-help-and-errors.md)
4. Advanced command response patterns: [REST Shortcuts and Command Context](client-rest-and-context.md)

Quick mental model:

- `Client` owns REST, gateway, commands, events, cache/state/services, tasks, plugins, and scripting.
- `run()` performs startup/auth/sync/loop activation.
- `wait()` blocks the process; `stop()` shuts down cleanly.

Related guides:

- [Commands Guide](commands.md)
- [Interactions Guide](interactions.md)
- [Troubleshooting](troubleshooting.md)
