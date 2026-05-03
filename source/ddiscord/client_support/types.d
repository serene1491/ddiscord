/**
 * ddiscord — client support types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_support.types;

import core.time : Duration, dur;
import ddiscord.commands : CommandDescriptor;
import ddiscord.context.command : CommandContext;
import ddiscord.core.http.client : HttpTransport;
import ddiscord.logging : LogLevel;
import ddiscord.models.message : MessageCreate;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;

/// Client configuration defaults.
private enum DefaultMaxDispatchQueueSize = 4096;
private enum DefaultDispatchOverflowLogEvery = 100;

/// Client runtime configuration.
struct ClientConfig
{
    string token;
    uint intents;
    string prefix = "!";
    string pluginsDir = "./plugins";
    bool allowLoosePlugins = true;
    bool allowPluginEntrypointEscape = false;
    bool requireExplicitPluginPermissions = false;
    Nullable!Snowflake ownerId;
    Nullable!Snowflake applicationId;
    bool autoSyncCommands = true;
    LogLevel logLevel = LogLevel.Information;
    Nullable!HttpTransport transport;
    Duration restTimeout = dur!"seconds"(15);
    size_t httpSessionPoolSize = 2;
    Duration httpMaxSessionIdle = dur!"seconds"(55);
    bool autoRetryRateLimits = true;
    uint maxRateLimitRetries = 3;
    bool autoRetryServerErrors = true;
    uint maxServerErrorRetries = 3;
    Duration retryBaseDelay = dur!"msecs"(500);
    Duration maxRetryDelay = dur!"seconds"(30);
    bool logUnhandledGatewayDispatchEvents = false;
    size_t gatewayUnhandledDispatchLogEvery = 100;
    bool enableSharding;
    bool autoSharding = true;
    uint shardCount;
    bool autoReshard;
    Duration autoReshardCheckInterval = dur!"minutes"(10);
    size_t maxDispatchQueueSize = DefaultMaxDispatchQueueSize;
    bool dropOldestDispatchOnOverflow = true;
    size_t dispatchOverflowLogEvery = DefaultDispatchOverflowLogEvery;
    /// TTL for cached guild role snapshots used by prefix permission resolution.
    /// Set `Duration.zero` to disable this cache.
    Duration prefixPermissionRoleCacheTtl = dur!"minutes"(5);
}

/// Runtime filter used by automatic module-level registration helpers.
struct CommandRegistrationFilter
{
    string[] includeModules;
    string[] excludeModules;
    string[] includeOwners;
    string[] excludeOwners;
    string[] includeNames;
    string[] excludeNames;
    string[] includeCategories;
    string[] excludeCategories;
    bool includeFreeFunctions = true;
    bool includeTypes = true;
    bool includeEvents = true;
    bool includePlugins = true;
    bool includeTasks = true;

    static CommandRegistrationFilter modules(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeModules = values.dup;
        return filter;
    }

    static CommandRegistrationFilter owners(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeOwners = values.dup;
        return filter;
    }

    static CommandRegistrationFilter names(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeNames = values.dup;
        return filter;
    }

    static CommandRegistrationFilter categories(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeCategories = values.dup;
        return filter;
    }

    CommandRegistrationFilter exceptModules(string[] values...)
    {
        excludeModules ~= values;
        return this;
    }

    CommandRegistrationFilter exceptOwners(string[] values...)
    {
        excludeOwners ~= values;
        return this;
    }

    CommandRegistrationFilter exceptNames(string[] values...)
    {
        excludeNames ~= values;
        return this;
    }

    CommandRegistrationFilter exceptCategories(string[] values...)
    {
        excludeCategories ~= values;
        return this;
    }

    CommandRegistrationFilter freeFunctionsOnly()
    {
        includeTypes = false;
        return this;
    }

    CommandRegistrationFilter typesOnly()
    {
        includeFreeFunctions = false;
        return this;
    }

    CommandRegistrationFilter withoutEvents()
    {
        includeEvents = false;
        return this;
    }

    CommandRegistrationFilter withoutPlugins()
    {
        includePlugins = false;
        return this;
    }

    CommandRegistrationFilter withoutTasks()
    {
        includeTasks = false;
        return this;
    }
}

/// User-facing classification for surfaced command failures.
enum CommandErrorKind
{
    UnknownCommand,
    MissingCommandName,
    MissingArgument,
    InvalidArgument,
    TooManyArguments,
    PolicyDenied,
    HandlerFailure,
    Unknown,
}

/// Rich error context exposed to the customizable error behavior.
struct CommandErrorContext
{
    CommandErrorKind kind = CommandErrorKind.Unknown;
    string route;
    string commandName;
    string error;
    CommandContext command;
}

/// User-facing help entry prepared from a command descriptor.
struct CommandHelpEntry
{
    string name;
    string description;
    string usage;
    string routes;
    string category;
    string sourceModule;
    string owner;
    string policies;
    CommandDescriptor descriptor;
}

/// Prepared help page delivered to the help renderer.
struct CommandHelpPage
{
    string commandName;
    string query;
    size_t page = 1;
    size_t pageSize;
    size_t totalEntries;
    size_t totalPages = 1;
    CommandHelpEntry[] entries;
    bool hasPrevious;
    bool hasNext;
    string previousCustomId;
    string nextCustomId;
}

/// Configures the built-in help command and its rendering pipeline.
final class CommandHelpBehavior
{
    bool enabled = true;
    string commandName = "help";
    string description = "Show registered commands";
    size_t pageSize = 6;
    bool showBuiltinCommands;
    bool useComponentsV2 = true;
    bool delegate(CommandDescriptor) includeCommand;
    CommandHelpEntry delegate(CommandDescriptor, string) buildEntry;
    MessageCreate delegate(CommandHelpPage) renderPage;
}

/// Configures how the client surfaces command failures back to Discord users.
final class CommandErrorBehavior
{
    bool enabled = true;
    bool surfaceUnknownCommand = true;
    bool surfaceMissingCommandName;
    bool surfaceArgumentErrors = true;
    bool surfacePolicyErrors;
    bool surfaceHandlerFailures = true;
    bool surfaceOtherErrors = true;
    bool delegate(CommandErrorContext) shouldSurface;
    MessageCreate delegate(CommandErrorContext) render;

    /// Returns a low-noise profile that avoids user-facing failure spam.
    static CommandErrorBehavior nonVerbose()
    {
        auto behavior = new CommandErrorBehavior;
        behavior.surfaceUnknownCommand = false;
        behavior.surfaceMissingCommandName = false;
        behavior.surfaceArgumentErrors = false;
        behavior.surfacePolicyErrors = false;
        behavior.surfaceHandlerFailures = false;
        behavior.surfaceOtherErrors = false;
        return behavior;
    }

    /// Returns a profile that surfaces all known command failure kinds.
    static CommandErrorBehavior verbose()
    {
        auto behavior = new CommandErrorBehavior;
        behavior.surfaceUnknownCommand = true;
        behavior.surfaceMissingCommandName = true;
        behavior.surfaceArgumentErrors = true;
        behavior.surfacePolicyErrors = true;
        behavior.surfaceHandlerFailures = true;
        behavior.surfaceOtherErrors = true;
        return behavior;
    }
}

struct RegistrationCandidate
{
    string moduleName;
    string ownerName;
    string symbolName;
    string commandName;
    string category;
    bool freeFunction;
    bool typeSymbol;
    bool command;
    bool event;
    bool plugin;
    bool task;
}

struct HelpRequest
{
    string query;
    size_t page = 1;
}

/// Runtime dispatch queue telemetry for production monitoring.
struct DispatchQueueHealth
{
    size_t queued;
    size_t peakQueued;
    size_t maxQueued;
    ulong droppedTotal;
}
