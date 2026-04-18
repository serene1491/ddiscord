/**
 * ddiscord — UDA-first command system.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.commands;

import core.time : Duration, MonoTime, dur;
import ddiscord.core.http.client : HttpError, HttpResponse, HttpTransport;
import ddiscord.context.autocomplete : AutocompleteContext;
import ddiscord.context.command : CommandContext, CommandSource;
import ddiscord.models.application_command : ApplicationCommandDefinition, ApplicationCommandOption,
    ApplicationCommandOptionType, ApplicationCommandType;
import ddiscord.models.channel : Channel;
import ddiscord.models.member : GuildMember;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient, RestClientConfig;
import ddiscord.util.errors : formatError;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
public import ddiscord.models.application_command : CommandRoute;
import ddiscord.models.channel : ChannelType;
import ddiscord.models.role : Permissions;
import ddiscord.services : ServiceContainer;
import std.ascii : isUpper, toLower;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : startsWith, strip;
import std.traits : ParameterDefaults, Parameters, ParameterIdentifierTuple, ReturnType, isCallable;
import std.typecons : Tuple;

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
    string symbolName;
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

private struct RateLimitWindowState
{
    MonoTime windowStart;
    uint used;
}

/// Registry that collects UDA-decorated handlers.
final class CommandRegistry
{
    private ServiceContainer _services;
    private CommandDescriptor[] _descriptors;
    private RateLimitWindowState[string] _rateLimits;

    this(ServiceContainer services)
    {
        _services = services;
    }

    /// Registers free function handlers by alias.
    void registerAll(handlers...)(int _dummy = 0)
    {
        auto _ = _dummy;
        registerHandlers!handlers(this);
    }

    /// Registers a stateful command group type.
    void register(T)()
    {
        injectServices!T();

        static foreach (memberName; __traits(allMembers, T))
        {
            {
                static if (memberName != "__ctor" && memberName != "__xdtor")
                {
                    mixin("alias memberSymbol = T." ~ memberName ~ ";");
                    static if (isCallable!memberSymbol)
                    {
                        enum hasAttrs = __traits(getAttributes, memberSymbol).length > 0;
                        static if (hasAttrs)
                        {
                            auto descriptor = describeMember!(T, memberName)();
                            if (descriptor.displayName.length != 0)
                                _descriptors ~= descriptor;
                        }
                    }
                }
            }
        }
    }

    /// Returns the registered descriptors.
    CommandDescriptor[] descriptors() @property
    {
        return _descriptors.dup;
    }

    /// Finds a command by name and route.
    Nullable!CommandDescriptor find(string name, CommandRoute route = CommandRoute.Hybrid)
    {
        foreach (descriptor; _descriptors)
        {
            if (descriptor.displayName == name && routeEnabled(descriptor.routes, route))
                return Nullable!CommandDescriptor.of(descriptor);
        }

        return Nullable!CommandDescriptor.init;
    }

    /// Parses a prefix invocation into a descriptor + argv.
    Result!(ParsedCommand, string) parsePrefix(string prefix, string content)
    {
        if (!content.startsWith(prefix))
        {
            return Result!(ParsedCommand, string).err(formatError(
                "commands",
                "The incoming content does not match the configured prefix.",
                "Expected prefix `" ~ prefix ~ "` but received `" ~ content ~ "`.",
                "Call `executePrefix` only for prefix messages or configure the client prefix correctly."
            ));
        }

        auto tokens = tokenize(content[prefix.length .. $]);
        if (tokens.length == 0)
        {
            return Result!(ParsedCommand, string).err(formatError(
                "commands",
                "No command name was provided after the prefix.",
                "Message content was `" ~ content ~ "`.",
                "Add a command name after the prefix, for example `!ping`."
            ));
        }

        auto descriptor = find(tokens[0], CommandRoute.Prefix);
        if (descriptor.isNull)
        {
            return Result!(ParsedCommand, string).err(formatError(
                "commands",
                "The requested prefix command is not registered.",
                "Unknown command `" ~ tokens[0] ~ "`.",
                "Check the command name or ensure the handler was registered before processing messages."
            ));
        }

        ParsedCommand parsed;
        parsed.name = tokens[0];
        parsed.args = tokens[1 .. $].dup;
        parsed.descriptor = descriptor;
        return Result!(ParsedCommand, string).ok(parsed);
    }

    /// Parses and executes a prefix command.
    Result!(CommandExecution, string) executePrefix(
        CommandContext ctx,
        string prefix,
        string content
    )
    {
        auto parsed = parsePrefix(prefix, content);
        if (parsed.isErr)
            return Result!(CommandExecution, string).err(parsed.error);

        auto descriptor = parsed.value.descriptor.get;
        auto policyError = validatePolicy(descriptor, ctx);
        if (!policyError.isNull)
            return Result!(CommandExecution, string).err(policyError.get);

        enforce(descriptor.prefixExecutor !is null, "Prefix executor was not registered for " ~ descriptor.displayName);
        return descriptor.prefixExecutor(ctx, parsed.value.args);
    }

    /// Executes a slash or context-menu command by name.
    Result!(CommandExecution, string) executeSlash(
        CommandContext ctx,
        string name,
        string[string] options = null
    )
    {
        auto descriptor = find(name, CommandRoute.Slash);
        if (descriptor.isNull)
            descriptor = find(name, CommandRoute.ContextMenu);

        if (descriptor.isNull)
        {
            return Result!(CommandExecution, string).err(formatError(
                "commands",
                "The requested interaction command is not registered.",
                "Unknown command `" ~ name ~ "`.",
                "Sync commands again and ensure the handler is registered for slash or context-menu routing."
            ));
        }

        auto resolved = descriptor.get;
        auto policyError = validatePolicy(resolved, ctx);
        if (!policyError.isNull)
            return Result!(CommandExecution, string).err(policyError.get);

        enforce(resolved.slashExecutor !is null, "Slash executor was not registered for " ~ resolved.displayName);
        return resolved.slashExecutor(ctx, options);
    }

    /// Returns slash/context-menu definitions derived from registered handlers.
    ApplicationCommandDefinition[] applicationCommands() @property
    {
        ApplicationCommandDefinition[] definitions;

        foreach (descriptor; _descriptors)
        {
            if (
                descriptor.applicationType == ApplicationCommandType.ChatInput &&
                !routeEnabled(descriptor.routes, CommandRoute.Slash)
            )
            {
                continue;
            }

            if (
                descriptor.applicationType != ApplicationCommandType.ChatInput &&
                !routeEnabled(descriptor.routes, CommandRoute.ContextMenu)
            )
            {
                continue;
            }

            ApplicationCommandDefinition definition;
            definition.name = descriptor.displayName;
            definition.description = descriptor.description.length == 0
                ? "Generated by ddiscord"
                : descriptor.description;
            definition.type = descriptor.applicationType;

            if (descriptor.applicationType == ApplicationCommandType.ChatInput)
            {
                foreach (option; descriptor.options)
                {
                    ApplicationCommandOption definitionOption;
                    definitionOption.name = option.displayName;
                    definitionOption.description = option.description.length == 0
                        ? option.displayName
                        : option.description;
                    definitionOption.type = option.applicationType;
                    definitionOption.required = option.required;
                    definition.options ~= definitionOption;
                }
            }

            definitions ~= definition;
        }

        return definitions;
    }

    private void injectServices(T)()
    {
        T instance = T.init;

        static foreach (index, _; instance.tupleof)
        {
            {
                alias FieldType = typeof(instance.tupleof[index]);

                static if (!is(FieldType == void))
                {
                    FieldType resolved;
                    if (_services.tryGet!FieldType(resolved))
                        instance.tupleof[index] = resolved;
                }
            }
        }

        _services.add!T(instance);
    }

    private Nullable!string validatePolicy(CommandDescriptor descriptor, CommandContext ctx)
    {
        if (descriptor.policy.ownerOnly)
        {
            auto settings = _services.get!CommandExecutionSettings();
            if (settings.ownerId.isNull || settings.ownerId.get != ctx.user.id)
            {
                return Nullable!string.of(formatError(
                    "commands",
                    "This command is restricted to the configured bot owner.",
                    "Invoker `" ~ ctx.user.id.toString ~ "` does not match the configured owner.",
                    "Set `ClientConfig.ownerId` correctly or remove `@RequireOwner` if that policy is not intended."
                ));
            }
        }

        if (descriptor.policy.requiredPermissions != 0)
        {
            if ((ctx.permissions & descriptor.policy.requiredPermissions) != descriptor.policy.requiredPermissions)
            {
                return Nullable!string.of(formatError(
                    "commands",
                    "The invoker does not satisfy the command permission requirements.",
                    "Required permissions mask: `" ~ descriptor.policy.requiredPermissions.to!string ~ "`, provided mask: `" ~ ctx.permissions.to!string ~ "`.",
                    "Grant the required Discord permissions or remove `@RequirePermissions` from the command."
                ));
            }
        }

        if (descriptor.policy.hasRateLimit)
        {
            auto key = rateLimitKey(descriptor, ctx);
            auto now = MonoTime.currTime;

            if (auto state = key in _rateLimits)
            {
                if (now - (*state).windowStart >= descriptor.policy.rateLimitWindow)
                {
                    (*state).windowStart = now;
                    (*state).used = 0;
                }

                if ((*state).used >= descriptor.policy.rateLimitCount)
                {
                    return Nullable!string.of(formatError(
                        "commands",
                        "This command is temporarily rate limited.",
                        "Bucket `" ~ descriptor.displayName ~ "` exceeded `" ~ descriptor.policy.rateLimitCount.to!string ~ "` invocation(s) in the active window.",
                        "Wait for the cooldown window to expire before trying again."
                    ));
                }

                (*state).used++;
            }
            else
            {
                RateLimitWindowState state;
                state.windowStart = now;
                state.used = 1;
                _rateLimits[key] = state;
            }
        }

        return Nullable!string.init;
    }

    private string rateLimitKey(CommandDescriptor descriptor, CommandContext ctx)
    {
        final switch (descriptor.policy.rateLimitBucket)
        {
            case RateLimitBucket.User:
                return descriptor.displayName ~ ":user:" ~ ctx.user.id.toString;
            case RateLimitBucket.Guild:
                if (!ctx.message.isNull && !ctx.message.get.guildId.isNull)
                    return descriptor.displayName ~ ":guild:" ~ ctx.message.get.guildId.get.toString;
                return descriptor.displayName ~ ":guild:none";
            case RateLimitBucket.Channel:
                return descriptor.displayName ~ ":channel:" ~ ctx.channel.id.toString;
            case RateLimitBucket.Global:
                return descriptor.displayName ~ ":global";
        }
    }
}

private void registerHandlers(handlers...)(CommandRegistry registry)
{
    static foreach (handler; handlers)
    {
        {
            auto descriptor = describeHandler!handler();
            if (descriptor.displayName.length != 0)
            {
                descriptor.prefixExecutor = buildFreePrefixExecutor!handler();
                descriptor.slashExecutor = buildFreeSlashExecutor!handler();
                registry._descriptors ~= descriptor;
            }
        }
    }
}

private CommandDescriptor describeHandler(alias fn)()
{
    CommandDescriptor descriptor;
    descriptor.symbolName = __traits(identifier, fn);
    descriptor.parameterNames = parameterNames!fn();
    descriptor.parameterTypes = parameterTypes!fn();
    descriptor.options = optionDescriptors!fn();

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (is(typeof(attr) == Command))
        {
            descriptor.displayName = attr.name;
            descriptor.description = attr.description;
            descriptor.routes = attr.routes;
            descriptor.applicationType = ApplicationCommandType.ChatInput;
        }
        else static if (is(typeof(attr) == HybridCommand))
        {
            descriptor.displayName = attr.name;
            descriptor.description = attr.description;
            descriptor.routes = CommandRoute.Hybrid;
            descriptor.applicationType = ApplicationCommandType.ChatInput;
        }
        else static if (is(typeof(attr) == MessageCommand))
        {
            descriptor.displayName = attr.name;
            descriptor.routes = CommandRoute.ContextMenu;
            descriptor.applicationType = ApplicationCommandType.Message;
        }
        else static if (is(typeof(attr) == UserCommand))
        {
            descriptor.displayName = attr.name;
            descriptor.routes = CommandRoute.ContextMenu;
            descriptor.applicationType = ApplicationCommandType.User;
        }
        else static if (AttrIs!(attr, RequireOwner))
        {
            descriptor.policy.ownerOnly = true;
        }
        else static if (is(typeof(attr) == RequirePermissions))
        {
            descriptor.policy.requiredPermissions = attr.permissions;
        }
        else static if (is(typeof(attr) == RateLimit))
        {
            descriptor.policy.hasRateLimit = true;
            descriptor.policy.rateLimitCount = attr.count;
            descriptor.policy.rateLimitWindow = attr.window;
            descriptor.policy.rateLimitBucket = attr.bucket;
        }
    }

    if (!hasCommandAttr!fn)
        descriptor.displayName = "";

    return descriptor;
}

private CommandDescriptor describeMember(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    auto descriptor = describeHandler!memberSymbol();
    descriptor.stateful = true;
    descriptor.ownerType = T.stringof;
    descriptor.prefixExecutor = buildStatefulPrefixExecutor!(T, memberName)();
    descriptor.slashExecutor = buildStatefulSlashExecutor!(T, memberName)();
    return descriptor;
}

private string[] parameterNames(alias fn)()
{
    string[] names;
    foreach (name; ParameterIdentifierTuple!fn)
        names ~= name;
    return names;
}

private string[] parameterTypes(alias fn)()
{
    string[] names;
    foreach (T; Parameters!fn)
        names ~= T.stringof;
    return names;
}

private CommandOptionDescriptor[] optionDescriptors(alias fn)()
{
    CommandOptionDescriptor[] options;
    alias ParamTypes = Parameters!fn;
    alias ParamNames = ParameterIdentifierTuple!fn;
    alias Defaults = ParameterDefaults!fn;

    static foreach (index, ParamType; ParamTypes)
    {
        static if (!is(ParamType == CommandContext))
        {
            {
                CommandOptionDescriptor option;
                option.parameterName = ParamNames[index];
                option.displayName = defaultOptionName(ParamNames[index]);
                option.description = defaultOptionDescription(ParamNames[index]);
                option.typeName = ParamType.stringof;
                option.applicationType = applicationOptionType!ParamType();
                option.required = is(Defaults[index] == void) && !isNullableType!ParamType;
                option.greedy = index == ParamTypes.length - 1 && is(ParamType == string);
                options ~= option;
            }
        }
    }

    return options;
}

private bool hasCommandAttr(alias fn)()
{
    bool result = false;

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (
            is(typeof(attr) == Command) ||
            is(typeof(attr) == HybridCommand) ||
            is(typeof(attr) == MessageCommand) ||
            is(typeof(attr) == UserCommand)
        )
        {
            result = true;
        }
    }

    return result;
}

private bool routeEnabled(CommandRoute available, CommandRoute requested)
{
    return (cast(uint) available & cast(uint) requested) != 0;
}

private string defaultOptionName(string parameterName)
{
    string value;

    foreach (index, ch; parameterName)
    {
        if (ch == '_' || ch == ' ')
        {
            if (value.length != 0 && value[$ - 1] != '-')
                value ~= '-';
            continue;
        }

        if (isUpper(ch))
        {
            if (index != 0 && value.length != 0 && value[$ - 1] != '-')
                value ~= '-';
            value ~= cast(char) toLower(ch);
            continue;
        }

        value ~= ch;
    }

    return value;
}

private string defaultOptionDescription(string parameterName)
{
    auto normalized = defaultOptionName(parameterName);
    string description;
    foreach (ch; normalized)
    {
        if (ch == '-')
            description ~= ' ';
        else
            description ~= ch;
    }
    return description;
}

private string[] tokenize(string input)
{
    string[] tokens;
    char quote;
    bool inQuote;
    string current;

    foreach (ch; input)
    {
        if (inQuote)
        {
            if (ch == quote)
            {
                inQuote = false;
            }
            else
            {
                current ~= ch;
            }

            continue;
        }

        if (ch == '"' || ch == '\'')
        {
            inQuote = true;
            quote = ch;
            continue;
        }

        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        {
            if (current.length != 0)
            {
                tokens ~= current;
                current = null;
            }

            continue;
        }

        current ~= ch;
    }

    if (current.length != 0)
        tokens ~= current;

    return tokens;
}

private template HasInjectAttr(T, string memberName)
{
    enum bool HasInjectAttr = HasInjectAttrImpl!(__traits(getAttributes, __traits(getMember, T, memberName)));
}

private template HasInjectAttrImpl(attrs...)
{
    static if (attrs.length == 0)
        enum bool HasInjectAttrImpl = false;
    else static if (is(typeof(attrs[0]) == Inject))
        enum bool HasInjectAttrImpl = true;
    else
        enum bool HasInjectAttrImpl = HasInjectAttrImpl!(attrs[1 .. $]);
}

private template AttrIs(alias attr, T)
{
    static if (__traits(compiles, typeof(attr)))
        enum bool AttrIs = is(typeof(attr) == T);
    else
        enum bool AttrIs = is(attr == T);
}

private bool isNullableType(T)()
{
    return is(T == Nullable!U, U);
}

private string joinGreedy(string[] args, size_t start)
{
    if (start >= args.length)
        return "";
    return args[start .. $].join(" ");
}

private Result!(T, string) parseValue(T)(
    string raw,
    CommandContext ctx
)
{
    static if (isNullableType!T)
    {
        alias Inner = InnerNullable!T;
        auto inner = parseValue!Inner(raw, ctx);
        if (inner.isErr)
            return Result!(T, string).err(inner.error);
        return Result!(T, string).ok(Nullable!Inner.of(inner.value));
    }
    else static if (is(T == string))
    {
        return Result!(T, string).ok(raw);
    }
    else static if (is(T == bool))
    {
        auto normalized = raw.strip;
        if (normalized == "true" || normalized == "1" || normalized == "yes")
            return Result!(T, string).ok(true);
        else if (normalized == "false" || normalized == "0" || normalized == "no")
            return Result!(T, string).ok(false);
        else
        {
            return Result!(T, string).err(formatError(
                "commands",
                "A boolean parameter received an invalid value.",
                "Received `" ~ raw ~ "`.",
                "Use one of: `true`, `false`, `1`, `0`, `yes`, or `no`."
            ));
        }
    }
    else static if (is(T == int) || is(T == long) || is(T == double) || is(T == ulong))
    {
        return Result!(T, string).ok(raw.to!T);
    }
    else static if (is(T == Snowflake))
    {
        return Result!(T, string).ok(Snowflake(extractSnowflake(raw)));
    }
    else static if (is(T == User))
    {
        User user;
        auto id = extractSnowflake(raw);
        user.id = Snowflake(id);
        user.username = raw;

        auto cached = ctx.cache.user(user.id);
        if (!cached.isNull)
            user = cached.get;

        return Result!(T, string).ok(user);
    }
    else static if (is(T == Role))
    {
        Role role;
        role.id = Snowflake(extractSnowflake(raw));
        role.name = raw;
        return Result!(T, string).ok(role);
    }
    else static if (is(T == Channel))
    {
        Channel channel;
        channel.id = Snowflake(extractSnowflake(raw));
        channel.name = raw;

        auto cached = ctx.cache.channel(channel.id);
        if (!cached.isNull)
            channel = cached.get;

        return Result!(T, string).ok(channel);
    }
    else static if (is(T == GuildMember))
    {
        auto user = parseValue!User(raw, ctx);
        if (user.isErr)
            return Result!(T, string).err(user.error);

        GuildMember member;
        member.user = Nullable!User.of(user.value);
        return Result!(T, string).ok(member);
    }
    else
    {
        return Result!(T, string).err(formatError(
            "commands",
            "This parameter type is not supported by the current command binder.",
            "Unsupported type: " ~ T.stringof ~ ".",
            "Use a supported scalar type or extend the binder before exposing this parameter in a command."
        ));
    }
}

private string missingArgumentMessage(string commandName, string parameterName, bool slashStyle)
{
    return formatError(
        "commands",
        slashStyle
            ? "A required slash-command option was not provided."
            : "A required prefix-command argument was not provided.",
        "Command `" ~ commandName ~ "` requires `" ~ parameterName ~ "`.",
        slashStyle
            ? "Pass the option in the interaction payload before executing the command."
            : "Check the command usage and provide the missing argument."
    );
}

private string parseArgumentMessage(
    string commandName,
    string parameterName,
    string expectedType,
    string rawValue,
    string detail
)
{
    return formatError(
        "commands",
        "A command argument could not be converted to the expected type.",
        "Command `" ~ commandName ~ "`, parameter `" ~ parameterName ~ "`, expected `" ~
            expectedType ~ "`, received `" ~ rawValue ~ "`. " ~ detail,
        "Correct the argument value or change the parameter type/default in the command definition."
    );
}

private string handlerFailureMessage(string commandName, Throwable error)
{
    return formatError(
        "commands",
        "The command handler raised an exception.",
        "Command `" ~ commandName ~ "` failed with: " ~ error.msg,
        "Inspect the command implementation and any REST call it performed."
    );
}

private ulong extractSnowflake(string raw)
{
    string digits;

    foreach (ch; raw)
    {
        if (ch >= '0' && ch <= '9')
            digits ~= ch;
    }

    if (digits.length == 0)
        return 0;

    return digits.to!ulong;
}

private template InnerNullable(T)
{
    static if (is(T == Nullable!U, U))
        alias InnerNullable = U;
}

private ApplicationCommandOptionType applicationOptionType(T)()
{
    static if (isNullableType!T)
        return applicationOptionType!(InnerNullable!T)();
    else static if (is(T == bool))
        return ApplicationCommandOptionType.Boolean;
    else static if (is(T == int) || is(T == long) || is(T == ulong) || is(T == Snowflake))
        return ApplicationCommandOptionType.Integer;
    else static if (is(T == double))
        return ApplicationCommandOptionType.Number;
    else static if (is(T == User) || is(T == GuildMember))
        return ApplicationCommandOptionType.User;
    else static if (is(T == Channel))
        return ApplicationCommandOptionType.Channel;
    else static if (is(T == Role))
        return ApplicationCommandOptionType.Role;
    else
        return ApplicationCommandOptionType.String;
}

private Result!(CommandExecution, string) delegate(CommandContext, string[]) buildFreePrefixExecutor(alias fn)()
{
    Result!(CommandExecution, string) delegate(CommandContext, string[]) executor;
    executor = (CommandContext ctx, string[] rawArgs) {
        return invokeFreePrefix!fn(ctx, rawArgs);
    };
    return executor;
}

private Result!(CommandExecution, string) delegate(CommandContext, string[string]) buildFreeSlashExecutor(alias fn)()
{
    Result!(CommandExecution, string) delegate(CommandContext, string[string]) executor;
    executor = (CommandContext ctx, string[string] rawOptions) {
        return invokeFreeSlash!fn(ctx, rawOptions);
    };
    return executor;
}

private Result!(CommandExecution, string) delegate(CommandContext, string[]) buildStatefulPrefixExecutor(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    Result!(CommandExecution, string) delegate(CommandContext, string[]) executor;
    executor = (CommandContext ctx, string[] rawArgs) {
        auto instance = ctx.services.get!T();
        return invokeStatefulPrefix!(T, memberSymbol)(instance, ctx, rawArgs);
    };
    return executor;
}

private Result!(CommandExecution, string) delegate(CommandContext, string[string]) buildStatefulSlashExecutor(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    Result!(CommandExecution, string) delegate(CommandContext, string[string]) executor;
    executor = (CommandContext ctx, string[string] rawOptions) {
        auto instance = ctx.services.get!T();
        return invokeStatefulSlash!(T, memberSymbol)(instance, ctx, rawOptions);
    };
    return executor;
}

private Result!(CommandExecution, string) invokeFreePrefix(alias fn)(
    CommandContext ctx,
    string[] rawArgs
)
{
    alias ParamTypes = Parameters!fn;
    alias ParamNames = ParameterIdentifierTuple!fn;
    alias Defaults = ParameterDefaults!fn;
    Tuple!ParamTypes bound;

    size_t cursor = 0;
    static foreach (index, ParamType; ParamTypes)
    {
        static if (is(ParamType == CommandContext))
        {
            bound[index] = ctx;
        }
        else
        {
            static if (index == ParamTypes.length - 1 && is(ParamType == string))
            {
                if (cursor < rawArgs.length)
                {
                    string source = joinGreedy(rawArgs, cursor);
                    auto parsed = parseValue!ParamType(source, ctx);
                    if (parsed.isErr)
                    {
                        return Result!(CommandExecution, string).err(parseArgumentMessage(
                            commandName!fn(),
                            ParamNames[index],
                            ParamType.stringof,
                            source,
                            parsed.error
                        ));
                    }

                    bound[index] = parsed.value;
                    cursor = rawArgs.length;
                }
                else static if (isNullableType!ParamType)
                {
                    bound[index] = ParamType.init;
                }
                else static if (!is(Defaults[index] == void))
                {
                    bound[index] = Defaults[index];
                }
                else
                {
                    return Result!(CommandExecution, string).err(
                        missingArgumentMessage(commandName!fn(), ParamNames[index], false)
                    );
                }
            }
            else
            {
                if (cursor < rawArgs.length)
                {
                    string source = rawArgs[cursor];
                    auto parsed = parseValue!ParamType(source, ctx);
                    if (parsed.isErr)
                    {
                        return Result!(CommandExecution, string).err(parseArgumentMessage(
                            commandName!fn(),
                            ParamNames[index],
                            ParamType.stringof,
                            source,
                            parsed.error
                        ));
                    }

                    bound[index] = parsed.value;
                    cursor++;
                }
                else static if (isNullableType!ParamType)
                {
                    bound[index] = ParamType.init;
                }
                else static if (!is(Defaults[index] == void))
                {
                    bound[index] = Defaults[index];
                }
                else
                {
                    return Result!(CommandExecution, string).err(
                        missingArgumentMessage(commandName!fn(), ParamNames[index], false)
                    );
                }
            }
        }
    }

    if (cursor < rawArgs.length)
    {
        return Result!(CommandExecution, string).err(formatError(
            "commands",
            "Too many prefix arguments were provided.",
            "Command `" ~ commandName!fn() ~ "` received extra arguments starting at `" ~ rawArgs[cursor] ~ "`.",
            "Remove the extra input or mark the last string parameter as greedy if it should capture the remainder."
        ));
    }

    try
    {
        static if (is(ReturnType!fn == void))
            fn(bound.expand);
        else
            auto _ = fn(bound.expand);
    }
    catch (Throwable error)
    {
        return Result!(CommandExecution, string).err(handlerFailureMessage(commandName!fn(), error));
    }

    CommandExecution execution;
    execution.commandName = commandName!fn();
    execution.replyCount = ctx.rest.messages.history.length;
    return Result!(CommandExecution, string).ok(execution);
}

private Result!(CommandExecution, string) invokeFreeSlash(alias fn)(
    CommandContext ctx,
    string[string] rawOptions
)
{
    alias ParamTypes = Parameters!fn;
    alias ParamNames = ParameterIdentifierTuple!fn;
    alias Defaults = ParameterDefaults!fn;
    Tuple!ParamTypes bound;

    static foreach (index, ParamType; ParamTypes)
    {
        {
            static if (is(ParamType == CommandContext))
            {
                bound[index] = ctx;
            }
            else
            {
                auto optionValue = lookupSlashOption(rawOptions, defaultOptionName(ParamNames[index]));
                if (!optionValue.isNull)
                {
                    auto parsed = parseValue!ParamType(optionValue.get, ctx);
                    if (parsed.isErr)
                    {
                        return Result!(CommandExecution, string).err(parseArgumentMessage(
                            commandName!fn(),
                            ParamNames[index],
                            ParamType.stringof,
                            optionValue.get,
                            parsed.error
                        ));
                    }

                    bound[index] = parsed.value;
                }
                else static if (isNullableType!ParamType)
                {
                    bound[index] = ParamType.init;
                }
                else static if (!is(Defaults[index] == void))
                {
                    bound[index] = Defaults[index];
                }
                else
                {
                    return Result!(CommandExecution, string).err(
                        missingArgumentMessage(commandName!fn(), ParamNames[index], true)
                    );
                }
            }
        }
    }

    try
    {
        static if (is(ReturnType!fn == void))
            fn(bound.expand);
        else
            auto _ = fn(bound.expand);
    }
    catch (Throwable error)
    {
        return Result!(CommandExecution, string).err(handlerFailureMessage(commandName!fn(), error));
    }

    CommandExecution execution;
    execution.commandName = commandName!fn();
    execution.replyCount = ctx.rest.messages.history.length;
    return Result!(CommandExecution, string).ok(execution);
}

private Result!(CommandExecution, string) invokeStatefulPrefix(T, alias member)(
    T instance,
    CommandContext ctx,
    string[] rawArgs
)
{
    alias ParamTypes = Parameters!member;
    alias ParamNames = ParameterIdentifierTuple!member;
    alias Defaults = ParameterDefaults!member;
    Tuple!ParamTypes bound;

    size_t cursor = 0;
    static foreach (index, ParamType; ParamTypes)
    {
        static if (is(ParamType == CommandContext))
        {
            bound[index] = ctx;
        }
        else
        {
            static if (index == ParamTypes.length - 1 && is(ParamType == string))
            {
                if (cursor < rawArgs.length)
                {
                    string source = joinGreedy(rawArgs, cursor);
                    auto parsed = parseValue!ParamType(source, ctx);
                    if (parsed.isErr)
                    {
                        return Result!(CommandExecution, string).err(parseArgumentMessage(
                            commandName!member(),
                            ParamNames[index],
                            ParamType.stringof,
                            source,
                            parsed.error
                        ));
                    }

                    bound[index] = parsed.value;
                    cursor = rawArgs.length;
                }
                else static if (isNullableType!ParamType)
                {
                    bound[index] = ParamType.init;
                }
                else static if (!is(Defaults[index] == void))
                {
                    bound[index] = Defaults[index];
                }
                else
                {
                    return Result!(CommandExecution, string).err(
                        missingArgumentMessage(commandName!member(), ParamNames[index], false)
                    );
                }
            }
            else
            {
                if (cursor < rawArgs.length)
                {
                    string source = rawArgs[cursor];
                    auto parsed = parseValue!ParamType(source, ctx);
                    if (parsed.isErr)
                    {
                        return Result!(CommandExecution, string).err(parseArgumentMessage(
                            commandName!member(),
                            ParamNames[index],
                            ParamType.stringof,
                            source,
                            parsed.error
                        ));
                    }

                    bound[index] = parsed.value;
                    cursor++;
                }
                else static if (isNullableType!ParamType)
                {
                    bound[index] = ParamType.init;
                }
                else static if (!is(Defaults[index] == void))
                {
                    bound[index] = Defaults[index];
                }
                else
                {
                    return Result!(CommandExecution, string).err(
                        missingArgumentMessage(commandName!member(), ParamNames[index], false)
                    );
                }
            }
        }
    }

    if (cursor < rawArgs.length)
    {
        return Result!(CommandExecution, string).err(formatError(
            "commands",
            "Too many prefix arguments were provided.",
            "Command `" ~ commandName!member() ~ "` received extra arguments starting at `" ~ rawArgs[cursor] ~ "`.",
            "Remove the extra input or mark the last string parameter as greedy if it should capture the remainder."
        ));
    }

    try
    {
        static if (is(ReturnType!member == void))
            mixin("instance." ~ __traits(identifier, member) ~ "(bound.expand);");
        else
            mixin("auto _ = instance." ~ __traits(identifier, member) ~ "(bound.expand);");
    }
    catch (Throwable error)
    {
        return Result!(CommandExecution, string).err(handlerFailureMessage(commandName!member(), error));
    }

    CommandExecution execution;
    execution.commandName = commandName!member();
    execution.replyCount = ctx.rest.messages.history.length;
    return Result!(CommandExecution, string).ok(execution);
}

private Result!(CommandExecution, string) invokeStatefulSlash(T, alias member)(
    T instance,
    CommandContext ctx,
    string[string] rawOptions
)
{
    alias ParamTypes = Parameters!member;
    alias ParamNames = ParameterIdentifierTuple!member;
    alias Defaults = ParameterDefaults!member;
    Tuple!ParamTypes bound;

    static foreach (index, ParamType; ParamTypes)
    {
        {
            static if (is(ParamType == CommandContext))
            {
                bound[index] = ctx;
            }
            else
            {
                auto optionValue = lookupSlashOption(rawOptions, defaultOptionName(ParamNames[index]));
                if (!optionValue.isNull)
                {
                    auto parsed = parseValue!ParamType(optionValue.get, ctx);
                    if (parsed.isErr)
                    {
                        return Result!(CommandExecution, string).err(parseArgumentMessage(
                            commandName!member(),
                            ParamNames[index],
                            ParamType.stringof,
                            optionValue.get,
                            parsed.error
                        ));
                    }

                    bound[index] = parsed.value;
                }
                else static if (isNullableType!ParamType)
                {
                    bound[index] = ParamType.init;
                }
                else static if (!is(Defaults[index] == void))
                {
                    bound[index] = Defaults[index];
                }
                else
                {
                    return Result!(CommandExecution, string).err(
                        missingArgumentMessage(commandName!member(), ParamNames[index], true)
                    );
                }
            }
        }
    }

    try
    {
        static if (is(ReturnType!member == void))
            mixin("instance." ~ __traits(identifier, member) ~ "(bound.expand);");
        else
            mixin("auto _ = instance." ~ __traits(identifier, member) ~ "(bound.expand);");
    }
    catch (Throwable error)
    {
        return Result!(CommandExecution, string).err(handlerFailureMessage(commandName!member(), error));
    }

    CommandExecution execution;
    execution.commandName = commandName!member();
    execution.replyCount = ctx.rest.messages.history.length;
    return Result!(CommandExecution, string).ok(execution);
}

private Nullable!string lookupSlashOption(string[string] rawOptions, string name)
{
    if (auto value = name in rawOptions)
        return Nullable!string.of(*value);
    return Nullable!string.init;
}

private string commandName(alias fn)()
{
    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (is(typeof(attr) == Command))
            return attr.name;
        else static if (is(typeof(attr) == HybridCommand))
            return attr.name;
        else static if (is(typeof(attr) == MessageCommand))
            return attr.name;
        else static if (is(typeof(attr) == UserCommand))
            return attr.name;
    }

    return __traits(identifier, fn);
}

private RestClient unittestRestClient()
{
    HttpTransport transport = (request) {
        HttpResponse response;
        response.statusCode = 200;

        JSONValue payload;
        if (request.body.length != 0)
            payload = parseJSON(cast(string) request.body);

        JSONValue message;
        message["id"] = "1";
        message["channel_id"] = "1";

        auto contentValue = payload.object.get("content", JSONValue.init);
        if (contentValue.type == JSONType.null_)
            message["content"] = "";
        else
            message["content"] = contentValue.str;

        JSONValue author;
        author["id"] = "999";
        author["username"] = "ddiscord";
        author["bot"] = true;
        message["author"] = author;

        response.body = cast(ubyte[]) message.toString().dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);
    return new RestClient(config);
}

unittest
{
    @Command("ping", routes: CommandRoute.Prefix)
    void ping(CommandContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(ping)(registry);

    auto parsed = registry.parsePrefix("!", "!ping").expect("parse failed");
    assert(parsed.name == "ping");
    assert(parsed.descriptor.get.displayName == "ping");
}

unittest
{
    @Command("roll")
    void roll(CommandContext ctx, long sides = 6, string reason = "dice")
    {
        auto _ = ctx;
        auto __ = sides;
        auto ___ = reason;
    }

    auto descriptor = describeHandler!roll();
    assert(descriptor.options.length == 2);
    assert(!descriptor.options[0].required);
    assert(!descriptor.options[1].required);
}

unittest
{
    @Command("sum", routes: CommandRoute.Prefix)
    void sum(CommandContext ctx, long left, long right)
    {
        ctx.reply((left + right).to!string).await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(sum)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;

    auto result = registry.executePrefix(ctx, "!", "!sum 2 3");
    assert(result.isOk);
    assert(rest.messages.history.length == 1);
    assert(rest.messages.history[0].content == "5");
}

unittest
{
    class MathService
    {
        long doubleIt(long value)
        {
            return value * 2;
        }
    }

    @Stateful
    struct MathCommands
    {
        @Inject MathService math;

        @Command("double", routes: CommandRoute.Prefix)
        void run(CommandContext ctx, long value)
        {
            auto _ = value;
            ctx.reply("18").await();
        }
    }

    auto services = new ServiceContainer;
    services.add!MathService(new MathService);
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registry.register!MathCommands();
    assert(!(services.get!MathCommands().math is null));

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;

    auto result = registry.executePrefix(ctx, "!", "!double 9");
    assert(result.isOk);
    assert(rest.messages.history[0].content == "18");
}

unittest
{
    @Command("secure", routes: CommandRoute.Prefix)
    @RequireOwner
    void secure(CommandContext ctx)
    {
        ctx.reply("ok").await();
    }

    auto services = new ServiceContainer;
    CommandExecutionSettings settings;
    settings.ownerId = Nullable!Snowflake.of(Snowflake(42));
    services.add!CommandExecutionSettings(settings);
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(secure)(registry);
    assert(describeHandler!secure().policy.ownerOnly);
    assert(services.has!CommandExecutionSettings());
    assert(!services.get!CommandExecutionSettings().ownerId.isNull);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;
    ctx.invoker.id = Snowflake(7);

    auto denied = registry.executePrefix(ctx, "!", "!secure");
    assert(denied.isErr);

    ctx.invoker.id = Snowflake(42);
    auto allowed = registry.executePrefix(ctx, "!", "!secure");
    assert(allowed.isOk);
}

unittest
{
    @Command("slow", routes: CommandRoute.Prefix)
    @RateLimit(1, dur!"seconds"(5), bucket: RateLimitBucket.User)
    void slow(CommandContext ctx)
    {
        ctx.reply("ok").await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(slow)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;
    ctx.invoker.id = Snowflake(99);

    auto first = registry.executePrefix(ctx, "!", "!slow");
    auto second = registry.executePrefix(ctx, "!", "!slow");

    assert(first.isOk);
    assert(second.isErr);
}

unittest
{
    @HybridCommand("echo", "Echoes text")
    void echo(CommandContext ctx, string text)
    {
        ctx.reply(text).await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(echo)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;
    ctx.source = CommandSource.Slash;

    string[string] options;
    options["text"] = "hello";

    auto result = registry.executeSlash(ctx, "echo", options);
    assert(result.isOk);
    assert(rest.messages.history.length == 1);
    assert(rest.messages.history[0].content == "hello");
}

unittest
{
    @HybridCommand("echo", "Echoes text")
    void echo(CommandContext ctx, string text)
    {
        auto _ = ctx;
        auto __ = text;
    }

    @MessageCommand("Inspect")
    void inspect(CommandContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(echo, inspect)(registry);

    auto definitions = registry.applicationCommands;
    assert(definitions.length == 2);
    assert(definitions[0].name == "echo");
    assert(definitions[0].type == ApplicationCommandType.ChatInput);
    assert(definitions[0].options.length == 1);
    assert(definitions[1].type == ApplicationCommandType.Message);
}
