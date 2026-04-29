# ddiscord Philosophy

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

`ddiscord` is being shaped as a production-grade runtime, not a toy wrapper.

## Principles

- Stability first: predictable behavior under load matters more than novelty.
- Typed by default: runtime string dispatch is minimized in favor of typed events, contexts, and models.
- Explicit failure handling: errors are surfaced with context and actionable hints.
- Backpressure over crashes: bounded queues and safe drop policies are preferred over unbounded growth.
- Modular design: high-churn logic should be split into focused modules to keep change risk low.

## Production Direction

- Keep REST and gateway behavior resilient (`retry`, `rate-limit`, and reconnection safety).
- Expand coverage where real bots need it most (events, commands, interactions, observability).
- Treat docs and runnable examples as first-class API contracts.
- Prioritize ergonomics that scale to large bots: fluent contexts, registration filters, and strong defaults.

## Performance Posture

- Favor low-allocation hot paths in dispatch and command execution loops.
- Expose runtime telemetry so operators can tune limits without forking internals.
- Keep abstractions shallow enough that advanced users can still reason about costs.
