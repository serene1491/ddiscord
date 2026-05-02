# Changelog

All notable changes to `ddiscord` should be documented in this file.

## [Unreleased]

### Added

- `scripts/release_preflight.sh` to run a release preflight gate (`dub test` plus
  `./scripts/test.sh --bot-seconds <N>`) with explicit, repeatable checks for 1.0-track work.
- `scripts/soak_idle_recovery.sh` to run a token-backed timed soak flow with an explicit
  post-idle probe window for first-request-after-idle validation.
- Shared internal backoff utilities in `source/ddiscord/core/backoff.d` for capped exponential
  delay growth and bounded jitter injection.
- Central Discord API error parsing helpers in `source/ddiscord/util/discord_api_error.d`
  (`extractDiscordApiErrorCode`, `hasDiscordApiErrorCode`, and
  `discordApiMessageContains`) with dedicated unit coverage.
- StringSelect and StringSelectOption builders.

### Fixed

- Command failure classification now treats Discord permission-denied API responses
  (`Missing Permissions` / `50013`, `Missing Access` / `50001`) as policy denials, improving
  user-facing failure routing and log semantics.
- Interaction failure hints now explicitly explain Discord `10062` ("Unknown interaction")
  as token-expiry timing, with guidance to defer first and follow up.
- Interaction callback fallback (`40060`) detection now uses structured Discord error-code/message
  parsing instead of brittle string fragments, reducing false negatives across wrapped error formats.
- `examples/test-bot` timed mode now performs explicit client shutdown (`stop` + `wait`) before
  exiting, preventing stuck live runs during preflight/soak automation.

### Changed

- Command execution logging now downgrades expected user/policy failures (permission/policy/argument)
  from error-level to warning-level, reducing false-positive operational noise.
- Failure-message delivery errors caused by expected Discord state/permission conditions
  (for example `50013`, `50001`, `10003`, `10062`, `10015`) now log at debug level instead of
  error level, so secondary delivery failures no longer obscure primary command failures.
- `scripts/test.sh` now accepts `--idle-probe-after <seconds>` and passes
  `TEST_BOT_IDLE_PROBE_AFTER_SECONDS` through to `examples/test-bot`.
- `scripts/test.sh` now honors `TEST_BOT_SKIP_RUN=1` to skip live `test-bot` execution even when
  tokens are available, enabling deterministic build-only preflight runs.
- `examples/test-bot` now supports a timed post-idle `users.me` probe to surface
  stale-connection/first-request-after-idle regressions during automated smoke runs.
- Script env loading now resolves `.env`/`.env.local` from both `scripts/` and `examples/`,
  reducing false token-missing errors when runtime credentials are stored in shared example env files.
- `scripts/release_preflight.sh` now supports an optional soak gate via `RELEASE_RUN_SOAK=1`,
  with configurable soak timings (`RELEASE_SOAK_SECONDS`,
  `RELEASE_SOAK_IDLE_PROBE_AFTER_SECONDS`).

### Refactored

- REST, HTTP transport, and gateway reconnect paths now reuse shared backoff helpers instead of
  keeping duplicated per-module implementations, reducing drift risk while preserving current
  retry/reconnect behavior.
- Command failure routing and expected-delivery-error detection now consume the shared Discord API
  error parser, removing duplicated code-fragment checks and reducing classifier drift risk.
- Dispatch queue overflow logs now include `droppedSinceLastReport` counters, improving burst-load
  observability without changing queue drop behavior.

## [0.4.0]

### Added

- Scripting hardening in `LuaRuntimeLimits` with a new `maxInstructions` cap (disabled by
  default when set to `0`) and dedicated unittest coverage for instruction-limit failures.

### Fixed

- Lua runtime instruction limiting now remains effective across `yield/resume` cycles instead
  of allowing reset-based bypass patterns.
- Lua runtime memory accounting now uses overflow-safe byte aggregation before enforcing
  `maxMemoryBytes`.
- Message-component event UX now exposes direct selection values on
  `MessageComponentEventContext.values` (and mirrors submitted components) so dropdown flows are
  consumable without digging into raw interaction payload fields.
- Command error rendering now keeps actionable Discord API validation details (including
  `Invalid Form Body` payloads) visible to users instead of falling back to a generic
  `"The command could not be completed."` message.
- HTTP request failures that surface as `RequestException` now recover embedded status codes
  (including `422`) and preserve API payload detail instead of being downgraded to transport-only
  failures.
- Transport failures with `status code 0` now include concrete exception-class detail when no
  nested message is available, improving network diagnosis.
- Client shutdown coordination now serializes thread-join phases shared by `wait()` and `stop()`,
  reducing join-race risk during concurrent shutdown requests.
- `scripts/test.sh` now skips the live `test-bot` execution when no shell token
  (`DISCORD_TOKEN`/`TOKEN`) is present, while still building all examples; set
  `TEST_BOT_FORCE_RUN=1` to force the live run step.
- Interaction callback recovery now detects Discord `40060` ("Interaction has already been
  acknowledged.") and automatically falls back to follow-up responses instead of failing
  command execution on post-idle callback races.
- `rest.interactions.send(...)` now applies the same `40060` recovery when used directly
  (outside command-context helpers), reducing post-idle callback races in custom interaction flows.
- HTTP status handling now treats bodyless `4xx` responses as transient transport failures,
  allowing REST retry logic to recover from stale keep-alive/proxy edge cases that often appear
  on the first request after idle periods.
- Interaction callback routes for autocomplete and modal responses now URL-encode interaction
  tokens consistently, preventing malformed callback paths when tokens contain reserved characters.
- REST and HTTP retry loops now only auto-retry transient server/transport failures for
  idempotent methods (`GET`, `PUT`, `DELETE`), reducing duplicate side effects for write routes.
- HTTP error diagnostics now redact sensitive interaction/webhook token path segments from logged
  request URLs while preserving route context.
- Gateway reconnect and REST/HTTP transient retry backoff now include bounded jitter to reduce
  synchronized reconnect/retry bursts across shards or process pools.
- REST global pacing now proactively spaces outbound requests using the configured Discord
  global request budget instead of relying only on reactive `429` handling.

### Refactored

- Lua VM lifecycle flow was decomposed into focused internal helpers for runtime guard
  activation/deactivation, coroutine outcome handling (`yield`/`complete`/`error`), and
  hook/cleanup setup while preserving existing scripting behavior.

### Changed

- Manual Lua documentation now includes a dedicated "Lua VM lifecycle and runtime guard flow"
  section covering thread lifecycle stages, resume outcomes, and guard enforcement behavior.

## [0.3.5]

### Added

- Repository helper script `scripts/test.sh` to build the library, build every runnable
  example project, and execute `examples/test-bot` with full runtime logs.
- Optional timed shutdown for `examples/test-bot` via `TEST_BOT_RUN_SECONDS`, enabling
  non-interactive smoke runs while preserving continuous mode with `0`.

### Changed

- Examples documentation now includes the unified build-and-run helper flow and timed
  `test-bot` execution controls.

### Fixed

- `examples/test-bot` now validates `roll` command input (`sides >= 2`) instead of allowing
  invalid random ranges.
- `examples/test-bot` now handles invalid `TEST_BOT_RUN_SECONDS` values gracefully by
  reporting the issue and continuing in continuous mode.

### Refactored

- Continued large-file decomposition for internal maintainability:
  - extracted REST public support types into `source/ddiscord/rest_types.d`
  - extracted REST payload types into `source/ddiscord/rest_payloads.d`
  - extracted REST internal stores into `source/ddiscord/rest_internal.d`
  - extracted client runtime support types into `source/ddiscord/client_runtime_types.d`
  - extracted command task and policy surfaces into
    `source/ddiscord/command_task_types.d` and `source/ddiscord/command_policy_types.d`
- Organized support modules into clearer subdirectories while preserving compatibility:
  - `source/ddiscord/client_support/types.d` and `source/ddiscord/client_support/runtime_types.d`
  - `source/ddiscord/rest_support/types.d`, `source/ddiscord/rest_support/payloads.d`,
    and `source/ddiscord/rest_support/internal.d`
  - `source/ddiscord/commands/task_types.d` and `source/ddiscord/commands/policy_types.d`
  - legacy flat modules kept as import shims to avoid breaking downstream imports
- `source/ddiscord/scripting/lua54.d` now relies on `dub.json` library linkage without a
  duplicated `pragma(lib, ...)` declaration.

## [0.3.4]

### Changed

- `CommandErrorBehavior.surfaceUnknownCommand = false` now also reduces unknown-command logging
  noise by downgrading those failures to debug logs.
- `examples/lua-scripting-bot` now accepts dynamic Lua values in host APIs:
  `reply(...)` and `log(...)` now accept `LuaValue` and render via `toDisplayString()`.
  between slash and prefix flows.
- `examples/lua-scripting-bot` Lua replies now use native `ctx.reply(...)`, and script execution no
  longer emits redundant `"<script> completed."` outputs when no explicit content is returned.
- Example startup logging was streamlined across runnable consoles by removing redundant
  `"[...] synced commands"` lines, and the recurring heartbeat log noise in `tasks-bot` was reduced.
- Documentation wording was polished across key manual pages with simpler terms.

### Fixed

- Lua host argument binding now accepts `LuaValue` parameters directly in `@LuaExpose` methods,
  fixing false "incompatible type" failures for APIs that intentionally consume dynamic Lua input.
- Prefix command parsing now preserves raw multiline content for trailing `@Greedy string`
  parameters instead of tokenizing/flattening whitespace, fixing script payload corruption.
- Prefix parsing helpers were unified under `ddiscord.client_text`, including a shared
  `parsePrefixInvocation(...)` utility used by examples to avoid duplicated parser logic.

## [0.3.3]

### Added

- REST coverage expansion for message retrieval and reactions:
  `messages.get(...)`, `messages.getMany(...)`, `messages.getReactions(...)`, and
  `messages.deleteAllReactions(...)`.
- Advanced escape-hatch REST surface via `rest.raw` with typed helpers:
  `request(...)`, `requestJson(...)`, `get(...)`, `delete_(...)`, `postJson(...)`,
  `putJson(...)`, and `patchJson(...)`.
- Gateway dispatch coverage for `GUILD_UPDATE`, `USER_UPDATE`, `MESSAGE_DELETE_BULK`,
  `VOICE_STATE_UPDATE`, and `VOICE_SERVER_UPDATE`.
- New typed client events and contexts for guild/user updates, bulk message deletes,
  voice state/server updates, and raw gateway dispatch payload access.
- Lua runtime safety controls through `LuaRuntimeLimits` (execution timeout, memory cap,
  and instruction checkpoint interval) with runtime limit enforcement.

### Changed

- Gateway dispatch flow now emits a typed raw-dispatch event for every dispatch name so
  unsupported/new Discord events can still be consumed immediately without waiting for
  dedicated wrappers.
- `rest.raw` now normalizes route paths and rejects absolute URLs, preventing accidental
  token forwarding outside Discord API routes.
- Raw REST auto-generated rate-limit keys now ignore query strings by default for better
  bucket reuse and steadier retry behavior.
- Lua runtime default limits were tuned for production usability while preserving guardrails:
  `2s` execution timeout, `32MB` memory limit, and `25k` instruction check interval.

### Fixed

- Lua runtime hook activation now restores previous hook context correctly in nested flows.
- Added unittest coverage for raw route normalization/security and Lua limit enforcement
  failure paths.


## [0.3.2.1]

### Added

- HTTP error metadata now includes typed retry timing via `HttpError.retryAfter` (`Nullable!Duration`).
- `HttpClientConfig` gained retry controls for transport-level resilience: `autoRetryRateLimits`, `maxRateLimitRetries`, `autoRetryServerErrors`, `maxServerErrorRetries`, `retryBaseDelay`, and `maxRetryDelay`.
- HTTP client retry parsing now reads both `Retry-After` headers and JSON `retry_after` payload values.
- New HTTP-client unittest coverage for retry-delay parsing and automatic retry behavior (rate-limit and server-error paths).
- Gateway dispatch internals now use a registered handler table (`eventName -> DispatchHandler`) instead of a monolithic branch chain.
- `GatewayClient` now supports typed multi-listener subscriptions via `on!T(...)`, `once!T(...)`, and `off!T(...)`.
- New typed gateway payload marker `GatewayResumedInfo` for `RESUMED` lifecycle subscriptions.
- New event-specific typed gateway wrappers for disambiguating shared model payloads:
  `GatewayMessageCreateEvent`, `GatewayMessageUpdateEvent`, `GatewayChannelCreateEvent`,
  `GatewayChannelUpdateEvent`, `GatewayChannelDeleteEvent`, `GatewayThreadCreateEvent`,
  and `GatewayThreadUpdateEvent`.
- Command-context UX APIs that return response payloads when available:
  `CommandContext.sendMessage(...)`, `replyMessage(...)`, `followupMessage(...)`, and `editResponse(...)`.
- Command-context UX APIs that always resolve a concrete response payload:
  `CommandContext.sendMessageResolved(...)` plus route aliases
  `PrefixContext.respondMessageResolved(...)`, `SlashContext.respondMessageResolved(...)`,
  and `HybridContext.respondMessageResolved(...)`.
- Route-context response helpers that preserve payload access:
  `PrefixContext.respondMessage(...)`, `SlashContext.respondMessage(...)`, and
  `HybridContext.respondMessage(...)`.
- Interaction REST helper for fetching the original callback response:
  `rest.interactions.fetchOriginal(interactionToken)`.
- New gateway unittest coverage for typed subscription semantics (multi-listener invocation, one-shot listener removal, and explicit unsubscription).
- New gateway unittest coverage verifying that message create/update wrapper subscriptions remain independently routable while legacy `on!Message(...)` listeners still receive both payloads.
- New command-context unittest coverage for message-returning response helpers across prefix and interaction flows.
- New command-context unittest coverage for resolved-message flows, including
  interaction callback `@original` fetching and prefix-route direct creation.

### Changed

- `HttpClient.send(...)` now runs through an internal retry loop that can automatically retry `429` responses and transient server/transport failures with backoff.
- REST transport setup now explicitly disables HTTP-layer retries in `RealDiscordRest` so REST remains the single owner of retry/rate-limit orchestration.
- Gateway `READY` and `RESUMED` dispatch handling was split into dedicated handlers while preserving the same public callback API.
- Gateway dispatch handlers now also emit typed subscription payloads in parallel with legacy `onX` callback fields.
- Client shard wiring now consumes typed gateway subscriptions (`gateway.on!T(...)`) for lifecycle and selected typed dispatch payloads (`GatewayReadyInfo`, `GatewayResumedInfo`, `Guild`, `UnavailableGuild`, `Interaction`, `GatewayGuildMemberAddInfo`, `GatewayPresenceUpdateInfo`).
- Client message routing now consumes dedicated message wrapper subscriptions (`GatewayMessageCreateEvent` / `GatewayMessageUpdateEvent`) to avoid payload-type ambiguity between create and update dispatches.
- Existing `send(...)`, `reply(...)`, `followup(...)`, and `edit(...)` command-context helpers now delegate through shared message-returning implementations for more consistent behavior and error propagation.
- Gateway URL normalization now uses the shared `DiscordGatewayVersion` constant instead of a hardcoded protocol version string.
- README usage examples now document the message-returning response helpers and resolved-response interaction flow.

### Fixed

- Eliminated duplicate retry attempts when using `RestClient` over `HttpClient` by preventing stacked retry loops across both layers.

## [0.3.2]

### Added

- Coroutine-aware Lua runtime stepping APIs: `evalStep*`, `evalFileStep*`, `callStep*`, `resumeStep*`, `canResume`, and `cancelSuspension`.
- Auto-resume Lua helpers: `evalAutoResume*` and `callAutoResume*` for host-driven continuation flows.
- New `@LuaApi(...)` UDA for namespaced API tables (default `api`) with global-export control.
- Command-route shorthand UDAs: `@SlashCommand(...)` and `@PrefixCommand(...)`.
- Application-command install/context UDAs: `@CommandInstallTypes(...)`, `@CommandContexts(...)`, `@GuildInstalled`, `@UserInstalled`, `@GuildContextOnly`, `@BotDmOnly`, `@PrivateChannelOnly`, `@UserInstalledDmOnly`, and `@UserInstalledPrivateOnly`.
- Additional install/context convenience UDAs: `@DmContextOnly`, `@GuildInstalledGuildOnly`, `@UserInstalledEverywhere`, and `@InstalledEverywhere`.
- Route-specific command context aliases: `PrefixContext`, `SlashContext`, `HybridContext`, and `ContextMenuContext`.
- Typed slash autocomplete routing via `@Autocomplete!handler("option")`, including automatic callback responses in `Client.receiveInteraction(...)`.
- Route-focused fluent context helpers: `PrefixContext.respond/replyToSource`, `SlashContext.respond/respondEphemeral/deferEphemeral/thinkEphemeral`, and `HybridContext.respond`.
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
- Scheduled-task UDA `@Task(...)` with `TaskMode` (`Every`, `Delay`, `Cron`) for declarative recurring/delayed bot jobs.
- `Task` UDA payload: `Task.loop(...)`, `Task.every(...)`, `Task.delay(...)`, and `Task.cron(...)`.
- Task auto-registration APIs: `client.registerTasks(...)`, `client.registerTaskGroup!T()`, plus module scanning support in `registerAllCommands(...)`.
- Task filtering support in `CommandRegistrationFilter` (`withoutTasks`) and candidate matching.
- Client service-container shortcuts: `addService`, `addServiceFactory`, `service`, `tryService`, and `removeService`.
- Batched service registration helper: `client.addServices(...)`.
- Manual task trigger helpers: `TaskScheduler.runNow(label)` and `client.runTaskNow(label)`.
- Runtime sharding controls: `client.reshard(...)`, `client.refreshShardTopology()`, and `client.activeShardCount`.

### Changed

- `LuaRuntime.eval*` and `LuaRuntime.call*` now run on coroutine-backed execution and return explicit guidance when scripts yield unexpectedly.
- `@LuaApi(...)` no longer injects Lua helper functions automatically; scripts now use native `coroutine.yield(...)` patterns explicitly.
- Application-command sync now serializes/parses Discord `integration_types` and `contexts` metadata.
- `@GuildOnly` and `@DirectMessageOnly` are now projected to application command `contexts` automatically when no explicit context UDA is provided.
- Command registration now validates route/context signature mismatches (for example, `SlashContext` on non-slash routes) and ambiguous implicit autocomplete configuration.
- `CommandRegistry.find(...)` now uses route-specific lookup caches for prefix/slash/context-menu routes to reduce per-invocation lookup cost.
- `CommandContext` now rejects `ephemeral=true` on non-interaction routes with explicit guidance instead of silently sending invalid payload flags.
- Interaction command routing now honors Discord `data.type` (`ApplicationCommandType`) so chat-input and context-menu commands are dispatched through the correct command path.
- Stateful command-group registration now rebuilds route lookup caches once per group registration pass instead of once per member.
- Guild delete gateway handling now evicts guild cache entries when Discord indicates a true removal (`unavailable=false`).
- Channel and message delete gateway handling now evict cache entries during runtime dispatch processing.
- Gateway/event typing surface now covers startup lifecycle plus core guild/presence/member dispatches.
- Task scheduler now validates invalid timing inputs earlier (non-empty label, non-negative delay, positive recurring/cron intervals, non-null callback).
- Scheduler callbacks now isolate `Throwable` failures so the scheduler keeps running even when callbacks throw beyond `Exception`.
- Dispatch and task worker loops now isolate unhandled `Throwable` errors and log them instead of terminating worker threads.
- REST guardrails now validate moderation/thread arguments earlier (timeout range, ban delete window, thread type/name, auto-archive durations) for safer runtime behavior.
- REST route hardening now validates empty reaction emojis and rejects empty webhook/interaction tokens before sending requests.
- Audit-log reason headers are now sanitized and URL-encoded before sending `X-Audit-Log-Reason`.
- Command install/context shorthand UDAs now use a canonical naming set (`@GuildInstalled`, `@UserInstalled`, `@GuildContextOnly`, `@BotDmOnly`, `@PrivateChannelOnly`, `@DmContextOnly`, `@UserInstalledDmOnly`, `@UserInstalledPrivateOnly`, `@GuildInstalledGuildOnly`, `@UserInstalledEverywhere`, `@InstalledEverywhere`).
- Stateful service autowiring now prioritizes explicit `@Inject` fields and supports class-backed stateful groups with clearer missing-constructor guidance.
- Async wrapper type was renamed from `Task!T` to `AsyncTask!T` to avoid symbol collisions with the new command/task UDA surface.
- Gateway frame parsing now accepts binary data frames and attempts JSON decoding before failing with protocol-specific ETF/compression guidance.

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
- Split client event-context builders into `ddiscord.client_event_contexts` and command metadata/context typing helpers into `ddiscord.commands.metadata` / `ddiscord.commands.contexts`.

### Documentation

- Updated README/examples/client docs for auto-registration filters, built-in help/error behavior, and new runnable consoles.
- Expanded runnable examples with focused event, interaction, services, and task scheduler consoles.
