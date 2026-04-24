# Changelog

All notable changes to `ddiscord` should be documented in this file.

## [0.3.2]

### Added

- Coroutine-aware Lua runtime stepping APIs: `evalStep*`, `evalFileStep*`, `callStep*`, `resumeStep*`, `canResume`, and `cancelSuspension`.
- Auto-resume Lua helpers: `evalAutoResume*` and `callAutoResume*` for host-driven continuation flows.
- New `@LuaApi(...)` UDA for namespaced API tables (default `api`) with global-export control.
- Command-route shorthand UDAs: `@SlashCommand(...)` and `@PrefixCommand(...)`.
- Application-command install/context UDAs: `@CommandInstallTypes(...)`, `@CommandContexts(...)`, `@GuildInstalled`, `@UserInstalled`, `@GuildContextOnly`, `@BotDmOnly`, `@PrivateChannelOnly`, `@UserInstalledDmOnly`, and `@UserInstalledPrivateOnly`.
- Value-style Lua exports through `LuaExposeMode.Value`, enabling direct access patterns like `author.username` in scripts.
- Value-export mutability policies via `LuaValueMutability` (`Auto`, `Mutable`, `ReadOnly`) with automatic readonly inference for `const/immutable LuaTable` exports.
- Lua export introspection helpers: `hasValue`, `callableExportNames`, and `valueExportNames`.
- Lua value-export introspection helper `valueExportReadOnly(name)` and startup validation for duplicate export names.
- Coroutine payload inspection helpers: `yieldedSignalKind(...)` and `yieldedTableField(...)`.
- `resumeStepTyped` / `resumeStep` overloads that accept a single `LuaValue` without manual array wrapping.
- Multipart form-data helper module (`ddiscord.core.http.multipart`) for binary upload payloads.
- Message attachment payload support via `MessageCreate.attach(...)` / `attachBytes(...)`.
- REST support for multipart attachments in channel messages and interaction responses.
- Command-context file helpers: `sendFile(...)`, `followupFile(...)`, and `editFile(...)`.
- Message lifecycle REST endpoints: `messages.edit(...)`, `messages.delete(...)`, and `messages.bulkDelete(...)`.
- Message utility REST endpoints: `messages.crosspost(...)`, `messages.pin(...)`, `messages.unpin(...)`, and `messages.pins(...)`.
- Command-context message-operation helpers: `ctx.messageRef`, `ctx.react(...)`, `ctx.unreact(...)`, `ctx.pin(...)`, `ctx.unpin(...)`, `ctx.crosspost(...)`, `ctx.editMessage(...)`, and `ctx.deleteMessage(...)`.
- Reaction REST endpoints: `reactions.add(...)`, `reactions.removeSelf(...)`, `reactions.removeUser(...)`, `reactions.clear(...)`, and `reactions.clearEmoji(...)`.
- Guild moderation REST endpoints: `guilds.timeoutMember(...)`, `guilds.clearMemberTimeout(...)`, `guilds.kick(...)`, `guilds.ban(...)`, and `guilds.unban(...)`.
- Optional audit-log reason support on moderation endpoints (`timeoutMember`, `clearMemberTimeout`, `kick`, `ban`, and `unban`).
- Thread REST endpoints: `threads.createFromMessage(...)`, `threads.create(...)`, `threads.join(...)`, `threads.leave(...)`, and `threads.archive(...)`.
- Webhook execution REST endpoint: `webhooks.execute(...)` with support for `thread_id`.
- New runnable console example: `examples/rest-ops-bot`.
- REST retry controls for `429` handling (`autoRetryRateLimits`, `maxRateLimitRetries`) in `RestClientConfig`.
- Rate-limit parser now handles case-insensitive global headers/scope values (`TRUE` / `GLOBAL`).
- Gateway dispatch coverage for `GUILD_CREATE` and `GUILD_DELETE` with typed callbacks in `GatewayClient`.
- Client-level emission of `GuildCreateEvent` and `GuildDeleteEvent` with typed event contexts.
- Gateway dispatch coverage for `GUILD_MEMBER_REMOVE`, `CHANNEL_CREATE`, `CHANNEL_UPDATE`, `CHANNEL_DELETE`, `MESSAGE_UPDATE`, `MESSAGE_DELETE`, and `TYPING_START`.
- Client-level emission of `GuildMemberRemoveEvent`, `ChannelCreateEvent`, `ChannelUpdateEvent`, `ChannelDeleteEvent`, `MessageUpdateEvent`, `MessageDeleteEvent`, and `TypingStartEvent` with typed contexts.
- Gateway dispatch coverage for `CHANNEL_PINS_UPDATE`, `MESSAGE_REACTION_ADD`, `MESSAGE_REACTION_REMOVE`, `MESSAGE_REACTION_REMOVE_ALL`, `MESSAGE_REACTION_REMOVE_EMOJI`, `GUILD_ROLE_CREATE`, `GUILD_ROLE_UPDATE`, `GUILD_ROLE_DELETE`, `INVITE_CREATE`, `INVITE_DELETE`, `WEBHOOKS_UPDATE`, `THREAD_CREATE`, `THREAD_UPDATE`, and `THREAD_DELETE`.
- Client-level emission/context support for the same event family (`ChannelPinsUpdateEvent`, reaction events, guild-role events, invite events, `WebhooksUpdateEvent`, and thread events).
- Gateway dispatch coverage for `GUILD_BAN_ADD` and `GUILD_BAN_REMOVE` with typed callbacks in `GatewayClient`.
- Client-level emission/context support for `GuildBanAddEvent` and `GuildBanRemoveEvent`.
- Cache eviction APIs (`evictUser`, `evictChannel`, `evictGuild`, `evictRole`, `evictMessage`) for safer runtime consistency flows.
- Presence model parsing helpers (`statusFromDiscord`, `activityTypeFromDiscord`) and activity JSON round-trip helpers.
- Command error behavior presets `CommandErrorBehavior.nonVerbose()` and `CommandErrorBehavior.verbose()`.
- New command UDAs: `@UseMiddleware("name")`, `@GuildOnly`, `@DirectMessageOnly`, and `@BotModule("name")`.
- Command-policy aliases for API ergonomics: `@RequirePermission(...)` and `@CooldownRate(...)`.
- Command middleware runtime hooks: `client.useMiddleware(...)` and `client.registerMiddleware(...)`, including built-in names `guild_only`, `dm_only`, and `owner_only`.
- Lua runtime capability-denial hints when scripts call globals filtered out by permissions.

### Changed

- `LuaRuntime.eval*` and `LuaRuntime.call*` now run on coroutine-backed execution and return explicit guidance when scripts yield unexpectedly.
- `@LuaApi(...)` no longer injects Lua helper functions automatically; scripts now use native `coroutine.yield(...)` patterns explicitly.
- Application-command sync now serializes/parses Discord `integration_types` and `contexts` metadata.
- `@GuildOnly` and `@DirectMessageOnly` are now projected to application command `contexts` automatically when no explicit context UDA is provided.
- Guild delete gateway handling now evicts guild cache entries when Discord indicates a true removal (`unavailable=false`).
- Channel and message delete gateway handling now evict cache entries during runtime dispatch processing.
- Gateway/event typing surface now covers startup lifecycle plus core guild/presence/member dispatches.
- Task scheduler now validates invalid timing inputs earlier (non-empty label, non-negative delay, positive recurring/cron intervals, non-null callback).
- Scheduler callbacks now isolate `Throwable` failures so the scheduler keeps running even when callbacks throw beyond `Exception`.
- Dispatch and task worker loops now isolate unhandled `Throwable` errors and log them instead of terminating worker threads.
- REST guardrails now validate moderation/thread arguments earlier (timeout range, ban delete window, thread type/name, auto-archive durations) for safer runtime behavior.
- REST route hardening now validates empty reaction emojis and rejects empty webhook/interaction tokens before sending requests.
- Audit-log reason headers are now sanitized and URL-encoded before sending `X-Audit-Log-Reason`.

### Fixed

- On POSIX targets, the HTTP layer now ignores `SIGPIPE` so transient broken socket writes surface as normal transport errors instead of terminating the process (`exit code -13`).

## [0.3.1]

### Added

- Gateway dispatch coverage for `GUILD_MEMBER_ADD` and `PRESENCE_UPDATE` with typed payload parsing in `GatewayClient`.
- Client-level emission of `GuildMemberAddEvent` and gateway-driven `PresenceUpdateEvent`, both with typed event contexts.
- Optional sampled logging for unhandled gateway dispatch event names (`logUnhandledGatewayDispatchEvents`, `gatewayUnhandledDispatchLogEvery`).

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
- Production philosophy document at `manual/philosophy.md`.
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
