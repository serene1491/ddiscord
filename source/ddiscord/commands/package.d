/**
 * ddiscord — UDA-first command system.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.commands;

public import ddiscord.command_types;

import core.sync.mutex : Mutex;
import core.time : Duration, MonoTime, dur;
import ddiscord.commands.contexts : CommandContextParameterCount, FirstCommandContextParameterType,
    hasExplicitHybridAttr, hasExplicitPrefixAttr, hasExplicitSlashAttr, isCommandContextParameter,
    resolveCommandContextParameter;
import ddiscord.commands.metadata : appendIntegrationTypes, appendInteractionContexts,
    normalizedIntegrationTypes, normalizedInteractionContexts, projectedContextsFromPolicy;
import ddiscord.client_text : tokenizePrefixContent;
import ddiscord.core.http.client : HttpError, HttpResponse, HttpTransport;
import ddiscord.context.autocomplete : AutocompleteContext;
import ddiscord.context.command : CommandContext, CommandSource, ContextMenuContext, HybridContext,
    PrefixContext, SlashContext;
import ddiscord.models.guild : Guild;
import ddiscord.models.application_command : ApplicationCommandDefinition, ApplicationCommandOption,
    ApplicationCommandOptionType, ApplicationCommandType, ApplicationIntegrationType,
    AutocompleteChoice,
    InteractionContextType;
import ddiscord.models.channel : Channel;
import ddiscord.models.member : GuildMember;
import ddiscord.permissions : missingPermissions, permissionNames;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient, RestClientConfig;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.limits : DiscordMaxAutocompleteChoices;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import ddiscord.models.role : Permissions;
import ddiscord.services : ServiceContainer;
import std.algorithm : canFind;
import std.ascii : isUpper, toLower;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : startsWith, strip;
import std.traits : ParameterDefaults, Parameters, ParameterIdentifierTuple, ReturnType,
    fullyQualifiedName, isCallable;
import std.typecons : Tuple;

private struct RateLimitWindowState
{
    MonoTime windowStart;
    uint used;
}

/// Built-in middleware that allows execution only in guild contexts.
CommandMiddleware guildOnlyMiddleware()
{
    return (CommandContext ctx) {
        if (!commandHasGuildScope(ctx))
        {
            return Result!(bool, string).err(formatError(
                "commands",
                "This command can only be used inside guild channels.",
                "",
                "Run this command in a server channel instead of direct messages."
            ));
        }

        return Result!(bool, string).ok(true);
    };
}

/// Built-in middleware that allows execution only in direct-message contexts.
CommandMiddleware directMessageOnlyMiddleware()
{
    return (CommandContext ctx) {
        if (commandHasGuildScope(ctx))
        {
            return Result!(bool, string).err(formatError(
                "commands",
                "This command can only be used in direct messages.",
                "",
                "Run this command in a DM conversation with the bot."
            ));
        }

        return Result!(bool, string).ok(true);
    };
}

/// Built-in middleware that enforces owner-only execution.
CommandMiddleware ownerOnlyMiddleware()
{
    return (CommandContext ctx) {
        auto settings = ctx.services.get!CommandExecutionSettings();
        if (settings.ownerId.isNull || settings.ownerId.get != ctx.user.id)
        {
            return Result!(bool, string).err(formatError(
                "commands",
                "This command is restricted to the configured bot owner.",
                "Invoker `" ~ ctx.user.id.toString ~ "` does not match the configured owner.",
                "Set `ClientConfig.ownerId` or remove the owner-only restriction."
            ));
        }

        return Result!(bool, string).ok(true);
    };
}

/// Registry that collects UDA-decorated handlers.
final class CommandRegistry
{
    private ServiceContainer _services;
    private CommandDescriptor[] _descriptors;
    private size_t[string] _prefixLookup;
    private size_t[string] _slashLookup;
    private size_t[string] _contextLookup;
    private RateLimitWindowState[string] _rateLimits;
    private Mutex _rateLimitMutex;
    private CommandMiddleware[] _globalMiddlewares;
    private CommandMiddleware[string] _namedMiddlewares;

    this(ServiceContainer services)
    {
        _services = services;
        _rateLimitMutex = new Mutex;
    }

    /// Registers free function handlers by alias.
    void registerAll(handlers...)(int _dummy = 0)
    {
        auto _ = _dummy;
        registerHandlers!handlers(this);
    }

    /// Registers a prebuilt descriptor.
    void registerDescriptor(CommandDescriptor descriptor)
    {
        if (descriptor.displayName.length == 0)
            return;
        validateDescriptorMetadata(descriptor);
        _descriptors ~= descriptor;
        rebuildLookupCaches();
    }

    /// Registers a middleware that runs before every command.
    void useMiddleware(CommandMiddleware middleware)
    {
        if (middleware is null)
            return;
        _globalMiddlewares ~= middleware;
    }

    /// Registers a reusable named middleware for `@UseMiddleware`.
    void registerMiddleware(string name, CommandMiddleware middleware)
    {
        auto normalized = name.strip;
        if (normalized.length == 0 || middleware is null)
            return;
        _namedMiddlewares[normalized] = middleware;
    }

    /// Removes descriptors matching the predicate.
    void removeWhere(bool delegate(const(CommandDescriptor)) predicate)
    {
        CommandDescriptor[] kept;

        foreach (descriptor; _descriptors)
        {
            if (!predicate(descriptor))
                kept ~= descriptor;
        }

        _descriptors = kept;
        rebuildLookupCaches();
    }

    /// Registers a stateful command group type.
    void register(T)()
    {
        injectServices!T();

        bool appended;

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
                            appended = registerMember!(T, memberName)(false) || appended;
                        }
                    }
                }
            }
        }

        if (appended)
            rebuildLookupCaches();
    }

    /// Registers a single stateful command member.
    bool registerMember(T, string memberName)(bool refreshLookup = true)
    {
        injectServices!T();

        auto descriptor = describeMember!(T, memberName)();
        if (descriptor.displayName.length != 0)
        {
            validateDescriptorMetadata(descriptor);
            _descriptors ~= descriptor;
            if (refreshLookup)
                rebuildLookupCaches();
            return true;
        }

        return false;
    }

    /// Returns the registered descriptors.
    CommandDescriptor[] descriptors() @property
    {
        return _descriptors.dup;
    }

    /// Finds a command by name and route.
    Nullable!CommandDescriptor find(string name, CommandRoute route = CommandRoute.Hybrid)
    {
        if (name.length == 0)
            return Nullable!CommandDescriptor.init;

        if (route == CommandRoute.Prefix)
        {
            if (auto index = name in _prefixLookup)
                return Nullable!CommandDescriptor.of(_descriptors[*index]);
            return Nullable!CommandDescriptor.init;
        }
        if (route == CommandRoute.Slash)
        {
            if (auto index = name in _slashLookup)
                return Nullable!CommandDescriptor.of(_descriptors[*index]);
            return Nullable!CommandDescriptor.init;
        }
        if (route == CommandRoute.ContextMenu)
        {
            if (auto index = name in _contextLookup)
                return Nullable!CommandDescriptor.of(_descriptors[*index]);
            return Nullable!CommandDescriptor.init;
        }

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

        auto body = content[prefix.length .. $];
        auto tokens = tokenize(body);
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
        parsed.descriptor = descriptor;

        auto rawArgs = prefixRawArguments(body);
        if (descriptorHasGreedyTail(descriptor.get))
            parsed.args = parsePrefixArgsWithGreedy(rawArgs, descriptor.get.options.length);
        else
            parsed.args = tokenize(rawArgs);

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

        return executeParsedPrefix(ctx, parsed.value);
    }

    /// Executes a previously parsed prefix invocation.
    Result!(CommandExecution, string) executeParsedPrefix(
        CommandContext ctx,
        ParsedCommand parsed
    )
    {
        enforce(!parsed.descriptor.isNull, "Parsed prefix commands must resolve to a registered descriptor.");

        auto descriptor = parsed.descriptor.get;
        auto policyError = validatePolicy(descriptor, ctx);
        if (!policyError.isNull)
            return Result!(CommandExecution, string).err(policyError.get);

        auto middlewareError = runMiddlewares(descriptor, ctx);
        if (!middlewareError.isNull)
            return Result!(CommandExecution, string).err(middlewareError.get);

        enforce(descriptor.prefixExecutor !is null, "Prefix executor was not registered for " ~ descriptor.displayName);
        return descriptor.prefixExecutor(ctx, parsed.args);
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

        auto middlewareError = runMiddlewares(resolved, ctx);
        if (!middlewareError.isNull)
            return Result!(CommandExecution, string).err(middlewareError.get);

        enforce(resolved.slashExecutor !is null, "Slash executor was not registered for " ~ resolved.displayName);
        return resolved.slashExecutor(ctx, options);
    }

    /// Executes a context-menu command by name.
    Result!(CommandExecution, string) executeContextMenu(
        CommandContext ctx,
        string name,
        string[string] options = null
    )
    {
        auto descriptor = find(name, CommandRoute.ContextMenu);
        if (descriptor.isNull)
        {
            return Result!(CommandExecution, string).err(formatError(
                "commands",
                "The requested context-menu command is not registered.",
                "Unknown command `" ~ name ~ "`.",
                "Sync commands again and ensure the handler is registered for context-menu routing."
            ));
        }

        auto resolved = descriptor.get;
        auto policyError = validatePolicy(resolved, ctx);
        if (!policyError.isNull)
            return Result!(CommandExecution, string).err(policyError.get);

        auto middlewareError = runMiddlewares(resolved, ctx);
        if (!middlewareError.isNull)
            return Result!(CommandExecution, string).err(middlewareError.get);

        enforce(resolved.slashExecutor !is null, "Context-menu executor was not registered for " ~ resolved.displayName);
        return resolved.slashExecutor(ctx, options);
    }

    /// Executes autocomplete handlers for a slash command option.
    Result!(AutocompleteChoice[], string) executeAutocomplete(
        CommandContext ctx,
        string name,
        string focusedName,
        string focusedValue,
        string[string] options = null,
        bool* handled = null
    )
    {
        auto descriptor = find(name, CommandRoute.Slash);
        if (descriptor.isNull)
        {
            if (handled !is null)
                *handled = false;
            return Result!(AutocompleteChoice[], string).ok(null);
        }

        auto resolved = descriptor.get;
        auto policyError = validatePolicy(resolved, ctx);
        if (!policyError.isNull)
            return Result!(AutocompleteChoice[], string).err(policyError.get);

        auto middlewareError = runMiddlewares(resolved, ctx);
        if (!middlewareError.isNull)
            return Result!(AutocompleteChoice[], string).err(middlewareError.get);

        if (resolved.autocompleteExecutor is null)
        {
            if (handled !is null)
                *handled = false;
            return Result!(AutocompleteChoice[], string).ok(null);
        }

        if (handled !is null)
            *handled = true;

        return resolved.autocompleteExecutor(ctx, focusedName, focusedValue, options);
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
            definition.type = descriptor.applicationType;
            definition.integrationTypes = normalizedIntegrationTypes(descriptor.integrationTypes);

            auto resolvedContexts = normalizedInteractionContexts(descriptor.contexts);
            if (resolvedContexts.length == 0)
                resolvedContexts = projectedContextsFromPolicy(descriptor.policy);
            definition.contexts = resolvedContexts;

            if (descriptor.applicationType == ApplicationCommandType.ChatInput)
            {
                definition.description = descriptor.description.length == 0
                    ? "Generated by ddiscord"
                    : descriptor.description;

                foreach (option; descriptor.options)
                {
                    ApplicationCommandOption definitionOption;
                    definitionOption.name = option.displayName;
                    definitionOption.description = option.description.length == 0
                        ? option.displayName
                        : option.description;
                    definitionOption.type = option.applicationType;
                    definitionOption.required = option.required;
                    definitionOption.autocomplete = option.autocomplete;
                    definitionOption.choices = option.choices.dup;
                    definitionOption.channelTypes = option.channelTypes.dup;
                    definition.options ~= definitionOption;
                }
            }

            definitions ~= definition;
        }

        return definitions;
    }

    /// Returns whether any registered command requires the configured owner.
    bool hasOwnerRestrictedCommands() const @property
    {
        foreach (descriptor; _descriptors)
        {
            if (descriptor.policy.ownerOnly)
                return true;
        }

        return false;
    }

    /// Returns the names of owner-restricted commands.
    string[] ownerRestrictedCommandNames() const @property
    {
        string[] names;

        foreach (descriptor; _descriptors)
        {
            if (descriptor.policy.ownerOnly)
                names ~= descriptor.displayName;
        }

        return names;
    }

    private void injectServices(T)()
    {
        if (_services.has!T())
            return;

        auto instance = instantiateStatefulOwner!T();

        static if (TypeHasInjectAttr!T)
        {
            injectMarkedFields(instance);
        }
        else
        {
            injectCompatibleFields(instance);
        }

        _services.add!T(instance);
    }

    private T instantiateStatefulOwner(T)()
    {
        static if (is(T == class))
        {
            static if (__traits(compiles, new T))
            {
                return new T;
            }
            else
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Could not create a stateful command group automatically.",
                    "Type `" ~ T.stringof ~ "` is a class without a default constructor.",
                    "Register an instance manually in `client.services` before registering this command group."
                ));
            }
        }
        else
        {
            return T.init;
        }
    }

    private void injectCompatibleFields(T)(ref T instance)
    {
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
    }

    private void injectMarkedFields(T)(ref T instance)
    {
        static foreach (memberName; __traits(allMembers, T))
        {
            static if (memberName != "__ctor" && memberName != "__xdtor")
            {
                mixin("alias memberSymbol = T." ~ memberName ~ ";");
                static if (!isCallable!memberSymbol)
                {
                    static if (HasInjectAttr!(T, memberName))
                    {
                        mixin("alias FieldType = typeof(instance." ~ memberName ~ ");");
                        auto resolved = _services.get!FieldType();
                        static if (__traits(compiles, mixin("instance." ~ memberName ~ " = resolved;")))
                        {
                            mixin("instance." ~ memberName ~ " = resolved;");
                        }
                    }
                }
            }
        }
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

        if (descriptor.policy.guildOnly && !commandHasGuildScope(ctx))
        {
            return Nullable!string.of(formatError(
                "commands",
                "This command can only run inside guild channels.",
                "",
                "Move this command to a server channel or remove `@GuildOnly`."
            ));
        }

        if (descriptor.policy.directMessageOnly && commandHasGuildScope(ctx))
        {
            return Nullable!string.of(formatError(
                "commands",
                "This command can only run in direct messages.",
                "",
                "Run this command via DM or remove `@DirectMessageOnly`."
            ));
        }

        if (descriptor.policy.requiredPermissions != 0)
        {
            if ((ctx.permissions & descriptor.policy.requiredPermissions) != descriptor.policy.requiredPermissions)
            {
                auto missing = missingPermissions(ctx.permissions, descriptor.policy.requiredPermissions);
                return Nullable!string.of(formatError(
                    "commands",
                    "The invoker does not satisfy the command permission requirements.",
                    "Missing permissions: `" ~ permissionNames(missing).join(", ") ~ "`. Required mask: `" ~
                        descriptor.policy.requiredPermissions.to!string ~ "`, provided mask: `" ~ ctx.permissions.to!string ~ "`.",
                    "Grant the required Discord permissions or remove `@RequirePermissions` from the command."
                ));
            }
        }

        if (descriptor.policy.hasRateLimit)
        {
            synchronized (_rateLimitMutex)
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
        }

        return Nullable!string.init;
    }

    private void rebuildLookupCaches()
    {
        _prefixLookup = null;
        _slashLookup = null;
        _contextLookup = null;

        foreach (index, descriptor; _descriptors)
        {
            if (descriptor.displayName.length == 0)
                continue;

            if (routeEnabled(descriptor.routes, CommandRoute.Prefix) &&
                descriptor.displayName !in _prefixLookup)
            {
                _prefixLookup[descriptor.displayName] = index;
            }

            if (
                descriptor.applicationType == ApplicationCommandType.ChatInput &&
                routeEnabled(descriptor.routes, CommandRoute.Slash) &&
                descriptor.displayName !in _slashLookup
            )
            {
                _slashLookup[descriptor.displayName] = index;
            }

            if (
                descriptor.applicationType != ApplicationCommandType.ChatInput &&
                routeEnabled(descriptor.routes, CommandRoute.ContextMenu) &&
                descriptor.displayName !in _contextLookup
            )
            {
                _contextLookup[descriptor.displayName] = index;
            }
        }
    }

    private Nullable!string runMiddlewares(CommandDescriptor descriptor, CommandContext ctx)
    {
        foreach (index, middleware; _globalMiddlewares)
        {
            auto result = middleware(ctx);
            if (result.isErr)
                return Nullable!string.of(result.error);
            if (!result.value)
            {
                return Nullable!string.of(formatError(
                    "commands",
                    "A global command middleware blocked this invocation.",
                    "Middleware index `" ~ index.to!string ~ "` returned `false`.",
                    "Return `Result.ok(true)` to allow execution or `Result.err(...)` with an explicit failure reason."
                ));
            }
        }

        foreach (name; descriptor.middlewareNames)
        {
            auto normalized = name.strip;
            if (normalized.length == 0)
                continue;

            auto middlewarePtr = normalized in _namedMiddlewares;
            if (middlewarePtr is null)
            {
                return Nullable!string.of(formatError(
                    "commands",
                    "The command references a middleware name that was not registered.",
                    "Missing middleware `" ~ normalized ~ "` for command `" ~ descriptor.displayName ~ "`.",
                    "Call `client.registerMiddleware(\"" ~ normalized ~ "\", ...)` before executing this command."
                ));
            }

            auto result = (*middlewarePtr)(ctx);
            if (result.isErr)
                return Nullable!string.of(result.error);
            if (!result.value)
            {
                return Nullable!string.of(formatError(
                    "commands",
                    "A command middleware blocked this invocation.",
                    "Middleware `" ~ normalized ~ "` returned `false` for `" ~ descriptor.displayName ~ "`.",
                    "Return `Result.ok(true)` to allow execution or `Result.err(...)` with an explicit failure reason."
                ));
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

private bool commandHasGuildScope(CommandContext ctx)
{
    if (!ctx.currentGuild.isNull)
        return true;

    if (!ctx.message.isNull && !ctx.message.get.guildId.isNull)
        return true;

    if (!ctx.interaction.isNull && !ctx.interaction.get.guildId.isNull)
        return true;

    return false;
}

private void registerHandlers(handlers...)(CommandRegistry registry)
{
    bool appended;

    static foreach (handler; handlers)
    {
        {
            auto descriptor = describeHandler!handler();
            if (descriptor.displayName.length != 0)
            {
                descriptor.prefixExecutor = buildFreePrefixExecutor!handler();
                descriptor.slashExecutor = buildFreeSlashExecutor!handler();
                descriptor.autocompleteExecutor = buildFreeAutocompleteExecutor!handler();
                validateDescriptorMetadata(descriptor);
                registry._descriptors ~= descriptor;
                appended = true;
            }
        }
    }

    if (appended)
        registry.rebuildLookupCaches();
}

private CommandDescriptor describeHandler(alias fn)()
{
    CommandDescriptor descriptor;
    descriptor.symbolName = __traits(identifier, fn);
    descriptor.qualifiedName = fullyQualifiedName!fn;
    descriptor.sourceModule = qualifiedModuleName(descriptor.qualifiedName);
    descriptor.sourceFile = symbolSourceFile!fn();
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
        else static if (is(typeof(attr) == SlashCommand))
        {
            descriptor.displayName = attr.name;
            descriptor.description = attr.description;
            descriptor.routes = CommandRoute.Slash;
            descriptor.applicationType = ApplicationCommandType.ChatInput;
        }
        else static if (is(typeof(attr) == PrefixCommand))
        {
            descriptor.displayName = attr.name;
            descriptor.description = attr.description;
            descriptor.routes = CommandRoute.Prefix;
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
        else static if (is(typeof(attr) == CommandInstallTypes))
        {
            appendIntegrationTypes(descriptor.integrationTypes, attr.values);
        }
        else static if (AttrIs!(attr, GuildInstalled))
        {
            appendIntegrationTypes(descriptor.integrationTypes, [ApplicationIntegrationType.GuildInstall]);
        }
        else static if (AttrIs!(attr, UserInstalled))
        {
            appendIntegrationTypes(descriptor.integrationTypes, [ApplicationIntegrationType.UserInstall]);
        }
        else static if (is(typeof(attr) == CommandContexts))
        {
            appendInteractionContexts(descriptor.contexts, attr.values);
        }
        else static if (AttrIs!(attr, GuildContextOnly))
        {
            appendInteractionContexts(descriptor.contexts, [InteractionContextType.Guild]);
        }
        else static if (AttrIs!(attr, BotDmOnly))
        {
            appendInteractionContexts(descriptor.contexts, [InteractionContextType.BotDM]);
        }
        else static if (AttrIs!(attr, PrivateChannelOnly))
        {
            appendInteractionContexts(descriptor.contexts, [InteractionContextType.PrivateChannel]);
        }
        else static if (AttrIs!(attr, UserInstalledDmOnly))
        {
            appendIntegrationTypes(descriptor.integrationTypes, [ApplicationIntegrationType.UserInstall]);
            appendInteractionContexts(descriptor.contexts, [InteractionContextType.BotDM]);
        }
        else static if (AttrIs!(attr, UserInstalledPrivateOnly))
        {
            appendIntegrationTypes(descriptor.integrationTypes, [ApplicationIntegrationType.UserInstall]);
            appendInteractionContexts(descriptor.contexts, [InteractionContextType.PrivateChannel]);
        }
        else static if (AttrIs!(attr, DmContextOnly))
        {
            appendInteractionContexts(
                descriptor.contexts,
                [InteractionContextType.BotDM, InteractionContextType.PrivateChannel]
            );
        }
        else static if (AttrIs!(attr, GuildInstalledGuildOnly))
        {
            appendIntegrationTypes(descriptor.integrationTypes, [ApplicationIntegrationType.GuildInstall]);
            appendInteractionContexts(descriptor.contexts, [InteractionContextType.Guild]);
        }
        else static if (AttrIs!(attr, UserInstalledEverywhere))
        {
            appendIntegrationTypes(descriptor.integrationTypes, [ApplicationIntegrationType.UserInstall]);
            appendInteractionContexts(
                descriptor.contexts,
                [InteractionContextType.Guild, InteractionContextType.BotDM, InteractionContextType.PrivateChannel]
            );
        }
        else static if (AttrIs!(attr, InstalledEverywhere))
        {
            appendIntegrationTypes(
                descriptor.integrationTypes,
                [ApplicationIntegrationType.GuildInstall, ApplicationIntegrationType.UserInstall]
            );
        }
        else static if (AttrIs!(attr, RequireOwner))
        {
            descriptor.policy.ownerOnly = true;
        }
        else static if (AttrIs!(attr, GuildOnly))
        {
            descriptor.policy.guildOnly = true;
        }
        else static if (AttrIs!(attr, DirectMessageOnly))
        {
            descriptor.policy.directMessageOnly = true;
        }
        else static if (is(typeof(attr) == RequirePermissions))
        {
            descriptor.policy.requiredPermissions = attr.permissions;
        }
        else static if (is(typeof(attr) == UseMiddleware))
        {
            auto middlewareName = attr.name.strip;
            if (middlewareName.length != 0)
                descriptor.middlewareNames ~= middlewareName;
        }
        else static if (is(typeof(attr) == RateLimit))
        {
            descriptor.policy.hasRateLimit = true;
            descriptor.policy.rateLimitCount = attr.count;
            descriptor.policy.rateLimitWindow = attr.window;
            descriptor.policy.rateLimitBucket = attr.bucket;
        }
        else static if (is(typeof(attr) == CommandCategory))
        {
            descriptor.category = attr.name;
        }
        else static if (AttrIs!(attr, HideFromHelp))
        {
            descriptor.hiddenFromHelp = true;
        }
    }

    if (!hasCommandAttr!fn)
        descriptor.displayName = "";
    else
    {
        validateHandlerContextCompatibility!fn(descriptor);
        validateAutocompleteMetadata!fn(descriptor);
    }

    return descriptor;
}

private CommandDescriptor describeMember(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    auto descriptor = describeHandler!memberSymbol();
    descriptor.stateful = true;
    descriptor.ownerType = T.stringof;
    descriptor.ownerQualifiedName = fullyQualifiedName!T;
    if (descriptor.sourceModule.length == 0)
        descriptor.sourceModule = qualifiedModuleName(descriptor.ownerQualifiedName);
    descriptor.prefixExecutor = buildStatefulPrefixExecutor!(T, memberName)();
    descriptor.slashExecutor = buildStatefulSlashExecutor!(T, memberName)();
    descriptor.autocompleteExecutor = buildStatefulAutocompleteExecutor!(T, memberName)();
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
    string[] explicitAutocompleteOptionNames;
    bool hasImplicitAutocomplete;
    alias ParamTypes = Parameters!fn;
    alias ParamNames = ParameterIdentifierTuple!fn;
    alias Defaults = ParameterDefaults!fn;

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (HasAutocompleteAttr!attr)
        {
            if (autocompleteAttrOptionName!attr.length != 0)
                explicitAutocompleteOptionNames ~= defaultOptionName(autocompleteAttrOptionName!attr);
            else
                hasImplicitAutocomplete = true;
        }
    }

    static foreach (index, ParamType; ParamTypes)
    {
        static if (!isCommandContextParameter!ParamType)
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

    foreach (name; explicitAutocompleteOptionNames)
    {
        foreach (ref option; options)
        {
            if (option.displayName == name)
                option.autocomplete = true;
        }
    }

    if (hasImplicitAutocomplete && options.length == 1)
        options[0].autocomplete = true;

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
            is(typeof(attr) == SlashCommand) ||
            is(typeof(attr) == PrefixCommand) ||
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

private bool descriptorHasApplicationSyncRoute(CommandDescriptor descriptor)
{
    if (descriptor.applicationType == ApplicationCommandType.ChatInput)
        return routeEnabled(descriptor.routes, CommandRoute.Slash);
    return routeEnabled(descriptor.routes, CommandRoute.ContextMenu);
}

private void validateDescriptorMetadata(CommandDescriptor descriptor)
{
    if (descriptor.policy.guildOnly && descriptor.policy.directMessageOnly)
    {
        throw new DdiscordException(formatError(
            "commands",
            "A command cannot be both guild-only and direct-message-only.",
            "Command `" ~ descriptor.displayName ~ "` defines `@GuildOnly` and `@DirectMessageOnly` together.",
            "Remove one of these policy UDAs so the command has a valid execution scope."
        ));
    }

    auto explicitContexts = normalizedInteractionContexts(descriptor.contexts);
    if (descriptor.policy.guildOnly && explicitContexts.length != 0)
    {
        foreach (context; explicitContexts)
        {
            if (context != InteractionContextType.Guild)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "A guild-only command cannot expose DM/private command contexts.",
                    "Command `" ~ descriptor.displayName ~ "` uses `@GuildOnly` with non-guild `@CommandContexts` values.",
                    "Keep only `InteractionContextType.Guild` or remove `@GuildOnly`."
                ));
            }
        }
    }

    if (descriptor.policy.directMessageOnly && explicitContexts.length != 0)
    {
        foreach (context; explicitContexts)
        {
            if (context == InteractionContextType.Guild)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "A DM-only command cannot expose guild command contexts.",
                    "Command `" ~ descriptor.displayName ~ "` uses `@DirectMessageOnly` with `InteractionContextType.Guild`.",
                    "Use only `InteractionContextType.BotDM`/`PrivateChannel` or remove `@DirectMessageOnly`."
                ));
            }
        }
    }

    if (
        !descriptorHasApplicationSyncRoute(descriptor) &&
        (descriptor.integrationTypes.length != 0 || descriptor.contexts.length != 0)
    )
    {
        throw new DdiscordException(formatError(
            "commands",
            "Command install/context UDAs require an application-command route.",
            "Command `" ~ descriptor.displayName ~ "` is prefix-only but defines install/context metadata.",
            "Use `@SlashCommand`/`@Command(..., routes: CommandRoute.Slash|Hybrid)` or remove install/context UDAs."
        ));
    }
}

private void validateHandlerContextCompatibility(alias fn)(CommandDescriptor descriptor)
{
    alias ParamTypes = Parameters!fn;
    enum contextParamCount = CommandContextParameterCount!ParamTypes;
    enum explicitHybrid = hasExplicitHybridAttr!fn;
    enum explicitPrefix = hasExplicitPrefixAttr!fn;
    enum explicitSlash = hasExplicitSlashAttr!fn;
    static assert(
        contextParamCount <= 1,
        "Command handlers support at most one command context parameter (`CommandContext`, `PrefixContext`, `SlashContext`, `HybridContext`, or `ContextMenuContext`)."
    );

    static if (contextParamCount == 0)
        return;
    else
    {
        alias CtxType = FirstCommandContextParameterType!ParamTypes;

        static if (explicitHybrid)
        {
            static if (!is(CtxType == HybridContext))
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "`@HybridCommand` handlers must use `HybridContext` for typed route access.",
                    "Handler `" ~ commandName!fn() ~ "` uses `" ~ CtxType.stringof ~ "`.",
                    "Change the handler signature to `HybridContext` to keep prefix/slash behavior explicit."
                ));
            }
        }
        static if (explicitPrefix)
        {
            static if (!is(CtxType == PrefixContext))
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "`@PrefixCommand` handlers must use `PrefixContext` for typed prefix access.",
                    "Handler `" ~ commandName!fn() ~ "` uses `" ~ CtxType.stringof ~ "`.",
                    "Change the handler signature to `PrefixContext`."
                ));
            }
        }
        static if (explicitSlash)
        {
            static if (!is(CtxType == SlashContext))
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "`@SlashCommand` handlers must use `SlashContext` for typed slash access.",
                    "Handler `" ~ commandName!fn() ~ "` uses `" ~ CtxType.stringof ~ "`.",
                    "Change the handler signature to `SlashContext`."
                ));
            }
        }

        if (descriptor.applicationType == ApplicationCommandType.User ||
            descriptor.applicationType == ApplicationCommandType.Message)
        {
            static if (!is(CtxType == CommandContext) && !is(CtxType == ContextMenuContext))
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Context-menu handlers require `CommandContext` or `ContextMenuContext`.",
                    "Handler `" ~ commandName!fn() ~ "` uses `" ~ CtxType.stringof ~ "`.",
                    "Use `ContextMenuContext` for typed context-menu handlers."
                ));
            }

            return;
        }

        static if (is(CtxType == PrefixContext))
        {
            if (descriptor.routes != CommandRoute.Prefix)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Prefix-only handler context cannot be used with non-prefix command routes.",
                    "Handler `" ~ commandName!fn() ~ "` uses `PrefixContext` but routes are `" ~ descriptor.routes.to!string ~ "`.",
                    "Use `CommandContext` or `HybridContext`, or switch the command route to prefix-only."
                ));
            }
        }
        else static if (is(CtxType == SlashContext))
        {
            if (descriptor.routes != CommandRoute.Slash)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Slash-only handler context cannot be used with non-slash command routes.",
                    "Handler `" ~ commandName!fn() ~ "` uses `SlashContext` but routes are `" ~ descriptor.routes.to!string ~ "`.",
                    "Use `CommandContext` or `HybridContext`, or switch the command route to slash-only."
                ));
            }
        }
        else static if (is(CtxType == HybridContext))
        {
            if (descriptor.routes != CommandRoute.Hybrid)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Hybrid handler context requires a hybrid command route.",
                    "Handler `" ~ commandName!fn() ~ "` uses `HybridContext` but routes are `" ~ descriptor.routes.to!string ~ "`.",
                    "Use `CommandContext` for single-route commands or expose the command as hybrid."
                ));
            }
        }
        else static if (is(CtxType == ContextMenuContext))
        {
            if (descriptor.applicationType == ApplicationCommandType.ChatInput)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Context-menu handler context cannot be used for chat-input commands.",
                    "Handler `" ~ commandName!fn() ~ "` uses `ContextMenuContext`.",
                    "Use `SlashContext`, `PrefixContext`, `HybridContext`, or `CommandContext`."
                ));
            }
        }
    }
}

private void validateAutocompleteMetadata(alias fn)(CommandDescriptor descriptor)
{
    if (!routeEnabled(descriptor.routes, CommandRoute.Slash))
    {
        static foreach (attr; __traits(getAttributes, fn))
        {
            static if (HasAutocompleteAttr!attr)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Autocomplete handlers require slash-capable command routes.",
                    "Command `" ~ descriptor.displayName ~ "` defines `@Autocomplete` without a slash route.",
                    "Use `@SlashCommand`, `@HybridCommand`, or set `@Command(..., routes: CommandRoute.Slash|Hybrid)`."
                ));
            }
        }

        return;
    }

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (HasAutocompleteAttr!attr)
        {
            auto targetName = autocompleteTargetName!fn(autocompleteAttrOptionName!attr);
            if (targetName.length == 0)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Implicit autocomplete target is ambiguous.",
                    "Command `" ~ descriptor.displayName ~ "` has `@Autocomplete` without an explicit option while exposing multiple options.",
                    "Pass the option explicitly, e.g. `@Autocomplete!handler(\"option-name\")`."
                ));
            }

            bool foundOption;
            ApplicationCommandOptionType targetType = ApplicationCommandOptionType.String;
            foreach (option; descriptor.options)
            {
                if (option.displayName == targetName)
                {
                    foundOption = true;
                    targetType = option.applicationType;
                    break;
                }
            }

            if (!foundOption)
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Autocomplete target option was not found in command parameters.",
                    "Command `" ~ descriptor.displayName ~ "` references option `" ~ targetName ~ "`.",
                    "Use a parameter name (or configured option name) that exists in the command signature."
                ));
            }

            if (
                targetType != ApplicationCommandOptionType.String &&
                targetType != ApplicationCommandOptionType.Integer &&
                targetType != ApplicationCommandOptionType.Number
            )
            {
                throw new DdiscordException(formatError(
                    "commands",
                    "Autocomplete is only supported for string/integer/number slash options.",
                    "Command `" ~ descriptor.displayName ~ "` targets option `" ~ targetName ~ "` of type `" ~ targetType.to!string ~ "`.",
                    "Use a string/integer/number option for autocomplete targets."
                ));
            }
        }
    }
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
    return tokenizePrefixContent(input);
}

private bool isPrefixWhitespace(char ch)
{
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
}

private string prefixRawArguments(string body)
{
    size_t cursor = 0;
    while (cursor < body.length && isPrefixWhitespace(body[cursor]))
        cursor++;
    while (cursor < body.length && !isPrefixWhitespace(body[cursor]))
        cursor++;
    while (cursor < body.length && isPrefixWhitespace(body[cursor]))
        cursor++;
    return body[cursor .. $];
}

private bool descriptorHasGreedyTail(CommandDescriptor descriptor)
{
    if (descriptor.options.length == 0)
        return false;
    return descriptor.options[$ - 1].greedy;
}

private string[] parsePrefixArgsWithGreedy(string rawArgs, size_t optionCount)
{
    if (optionCount == 0)
        return tokenize(rawArgs);

    if (optionCount == 1)
    {
        if (rawArgs.length == 0)
            return null;
        return [rawArgs];
    }

    auto requiredLeadingCount = optionCount - 1;
    string[] leading;
    auto tailStart = consumePrefixLeadingTokens(rawArgs, requiredLeadingCount, leading);
    if (tailStart == size_t.max)
        return tokenize(rawArgs);

    string[] args = leading.dup;
    if (tailStart < rawArgs.length)
        args ~= rawArgs[tailStart .. $];
    return args;
}

private size_t consumePrefixLeadingTokens(string rawArgs, size_t count, out string[] tokens)
{
    tokens = null;
    if (count == 0)
        return 0;

    bool inQuote;
    char quote;
    bool preserveQuoteChars;
    string current;

    foreach (index, ch; rawArgs)
    {
        if (inQuote)
        {
            if (ch == quote)
            {
                if (preserveQuoteChars)
                    current ~= ch;
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
            preserveQuoteChars = current.length != 0;
            if (preserveQuoteChars)
                current ~= ch;
            continue;
        }

        if (isPrefixWhitespace(ch))
        {
            if (current.length == 0)
                continue;

            tokens ~= current;
            current = null;
            if (tokens.length == count)
            {
                auto cursor = index + 1;
                while (cursor < rawArgs.length && isPrefixWhitespace(rawArgs[cursor]))
                    cursor++;
                return cursor;
            }
            continue;
        }

        current ~= ch;
    }

    if (current.length != 0)
    {
        tokens ~= current;
        if (tokens.length == count)
            return rawArgs.length;
    }

    return size_t.max;
}

private template HasInjectAttr(T, string memberName)
{
    enum bool HasInjectAttr = HasInjectAttrImpl!(__traits(getAttributes, __traits(getMember, T, memberName)));
}

private template TypeHasInjectAttr(T)
{
    enum bool TypeHasInjectAttr = TypeHasInjectAttrImpl!(T, __traits(allMembers, T));
}

private template TypeHasInjectAttrImpl(T, members...)
{
    static if (members.length == 0)
    {
        enum bool TypeHasInjectAttrImpl = false;
    }
    else static if (members[0] == "__ctor" || members[0] == "__xdtor")
    {
        enum bool TypeHasInjectAttrImpl = TypeHasInjectAttrImpl!(T, members[1 .. $]);
    }
    else
    {
        mixin("alias memberSymbol = T." ~ members[0] ~ ";");
        static if (!isCallable!memberSymbol && HasInjectAttr!(T, members[0]))
            enum bool TypeHasInjectAttrImpl = true;
        else
            enum bool TypeHasInjectAttrImpl = TypeHasInjectAttrImpl!(T, members[1 .. $]);
    }
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

private template HasAutocompleteAttr(alias attr)
{
    static if (__traits(compiles, typeof(attr)))
        enum bool HasAutocompleteAttr = is(typeof(attr) == Autocomplete!handler, alias handler);
    else
        enum bool HasAutocompleteAttr = is(attr == Autocomplete!handler, alias handler);
}

private template AutocompleteAttrHandler(alias attr)
{
    static if (__traits(compiles, typeof(attr)))
    {
        static if (is(typeof(attr) == Autocomplete!handler, alias handler))
            alias AutocompleteAttrHandler = handler;
    }
    else
    {
        static if (is(attr == Autocomplete!handler, alias handler))
            alias AutocompleteAttrHandler = handler;
    }
}

private string autocompleteAttrOptionName(alias attr)()
{
    static if (__traits(compiles, typeof(attr)))
        return attr.optionName;
    else
        return "";
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

private string handlerFailureMessage(string commandName, Exception error)
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

private Result!(AutocompleteChoice[], string) delegate(CommandContext, string, string, string[string]) buildFreeAutocompleteExecutor(alias fn)()
{
    Result!(AutocompleteChoice[], string) delegate(CommandContext, string, string, string[string]) executor;
    executor = (CommandContext ctx, string focusedName, string focusedValue, string[string] options) {
        return invokeFreeAutocomplete!fn(ctx, focusedName, focusedValue, options);
    };
    return executor;
}

private Result!(AutocompleteChoice[], string) delegate(CommandContext, string, string, string[string]) buildStatefulAutocompleteExecutor(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    Result!(AutocompleteChoice[], string) delegate(CommandContext, string, string, string[string]) executor;
    executor = (CommandContext ctx, string focusedName, string focusedValue, string[string] options) {
        auto _ = ctx.services.get!T();
        return invokeFreeAutocomplete!memberSymbol(ctx, focusedName, focusedValue, options);
    };
    return executor;
}

private Result!(AutocompleteChoice[], string) invokeFreeAutocomplete(alias fn)(
    CommandContext ctx,
    string focusedName,
    string focusedValue,
    string[string] options
)
{
    auto _ = options;

    if (focusedName.length == 0)
    {
        return Result!(AutocompleteChoice[], string).err(formatError(
            "commands",
            "Autocomplete interactions require a focused option name.",
            "Command `" ~ commandName!fn() ~ "` did not receive the focused option metadata.",
            "Ensure the Discord interaction payload includes a focused option and call `receiveInteraction` with the raw interaction."
        ));
    }

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (HasAutocompleteAttr!attr)
        {
            alias handler = AutocompleteAttrHandler!attr;

            if (autocompleteAttrOptionName!attr.length == 0)
                return runAutocompleteHandler!handler(ctx, focusedName, focusedValue);

            auto targetName = autocompleteTargetName!fn(autocompleteAttrOptionName!attr);
            if (targetName == focusedName)
                return runAutocompleteHandler!handler(ctx, focusedName, focusedValue);
        }
    }

    return Result!(AutocompleteChoice[], string).ok(null);
}

private Result!(AutocompleteChoice[], string) runAutocompleteHandler(alias handler)(
    CommandContext ctx,
    string focusedName,
    string focusedValue
)
{
    AutocompleteContext autocomplete;
    autocomplete.focusedName = focusedName;
    autocomplete.focusedValue = focusedValue;

    try
    {
        alias HandlerParams = Parameters!handler;
        static if (is(ReturnType!handler == void))
        {
            static if (HandlerParams.length == 1 && is(HandlerParams[0] == string))
            {
                handler(focusedValue);
            }
            else static if (HandlerParams.length == 1 && is(HandlerParams[0] == AutocompleteContext))
            {
                handler(autocomplete);
            }
            else static if (HandlerParams.length == 2 && is(HandlerParams[0] == string) && is(HandlerParams[1] == CommandContext))
            {
                handler(focusedValue, ctx);
            }
            else static if (HandlerParams.length == 2 &&
                is(HandlerParams[0] == AutocompleteContext) &&
                is(HandlerParams[1] == CommandContext))
            {
                handler(autocomplete, ctx);
            }
            else
            {
                static assert(
                    false,
                    "Unsupported autocomplete handler signature. Supported signatures are:\n"
                    ~ "  void handler(string)\n"
                    ~ "  void handler(string, CommandContext)\n"
                    ~ "  void handler(AutocompleteContext)\n"
                    ~ "  void handler(AutocompleteContext, CommandContext)\n"
                    ~ "  AutocompleteChoice[] handler(string)\n"
                    ~ "  AutocompleteChoice[] handler(string, CommandContext)\n"
                    ~ "  AutocompleteChoice[] handler(AutocompleteContext)\n"
                    ~ "  AutocompleteChoice[] handler(AutocompleteContext, CommandContext)"
                );
            }

            return Result!(AutocompleteChoice[], string).ok(normalizeAutocompleteChoices(autocomplete.choices));
        }
        else static if (is(ReturnType!handler == AutocompleteChoice[]))
        {
            AutocompleteChoice[] choices;

            static if (HandlerParams.length == 1 && is(HandlerParams[0] == string))
            {
                choices = handler(focusedValue);
            }
            else static if (HandlerParams.length == 1 && is(HandlerParams[0] == AutocompleteContext))
            {
                choices = handler(autocomplete);
            }
            else static if (HandlerParams.length == 2 && is(HandlerParams[0] == string) && is(HandlerParams[1] == CommandContext))
            {
                choices = handler(focusedValue, ctx);
            }
            else static if (HandlerParams.length == 2 &&
                is(HandlerParams[0] == AutocompleteContext) &&
                is(HandlerParams[1] == CommandContext))
            {
                choices = handler(autocomplete, ctx);
            }
            else
            {
                static assert(
                    false,
                    "Unsupported autocomplete handler signature. Supported signatures are:\n"
                    ~ "  void handler(string)\n"
                    ~ "  void handler(string, CommandContext)\n"
                    ~ "  void handler(AutocompleteContext)\n"
                    ~ "  void handler(AutocompleteContext, CommandContext)\n"
                    ~ "  AutocompleteChoice[] handler(string)\n"
                    ~ "  AutocompleteChoice[] handler(string, CommandContext)\n"
                    ~ "  AutocompleteChoice[] handler(AutocompleteContext)\n"
                    ~ "  AutocompleteChoice[] handler(AutocompleteContext, CommandContext)"
                );
            }

            return Result!(AutocompleteChoice[], string).ok(normalizeAutocompleteChoices(choices));
        }
        else
        {
            static assert(
                false,
                "Autocomplete handlers must return `void` or `AutocompleteChoice[]`."
            );
        }
    }
    catch (Exception error)
    {
        return Result!(AutocompleteChoice[], string).err(formatError(
            "commands",
            "The autocomplete handler raised an exception.",
            "Handler `" ~ __traits(identifier, handler) ~ "` failed with `" ~ error.msg ~ "`.",
            "Catch domain errors inside your autocomplete handler or return an empty choice list on failure."
        ));
    }
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
        static if (isCommandContextParameter!ParamType)
        {
            auto resolved = resolveCommandContextParameter!ParamType(ctx);
            if (resolved.isErr)
                return Result!(CommandExecution, string).err(resolved.error);
            bound[index] = resolved.value;
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
            "Remove the extra input or use a final `string` parameter to capture the remainder."
        ));
    }

    try
    {
        static if (is(ReturnType!fn == void))
            fn(bound.expand);
        else
            auto _ = fn(bound.expand);
    }
    catch (Exception error)
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
            static if (isCommandContextParameter!ParamType)
            {
                auto resolved = resolveCommandContextParameter!ParamType(ctx);
                if (resolved.isErr)
                    return Result!(CommandExecution, string).err(resolved.error);
                bound[index] = resolved.value;
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
    catch (Exception error)
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
        static if (isCommandContextParameter!ParamType)
        {
            auto resolved = resolveCommandContextParameter!ParamType(ctx);
            if (resolved.isErr)
                return Result!(CommandExecution, string).err(resolved.error);
            bound[index] = resolved.value;
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
            "Remove the extra input or use a final `string` parameter to capture the remainder."
        ));
    }

    try
    {
        static if (is(ReturnType!member == void))
            mixin("instance." ~ __traits(identifier, member) ~ "(bound.expand);");
        else
            mixin("auto _ = instance." ~ __traits(identifier, member) ~ "(bound.expand);");
    }
    catch (Exception error)
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
            static if (isCommandContextParameter!ParamType)
            {
                auto resolved = resolveCommandContextParameter!ParamType(ctx);
                if (resolved.isErr)
                    return Result!(CommandExecution, string).err(resolved.error);
                bound[index] = resolved.value;
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
    catch (Exception error)
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

private string implicitAutocompleteTargetName(alias fn)()
{
    alias ParamTypes = Parameters!fn;
    alias ParamNames = ParameterIdentifierTuple!fn;

    size_t optionCount = 0;
    string onlyOptionName;

    static foreach (index, ParamType; ParamTypes)
    {
        static if (!isCommandContextParameter!ParamType)
        {
            optionCount++;
            if (optionCount == 1)
                onlyOptionName = defaultOptionName(ParamNames[index]);
        }
    }

    if (optionCount == 1)
        return onlyOptionName;

    return "";
}

private string autocompleteTargetName(alias fn)(string configuredOptionName)
{
    if (configuredOptionName.length != 0)
        return defaultOptionName(configuredOptionName);
    return implicitAutocompleteTargetName!fn();
}

private AutocompleteChoice[] normalizeAutocompleteChoices(scope const(AutocompleteChoice)[] choices)
{
    AutocompleteChoice[] normalized;

    foreach (choice; choices)
    {
        if (choice.name.length == 0 || choice.value.length == 0)
            continue;

        normalized ~= choice;
        if (normalized.length >= DiscordMaxAutocompleteChoices)
            break;
    }

    return normalized;
}

private string commandName(alias fn)()
{
    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (is(typeof(attr) == Command))
            return attr.name;
        else static if (is(typeof(attr) == HybridCommand))
            return attr.name;
        else static if (is(typeof(attr) == SlashCommand))
            return attr.name;
        else static if (is(typeof(attr) == PrefixCommand))
            return attr.name;
        else static if (is(typeof(attr) == MessageCommand))
            return attr.name;
        else static if (is(typeof(attr) == UserCommand))
            return attr.name;
    }

    return __traits(identifier, fn);
}

private string qualifiedModuleName(string qualifiedName)
{
    size_t lastDot = size_t.max;

    foreach (index, ch; qualifiedName)
    {
        if (ch == '.')
            lastDot = index;
    }

    if (lastDot == size_t.max)
        return qualifiedName;

    return qualifiedName[0 .. lastDot];
}

private string symbolSourceFile(alias fn)()
{
    static if (__traits(compiles, __traits(getLocation, fn)))
    {
        return __traits(getLocation, fn)[0];
    }
    else
    {
        return "";
    }
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
    @Command("save-script", routes: CommandRoute.Prefix)
    void saveScript(CommandContext ctx, string name, string scopeValue, @Greedy string source)
    {
        auto _ = name;
        auto __ = scopeValue;
        ctx.send(source).await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(saveScript)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;

    auto result = registry.executePrefix(
        ctx,
        "&",
        `&save-script say2 server log.info("hello world")`
    );
    assert(result.isOk, result.error);
    assert(rest.messages.history.length == 1);
    assert(rest.messages.history[0].content == `log.info("hello world")`);
}

unittest
{
    @Stateful
    struct GreedyStatefulCommands
    {
        @Command("echo-script", routes: CommandRoute.Prefix)
        void echoScript(CommandContext ctx, string name, @Greedy string source)
        {
            auto _ = name;
            ctx.send(source).await();
        }
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registry.register!GreedyStatefulCommands();

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;

    auto result = registry.executePrefix(
        ctx,
        "!",
        `!echo-script say2 log.info("hello world")`
    );
    assert(result.isOk, result.error);
    assert(rest.messages.history.length == 1);
    assert(rest.messages.history[0].content == `log.info("hello world")`);
}

unittest
{
    @Command("save-script", routes: CommandRoute.Prefix)
    void saveScript(CommandContext ctx, string name, string scopeValue, @Greedy string source)
    {
        auto _ = name;
        auto __ = scopeValue;
        ctx.send(source).await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(saveScript)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;

    auto payload = "&save-script nether server\n"
        ~ "-- Built-in guide script: nether\n"
        ~ "local function trim(value)\n"
        ~ "    return (value:gsub(\"^%s+\", \"\"):gsub(\"%s+$\", \"\"))\n"
        ~ "end\n";

    auto result = registry.executePrefix(ctx, "&", payload);
    assert(result.isOk, result.error);
    assert(rest.messages.history.length == 1);
    assert(rest.messages.history[0].content.canFind("-- Built-in guide script: nether\n"));
    assert(rest.messages.history[0].content.canFind("gsub(\"^%s+\", \"\")"));
    assert(rest.messages.history[0].content.canFind("\nlocal function trim(value)\n"));
}

unittest
{
    @PrefixCommand("legacy")
    void legacy(PrefixContext ctx)
    {
        auto _ = ctx;
    }

    @SlashCommand("modern")
    void modern(SlashContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(legacy, modern)(registry);

    assert(!registry.find("legacy", CommandRoute.Prefix).isNull);
    assert(!registry.find("modern", CommandRoute.Slash).isNull);
    assert(registry.find("modern", CommandRoute.Prefix).isNull);

    registry.removeWhere((descriptor) => descriptor.displayName == "legacy");
    assert(registry.find("legacy", CommandRoute.Prefix).isNull);
    assert(!registry.find("modern", CommandRoute.Slash).isNull);
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
        ctx.send((left + right).to!string).await();
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
            ctx.send("18").await();
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
        ctx.send("ok").await();
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
        ctx.send("ok").await();
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
    void echo(HybridContext ctx, string text)
    {
        ctx.send(text).await();
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
    @Command("whoami", routes: CommandRoute.Prefix)
    void whoami(PrefixContext ctx)
    {
        assert(ctx.isPrefix);
        ctx.send("prefix").await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(whoami)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;
    ctx.source = CommandSource.Prefix;

    auto result = registry.executePrefix(ctx, "!", "!whoami");
    assert(result.isOk);
    assert(rest.messages.history[$ - 1].content == "prefix");
}

unittest
{
    @HybridCommand("route", "Inspect hybrid route")
    void route(HybridContext ctx, string text = "")
    {
        assert(ctx.fromSlash);
        assert(!ctx.slash.isNull);
        assert(ctx.prefix.isNull);
        ctx.send("hybrid:" ~ text).await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(route)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;
    ctx.source = CommandSource.Slash;

    string[string] options;
    options["text"] = "ok";

    auto result = registry.executeSlash(ctx, "route", options);
    assert(result.isOk);
    assert(rest.messages.history[$ - 1].content == "hybrid:ok");
}

unittest
{
    @HybridCommand("echo", "Echoes text")
    void echo(HybridContext ctx, string text)
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

unittest
{
    @UserCommand("inspect-user")
    void inspectUser(ContextMenuContext ctx)
    {
        assert(ctx.isContextMenu);
        ctx.send("context-ok").await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(inspectUser)(registry);

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;
    ctx.source = CommandSource.ContextMenu;

    auto result = registry.executeContextMenu(ctx, "inspect-user");
    assert(result.isOk);
    assert(rest.messages.history.length == 1);
    assert(rest.messages.history[0].content == "context-ok");

    auto wrongRoute = registry.executeSlash(ctx, "inspect-user");
    assert(wrongRoute.isErr);
}

unittest
{
    @SlashCommand("whoami", "Inspect user command install/context metadata")
    @UserInstalled
    @GuildInstalled
    @CommandContexts(InteractionContextType.Guild, InteractionContextType.PrivateChannel)
    void whoami(SlashContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(whoami)(registry);

    auto definitions = registry.applicationCommands;
    assert(definitions.length == 1);
    assert(definitions[0].name == "whoami");
    assert(definitions[0].integrationTypes.length == 2);
    assert(definitions[0].integrationTypes.canFind(ApplicationIntegrationType.GuildInstall));
    assert(definitions[0].integrationTypes.canFind(ApplicationIntegrationType.UserInstall));
    assert(definitions[0].contexts.length == 2);
    assert(definitions[0].contexts[0] == InteractionContextType.Guild);
    assert(definitions[0].contexts[1] == InteractionContextType.PrivateChannel);
}

unittest
{
    @PrefixCommand("guild-maint")
    @GuildOnly
    void guildMaint(PrefixContext ctx)
    {
        auto _ = ctx;
    }

    @SlashCommand("dm-utility")
    @DirectMessageOnly
    void dmUtility(SlashContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(guildMaint, dmUtility)(registry);

    auto definitions = registry.applicationCommands;
    assert(definitions.length == 1);
    assert(definitions[0].name == "dm-utility");
    assert(definitions[0].contexts.length == 2);
    assert(definitions[0].contexts.canFind(InteractionContextType.BotDM));
    assert(definitions[0].contexts.canFind(InteractionContextType.PrivateChannel));
}

unittest
{
    @SlashCommand("dm-only-install")
    @UserInstalledDmOnly
    void dmInstall(SlashContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(dmInstall)(registry);

    auto definitions = registry.applicationCommands;
    assert(definitions.length == 1);
    assert(definitions[0].integrationTypes.length == 1);
    assert(definitions[0].integrationTypes[0] == ApplicationIntegrationType.UserInstall);
    assert(definitions[0].contexts.length == 1);
    assert(definitions[0].contexts[0] == InteractionContextType.BotDM);
}

unittest
{
    @PrefixCommand("broken")
    @UserInstalled
    void broken(PrefixContext ctx)
    {
        auto _ = ctx;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(broken)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("prefix-only"));
    }

    assert(threw);
}

unittest
{
    @SlashCommand("context-conflict")
    @GuildOnly
    @CommandContexts(InteractionContextType.BotDM)
    void contextConflict(SlashContext ctx)
    {
        auto _ = ctx;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(contextConflict)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("cannot expose DM/private command contexts"));
    }

    assert(threw);
}

unittest
{
    @SlashCommand("conflicted")
    @GuildOnly
    @DirectMessageOnly
    void conflicted(SlashContext ctx)
    {
        auto _ = ctx;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(conflicted)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("cannot be both guild-only and direct-message-only"));
    }

    assert(threw);
}

unittest
{
    @HybridCommand("wrong-context")
    void wrongContext(SlashContext ctx)
    {
        auto _ = ctx;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(wrongContext)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("must use `HybridContext`"));
    }

    assert(threw);
}

unittest
{
    @SlashCommand("wrong-slash-context")
    void wrongSlashContext(CommandContext ctx)
    {
        auto _ = ctx;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(wrongSlashContext)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("must use `SlashContext`"));
    }

    assert(threw);
}

unittest
{
    @PrefixCommand("wrong-prefix-context")
    void wrongPrefixContext(CommandContext ctx)
    {
        auto _ = ctx;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(wrongPrefixContext)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("must use `PrefixContext`"));
    }

    assert(threw);
}

unittest
{
    AutocompleteChoice[] completeSong(string partial, CommandContext ctx)
    {
        auto _ = ctx;
        return [
            AutocompleteChoice("Song " ~ partial, partial ~ "-1"),
            AutocompleteChoice("Song " ~ partial ~ " 2", partial ~ "-2"),
        ];
    }

    @SlashCommand("play", "Play a song")
    @Autocomplete!completeSong("song")
    void play(SlashContext ctx, string song)
    {
        auto _ = ctx;
        auto __ = song;
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    registerHandlers!(play)(registry);

    CommandContext ctx;
    ctx.services = services;
    ctx.source = CommandSource.Slash;

    bool handled;
    auto result = registry.executeAutocomplete(ctx, "play", "song", "hel", null, &handled);
    assert(result.isOk);
    assert(handled);
    assert(result.value.length == 2);
    assert(result.value[0].name == "Song hel");

    auto definitions = registry.applicationCommands;
    assert(definitions.length == 1);
    assert(definitions[0].options.length == 1);
    assert(definitions[0].options[0].autocomplete);
}

unittest
{
    AutocompleteChoice[] completeSingle(string partial)
    {
        return [AutocompleteChoice("Echo " ~ partial, partial)];
    }

    @SlashCommand("echo-auto", "Autocomplete a single option")
    @Autocomplete!completeSingle
    void echoAuto(SlashContext ctx, string text)
    {
        auto _ = ctx;
        auto __ = text;
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    registerHandlers!(echoAuto)(registry);

    CommandContext ctx;
    ctx.services = services;
    ctx.source = CommandSource.Slash;

    bool handled;
    auto result = registry.executeAutocomplete(ctx, "echo-auto", "text", "hi", null, &handled);
    assert(result.isOk);
    assert(handled);
    assert(result.value.length == 1);
    assert(result.value[0].value == "hi");
}

unittest
{
    AutocompleteChoice[] completeAny(string partial)
    {
        return [AutocompleteChoice(partial, partial)];
    }

    @SlashCommand("ambiguous", "Ambiguous implicit autocomplete")
    @Autocomplete!completeAny
    void ambiguous(SlashContext ctx, string first, string second)
    {
        auto _ = ctx;
        auto __ = first;
        auto ___ = second;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(ambiguous)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("Implicit autocomplete target is ambiguous"));
    }

    assert(threw);
}

unittest
{
    AutocompleteChoice[] prefixAutocomplete(string partial)
    {
        return [AutocompleteChoice(partial, partial)];
    }

    @PrefixCommand("prefix-auto")
    @Autocomplete!prefixAutocomplete("query")
    void prefixAuto(PrefixContext ctx, string query)
    {
        auto _ = ctx;
        auto __ = query;
    }

    bool threw;
    try
    {
        auto registry = new CommandRegistry(new ServiceContainer);
        registerHandlers!(prefixAuto)(registry);
    }
    catch (DdiscordException error)
    {
        threw = true;
        assert(error.msg.canFind("Autocomplete handlers require slash-capable command routes"));
    }

    assert(threw);
}

unittest
{
    @SlashCommand("install-combos")
    @InstalledEverywhere
    @GuildInstalledGuildOnly
    @DmContextOnly
    void installCombos(SlashContext ctx)
    {
        auto _ = ctx;
    }

    auto registry = new CommandRegistry(new ServiceContainer);
    registerHandlers!(installCombos)(registry);
    auto definitions = registry.applicationCommands;

    assert(definitions.length == 1);
    assert(definitions[0].integrationTypes.length == 2);
    assert(definitions[0].integrationTypes.canFind(ApplicationIntegrationType.GuildInstall));
    assert(definitions[0].integrationTypes.canFind(ApplicationIntegrationType.UserInstall));
    assert(definitions[0].contexts.length == 3);
    assert(definitions[0].contexts.canFind(InteractionContextType.Guild));
    assert(definitions[0].contexts.canFind(InteractionContextType.BotDM));
    assert(definitions[0].contexts.canFind(InteractionContextType.PrivateChannel));
}

unittest
{
    @Command("mod-only", routes: CommandRoute.Prefix)
    @UseMiddleware("must-be-guild")
    void modOnly(CommandContext ctx)
    {
        ctx.send("ok").await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(modOnly)(registry);
    registry.registerMiddleware("must-be-guild", guildOnlyMiddleware());

    CommandContext dmCtx;
    dmCtx.rest = rest;
    dmCtx.services = services;
    dmCtx.currentGuild = Nullable!Guild.init;
    auto denied = registry.executePrefix(dmCtx, "!", "!mod-only");
    assert(denied.isErr);
    assert(denied.error.canFind("guild channels"));

    CommandContext guildCtx;
    guildCtx.rest = rest;
    guildCtx.services = services;
    Guild guild;
    guild.id = Snowflake(55);
    guildCtx.currentGuild = Nullable!Guild.of(guild);
    auto allowed = registry.executePrefix(guildCtx, "!", "!mod-only");
    assert(allowed.isOk);
}

unittest
{
    @Command("global-mid", routes: CommandRoute.Prefix)
    void globalMid(CommandContext ctx)
    {
        ctx.send("ok").await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(globalMid)(registry);
    registry.useMiddleware((CommandContext ctx) {
        auto _ = ctx;
        return Result!(bool, string).err("blocked by global middleware");
    });

    CommandContext ctx;
    ctx.rest = rest;
    ctx.services = services;

    auto blocked = registry.executePrefix(ctx, "!", "!global-mid");
    assert(blocked.isErr);
    assert(blocked.error.canFind("blocked by global middleware"));
}

unittest
{
    @Command("guild", routes: CommandRoute.Prefix)
    @GuildOnly
    void guildCommand(CommandContext ctx)
    {
        ctx.send("ok").await();
    }

    @Command("dm", routes: CommandRoute.Prefix)
    @DirectMessageOnly
    void dmCommand(CommandContext ctx)
    {
        ctx.send("ok").await();
    }

    auto services = new ServiceContainer;
    auto registry = new CommandRegistry(services);
    auto rest = unittestRestClient();
    registerHandlers!(guildCommand, dmCommand)(registry);

    CommandContext dmCtx;
    dmCtx.rest = rest;
    dmCtx.services = services;
    auto guildDenied = registry.executePrefix(dmCtx, "!", "!guild");
    assert(guildDenied.isErr);

    CommandContext guildCtx;
    guildCtx.rest = rest;
    guildCtx.services = services;
    Guild guild;
    guild.id = Snowflake(1);
    guildCtx.currentGuild = Nullable!Guild.of(guild);

    auto guildAllowed = registry.executePrefix(guildCtx, "!", "!guild");
    assert(guildAllowed.isOk);

    auto dmDenied = registry.executePrefix(guildCtx, "!", "!dm");
    assert(dmDenied.isErr);
    auto dmAllowed = registry.executePrefix(dmCtx, "!", "!dm");
    assert(dmAllowed.isOk);
}
