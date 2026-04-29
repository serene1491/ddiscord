/**
 * ddiscord — command-system public types and UDAs.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.command_types;

import core.time : Duration, dur;
import ddiscord.context.command : CommandContext;
import ddiscord.models.application_command : ApplicationCommandOptionType, ApplicationCommandType,
    ApplicationCommandOptionChoice, ApplicationIntegrationType, AutocompleteChoice, InteractionContextType;
public import ddiscord.models.application_command : CommandRoute;
import ddiscord.models.channel : ChannelType;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;

/// Command middleware callback.
alias CommandMiddleware = Result!(bool, string) delegate(CommandContext);

/// Marks a command handler.
struct Command
{
    string name;
    string description;
    CommandRoute routes;

    this(string name, string description = "", CommandRoute routes = CommandRoute.Hybrid)
    {
        this.name = name;
        this.description = description;
        this.routes = routes;
    }
}

/// Marks an explicit hybrid command handler.
struct HybridCommand
{
    string name;
    string description;

    this(string name, string description = "")
    {
        this.name = name;
        this.description = description;
    }
}

/// Marks an explicit slash-only command handler.
struct SlashCommand
{
    string name;
    string description;

    this(string name, string description = "")
    {
        this.name = name;
        this.description = description;
    }
}

/// Marks an explicit prefix-only command handler.
struct PrefixCommand
{
    string name;
    string description;

    this(string name, string description = "")
    {
        this.name = name;
        this.description = description;
    }
}

/// Marks a message context-menu handler.
struct MessageCommand
{
    string name;

    this(string name)
    {
        this.name = name;
    }
}

/// Marks a user context-menu handler.
struct UserCommand
{
    string name;

    this(string name)
    {
        this.name = name;
    }
}

/// Marks an input parameter as a command option.
struct Option
{
    string name;
    string description;
    double min;
    double max;

    this(string name, string description = "", double min = double.nan, double max = double.nan)
    {
        this.name = name;
        this.description = description;
        this.min = min;
        this.max = max;
    }
}

/// Marks a choice for a string option.
struct Choice
{
    string label;
    string value;

    this(string label, string value)
    {
        this.label = label;
        this.value = value;
    }
}

/// Marks allowed channel kinds.
struct ChannelTypes
{
    ChannelType[] values;

    this(ChannelType[] values...)
    {
        this.values = values.dup;
    }
}

/// Marks a greedy prefix argument.
struct Greedy
{
}

/// Marks a type or field as stateful/injectable.
struct Stateful
{
}

/// Marks a field for service injection.
struct Inject
{
}

/// Assigns a category used by built-in help and filtering.
struct CommandCategory
{
    string name;

    this(string name)
    {
        this.name = name;
    }
}

/// Hides a command from the built-in help surface.
struct HideFromHelp
{
}

/// Attaches a named middleware to a command.
struct UseMiddleware
{
    string name;

    this(string name)
    {
        this.name = name;
    }
}

/// Restricts command execution to guild contexts.
struct GuildOnly
{
}

/// Restricts command execution to direct-message contexts.
struct DirectMessageOnly
{
}

/// Sets explicit Discord installation targets (`integration_types`) for a command.
struct CommandInstallTypes
{
    ApplicationIntegrationType[] values;

    this(ApplicationIntegrationType[] values...)
    {
        this.values = values.dup;
    }
}

/// Restricts command install target to guild installations.
struct GuildInstalled
{
}

/// Restricts command install target to user installations.
struct UserInstalled
{
}

/// Sets explicit Discord interaction contexts (`contexts`) for a command.
struct CommandContexts
{
    InteractionContextType[] values;

    this(InteractionContextType[] values...)
    {
        this.values = values.dup;
    }
}

/// Restricts command contexts to guild invocations only.
struct GuildContextOnly
{
}

/// Restricts command contexts to bot DMs only.
struct BotDmOnly
{
}

/// Restricts command contexts to private channels only.
struct PrivateChannelOnly
{
}

/// Convenience combo for user-installed commands available only in bot DMs.
struct UserInstalledDmOnly
{
}

/// Convenience combo for user-installed commands available only in private channels.
struct UserInstalledPrivateOnly
{
}

/// Restricts command contexts to DM surfaces (bot DMs + private channels).
struct DmContextOnly
{
}

/// Convenience combo for guild-installed commands available only in guild channels.
struct GuildInstalledGuildOnly
{
}

/// Convenience combo for user-installed commands available in any interaction context.
struct UserInstalledEverywhere
{
}

/// Convenience combo for commands installable in guilds and user installs.
struct InstalledEverywhere
{
}

/// Task scheduling mode for `@Task`.
enum TaskMode
{
    Every,
    Delay,
    Cron,
}

/// Marks a method/function as a scheduled task entrypoint.
struct Task
{
    string label;
    TaskMode mode = TaskMode.Every;
    Duration interval = Duration.zero;
    string expression;
    bool runOnRegister;
    ulong count;
    bool reconnect = true;

    this(
        Duration interval,
        string label = "",
        TaskMode mode = TaskMode.Every,
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        this.label = label;
        this.mode = mode;
        this.interval = interval;
        this.runOnRegister = runOnRegister;
        this.count = count;
        this.reconnect = reconnect;
    }

    this(
        string expression,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        this.label = label;
        this.mode = TaskMode.Cron;
        this.expression = expression;
        this.runOnRegister = runOnRegister;
        this.count = count;
        this.reconnect = reconnect;
    }

    /// Task loop constructor (`seconds` + `minutes` + `hours`).
    static Task loop(
        double seconds = 0,
        double minutes = 0,
        double hours = 0,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        auto totalSeconds = seconds + (minutes * 60.0) + (hours * 3600.0);
        auto intervalMs = cast(long) (totalSeconds * 1000.0);

        Task task;
        task.label = label;
        task.mode = TaskMode.Every;
        task.interval = intervalMs <= 0 ? Duration.zero : dur!"msecs"(intervalMs);
        task.runOnRegister = runOnRegister;
        task.count = count;
        task.reconnect = reconnect;
        return task;
    }

    /// Explicit recurring-task constructor.
    static Task every(
        Duration interval,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        return Task(interval, label, TaskMode.Every, runOnRegister, count, reconnect);
    }

    /// Explicit one-shot delay-task constructor.
    static Task delay(
        Duration interval,
        string label = "",
        bool runOnRegister = false,
        bool reconnect = true
    )
    {
        return Task(interval, label, TaskMode.Delay, runOnRegister, 1, reconnect);
    }

    /// Explicit cron-task constructor.
    static Task cron(
        string expression,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        return Task(expression, label, runOnRegister, count, reconnect);
    }
}

/// Marks a command module for future module-level auto-discovery.
struct BotModule
{
    string name;

    this(string name)
    {
        this.name = name;
    }
}

/// Marks a command that requires bot ownership.
struct RequireOwner
{
}

/// Marks a command that requires specific permissions.
struct RequirePermissions
{
    ulong permissions;

    this(ulong permissions)
    {
        this.permissions = permissions;
    }
}

/// Singular alias for `RequirePermissions`.
alias RequirePermission = RequirePermissions;

/// Rate limit bucket selector.
enum RateLimitBucket
{
    User,
    Guild,
    Channel,
    Global,
}

/// Rate limit attribute.
struct RateLimit
{
    uint count;
    Duration window;
    RateLimitBucket bucket;

    this(uint count, Duration window, RateLimitBucket bucket = RateLimitBucket.User)
    {
        this.count = count;
        this.window = window;
        this.bucket = bucket;
    }
}

/// Alias for `RateLimit` with the same payload semantics.
alias CooldownRate = RateLimit;

/// Attribute attaching an autocomplete handler symbol.
struct Autocomplete(alias handler)
{
    string optionName;

    this(string optionName)
    {
        this.optionName = optionName;
    }
}

/// High-level command descriptor captured from UDAs.
struct CommandDescriptor
{
    string displayName;
    string description;
    CommandRoute routes = CommandRoute.Hybrid;
    ApplicationCommandType applicationType = ApplicationCommandType.ChatInput;
    ApplicationIntegrationType[] integrationTypes;
    InteractionContextType[] contexts;
    bool stateful;
    string ownerType;
    string ownerQualifiedName;
    string symbolName;
    string qualifiedName;
    string sourceModule;
    string sourceFile;
    string category;
    bool hiddenFromHelp;
    bool builtin;
    string[] middlewareNames;
    string[] parameterNames;
    string[] parameterTypes;
    CommandOptionDescriptor[] options;
    Result!(AutocompleteChoice[], string) delegate(
        CommandContext,
        string focusedName,
        string focusedValue,
        string[string] options
    ) autocompleteExecutor;
    CommandPolicyDescriptor policy;
    Result!(CommandExecution, string) delegate(CommandContext, string[]) prefixExecutor;
    Result!(CommandExecution, string) delegate(CommandContext, string[string]) slashExecutor;
}

/// High-level option descriptor inferred from a handler parameter.
struct CommandOptionDescriptor
{
    string parameterName;
    string displayName;
    string description;
    string typeName;
    ApplicationCommandOptionType applicationType = ApplicationCommandOptionType.String;
    bool required = true;
    bool greedy;
    bool autocomplete;
    ApplicationCommandOptionChoice[] choices;
    ChannelType[] channelTypes;
}

/// Policy descriptor extracted from command UDAs.
struct CommandPolicyDescriptor
{
    bool ownerOnly;
    bool guildOnly;
    bool directMessageOnly;
    ulong requiredPermissions;
    bool hasRateLimit;
    uint rateLimitCount;
    Duration rateLimitWindow;
    RateLimitBucket rateLimitBucket = RateLimitBucket.User;
}

/// Prefix command parse result.
struct ParsedCommand
{
    string name;
    string[] args;
    Nullable!CommandDescriptor descriptor;
}

/// Outcome of a successfully-executed command.
struct CommandExecution
{
    string commandName;
    size_t replyCount;
}

/// Runtime settings consulted by command policies.
struct CommandExecutionSettings
{
    Nullable!Snowflake ownerId;
}

unittest
{
    auto task = Task.loop(seconds: 1.5, minutes: 1, count: 3, label: "loop");
    assert(task.mode == TaskMode.Every);
    assert(task.interval > Duration.zero);
    assert(task.count == 3);
    assert(task.label == "loop");

    auto delayed = Task.delay(dur!"seconds"(2), "once");
    assert(delayed.mode == TaskMode.Delay);
    assert(delayed.count == 1);

    auto cron = Task.cron("@every:5s", "cron");
    assert(cron.mode == TaskMode.Cron);
    assert(cron.expression == "@every:5s");
}
