# Changelog

All notable changes to `ddiscord` should be documented in this file.

## [0.3.1]

### Fixed

- Reduced noisy unittest output by disabling intentional dispatch-overflow warning logs in the queue-boundary client test.
- Hardened REST rate-limit retry parsing to handle multiple `retry_after` JSON types safely and ignore invalid/non-positive delays.
- Narrowed several broad conversion catches to typed conversion exceptions in help/env/scripting parsing paths.
- Improved gateway diagnostics by logging explicit heartbeat-send and graceful-close failures before reconnect/cleanup.

## [0.3.0]

### Added

- Module-local auto-registration through `client.registerCommands()` and `client.registerAllCommands()`.
- `CommandRegistrationFilter` to include or exclude modules, owners, names, categories, events, and plugins.
- Built-in `help` command with pagination and configurable rendering.
- Configurable command error behavior (`CommandErrorBehavior`) for unknown commands, argument issues, and handler failures.
- Help-oriented command metadata via `@CommandCategory` and `@HideFromHelp`.
- Expanded runnable examples with `help-bot` and `filter-bot`.
- `ILogger` and `NullLogger` in `ddiscord.logging` for pluggable logging integrations.
- Dispatch queue backpressure controls in `ClientConfig` (`maxDispatchQueueSize`, `dropOldestDispatchOnOverflow`, `dispatchOverflowLogEvery`).
- `client.dispatchQueueHealth` runtime telemetry for queued/peak/dropped dispatch tracking.
- Production philosophy document at `docs/philosophy.md`.
- Real `client.uptime` tracking with elapsed milliseconds and human-readable formatting.
- Lua plugin host API additions: `state_has`, `state_del`, `log_info`, `log_warn`, `log_error`.
- Lua plugin context exports: `plugin_version`, `plugin_api_version`, `plugin_entrypoint`, and `plugin_sandbox`.
- Typed Lua runtime call/eval methods (`evalTyped`, `evalFileTyped`, `callTyped`) for richer host integrations.
- File-based Lua plugins without declared permissions now default to a minimal untrusted capability set (`context.read`).
- Gateway intent presets (`GuildTextCommands`, `DefaultCommandBot`, `NonPrivileged`, etc.) to simplify common setup.

### Changed

- Built-in help now respects visibility rules and command metadata (owner-only, permissions, hidden/category tags).
- Route-specific command contexts and typed event contexts are now used consistently across runtime and examples.
- `test-bot` startup flow now performs richer REST validation checks, including optional guild-scoped checks.
- Plugin loading now enforces safer manifest entrypoint resolution by default (no path escape outside plugin directory).
- `ClientConfig` now exposes plugin hardening controls (`allowLoosePlugins`, `allowPluginEntrypointEscape`, `requireExplicitPluginPermissions`).

### Fixed

- Corrected Components V2 serialization to emit Discord-compatible integer component types and payload shapes.
- Fixed message component serialization in `MessageCreate` so complex component payloads no longer degrade into unknown types.
- Improved default user-facing command failure messages to stay concise while still giving actionable hints.
- Built-in help filtering now matches command text case-insensitively.
- Updated default Discord `User-Agent` values to the real repository/version and centralized them in `ddiscord.util.identity`.
- Added automatic retry with exponential backoff for transient REST failures (`5xx`, timeout, transport), configurable through `RestClientConfig`.

### Refactored

- Split large command/client type surfaces into dedicated modules:
  `ddiscord.command_types` and `ddiscord.client_types`.
- Split client dispatch queue internals into `ddiscord.client_queue` to reduce `client.d` responsibility.
- Split runtime helpers into `ddiscord.client_runtime` and registration filter matching into `ddiscord.client_filters`.
- Split prefix-text parsing helpers into `ddiscord.client_text` to keep `client.d` focused on orchestration.

### Documentation

- Updated README/examples/client docs for auto-registration filters, built-in help/error behavior, and new runnable consoles.
- Expanded runnable examples with focused event, interaction, services, and task scheduler consoles.
