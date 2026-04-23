# Client Guide

`Client` is the runtime hub of `ddiscord`. This guide was split into focused pages to keep
maintenance easier and reduce page size.

Use these sections:

- [Client Config and Lifecycle](client-config-and-lifecycle.md)
- [Registration and Events](client-registration-and-events.md)
- [Built-in Help and Errors](client-help-and-errors.md)
- [REST Shortcuts and Command Context](client-rest-and-context.md)

Quick mental model:

- `Client` owns REST, gateway, commands, event dispatch, cache/state/services, tasks, plugins, and scripting.
- `run()` performs startup/auth/sync/loop activation.
- `wait()` blocks the process; `stop()` shuts down cleanly.
