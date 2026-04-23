/**
 * ddiscord — command-system public types and UDAs.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.command_types;

import core.time : Duration;
import ddiscord.context.command : CommandContext;
import ddiscord.models.application_command : ApplicationCommandOptionType, ApplicationCommandType;
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
}

/// High-level command descriptor captured from UDAs.
struct CommandDescriptor
{
    string displayName;
    string description;
    CommandRoute routes = CommandRoute.Hybrid;
    ApplicationCommandType applicationType = ApplicationCommandType.ChatInput;
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
