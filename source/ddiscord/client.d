/**
 * ddiscord — client façade.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client;

public import ddiscord.client_types : CommandErrorBehavior, CommandErrorContext, CommandErrorKind,
    CommandHelpBehavior, CommandHelpEntry, CommandHelpPage, CommandRegistrationFilter,
    DispatchQueueHealth;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;
import ddiscord.cache : CacheStore;
import ddiscord.client_errors : buildFailurePayload, classifyCommandFailure, shouldSurfaceFailure;
import ddiscord.client_filters : matchesRegistrationFilter;
import ddiscord.client_event_contexts : ClientEventContextBuilders;
import ddiscord.client_queue : DispatchQueuePushOutcome, compactQueue, pushBounded, queueDepth;
import ddiscord.client_runtime : UptimeSample, snowflakeLatencyMilliseconds;
import ddiscord.client_text : attemptedPrefixCommandName;
import ddiscord.client_types : HelpRequest, RegistrationCandidate;
import ddiscord.commands : Command, CommandCategory, CommandDescriptor, CommandExecution,
    CommandExecutionSettings, CommandMiddleware, CommandOptionDescriptor, CommandRegistry,
    CommandRoute, Autocomplete, HideFromHelp, HybridCommand, Inject, MessageCommand, ParsedCommand, PrefixCommand,
    RequireOwner, RequirePermissions, SlashCommand, Task, TaskMode, UserCommand, directMessageOnlyMiddleware,
    guildOnlyMiddleware, ownerOnlyMiddleware;
import ddiscord.context.command : CommandContext, CommandSource, ContextMenuContext, HybridContext,
    SlashContext;
import ddiscord.context.event : AutocompleteInteractionEventContext, CommandExecutedEventContext,
    ChannelCreateEventContext, ChannelDeleteEventContext, ChannelPinsUpdateEventContext,
    ChannelUpdateEventContext, CommandFailedEventContext, EventContext, GuildCreateEventContext,
    GuildDeleteEventContext, GuildMemberAddEventContext, GuildMemberRemoveEventContext,
    GuildBanAddEventContext, GuildBanRemoveEventContext, GuildRoleCreateEventContext,
    GuildRoleDeleteEventContext, GuildRoleUpdateEventContext, InteractionCreateEventContext,
    InviteCreateEventContext, InviteDeleteEventContext, MessageComponentEventContext,
    MessageCreateEventContext, MessageDeleteEventContext, MessageReactionAddEventContext,
    MessageReactionRemoveAllEventContext, MessageReactionRemoveEmojiEventContext,
    MessageReactionRemoveEventContext, MessageUpdateEventContext, ModalSubmitEventContext,
    PresenceUpdateEventContext, ReadyEventContext, ResumedEventContext,
    ThreadCreateEventContext, ThreadDeleteEventContext, ThreadUpdateEventContext,
    TypingStartEventContext, WebhooksUpdateEventContext;
import ddiscord.events.dispatcher : Event, EventDispatcher;
import ddiscord.events.types : AutocompleteInteractionEvent, CommandExecutedEvent,
    ChannelCreateEvent, ChannelDeleteEvent, ChannelPinsUpdateEvent, ChannelUpdateEvent,
    CommandFailedEvent, GuildCreateEvent, GuildDeleteEvent, GuildMemberAddEvent,
    GuildMemberRemoveEvent, GuildBanAddEvent, GuildBanRemoveEvent, GuildRoleCreateEvent,
    GuildRoleDeleteEvent, GuildRoleUpdateEvent, InteractionCreateEvent, InviteCreateEvent,
    InviteDeleteEvent, MessageComponentEvent, MessageCreateEvent, MessageDeleteEvent,
    MessageReactionAddEvent, MessageReactionRemoveAllEvent, MessageReactionRemoveEmojiEvent,
    MessageReactionRemoveEvent, MessageUpdateEvent, ModalSubmitEvent, PresenceUpdateEvent,
    ReadyEvent, ResumedEvent, ThreadCreateEvent, ThreadDeleteEvent, ThreadUpdateEvent,
    TypingStartEvent, WebhooksUpdateEvent;
import ddiscord.gateway.client : GatewayClient, GatewayClientConfig, GatewayGuildMemberAddInfo,
    GatewayGuildMemberRemoveInfo, GatewayGuildBanInfo, GatewayGuildRoleDeleteInfo,
    GatewayGuildRoleInfo, GatewayInviteInfo, GatewayMessageDeleteInfo,
    GatewayMessageReactionInfo, GatewayMessageReactionRemoveAllInfo,
    GatewayPresenceUpdateInfo, GatewayReadyInfo, GatewayThreadDeleteInfo,
    GatewayTypingStartInfo, GatewayWebhooksUpdateInfo, GatewayChannelPinsUpdateInfo;
import ddiscord.gateway.intents : GatewayIntent;
import ddiscord.help.navigation : BuiltInHelpCustomIdPrefix, BuiltInHelpDefaultPageSize,
    BuiltInHelpNoopCustomId, buildPersistentHelpCustomId, parsePersistentHelpCustomId;
import ddiscord.help.rendering : defaultComponentsHelpPage, defaultEmbeddedHelpPage;
import ddiscord.logging : LogLevel, Logger;
import ddiscord.models.application_command : ApplicationCommandDefinition, ApplicationCommandOption,
    ApplicationCommandOptionType, ApplicationCommandType, AutocompleteChoice, InteractionType;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild, UnavailableGuild;
import ddiscord.models.interaction : Interaction, InteractionOption;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message, MessageCreate;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.role : Permissions, Role;
import ddiscord.models.user : User;
import ddiscord.plugins : LuaPlugin, PluginRegistry;
import ddiscord.permissions : computeEffectivePermissions;
import ddiscord.core.http.client : HttpError, HttpErrorKind, HttpRequest, HttpResponse, HttpTransport;
import ddiscord.rest : ApplicationCommandsEndpoints, ApplicationsEndpoints, ChannelsEndpoints,
    GatewayBotInfo, GatewayEndpoints, GuildsEndpoints, InteractionsEndpoints, MessagesEndpoints,
    ReactionsEndpoints, RestClient, RestClientConfig, ThreadsEndpoints, UsersEndpoints,
    WebhooksEndpoints;
import ddiscord.scripting : LuaCapability, LuaRuntime, LuaSandboxProfile, ScriptingEngine;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.tasks : TaskScheduler;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.algorithm : canFind, sort;
import std.ascii : toLower;
import std.conv : ConvException, to;
import std.string : startsWith, strip;
import std.traits : Parameters, fullyQualifiedName, isCallable;
import std.typecons : Tuple;

/// Client configuration.
private enum DefaultMaxDispatchQueueSize = 4096;
private enum DefaultDispatchOverflowLogEvery = 100;

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
}

private enum GatewayReadyWatchdogLabel = "gateway-ready-watchdog";
private enum GatewayAutoReshardWatchdogLabel = "gateway-auto-reshard-watchdog";

private struct ShardRuntime
{
    uint shardId;
    GatewayClient gateway;
    Thread thread;
}

private struct DispatchItem
{
    enum Kind
    {
        Message,
        Interaction,
    }

    Kind kind;
    Message message;
    Interaction interaction;
    Channel channel;
    ulong permissions;
}

/// High-level client façade for the MVP library.
final class Client
{
    ClientConfig config;
    ServiceContainer services;
    CommandRegistry commands;
    EventDispatcher events;
    PluginRegistry plugins;
    TaskScheduler tasks;
    RestClient rest;
    CacheStore cache;
    StateStore state;
    Logger logger;
    UptimeSample uptime;
    private bool _running;
    private StatusType _status = StatusType.Online;
    private Activity _activity;
    private User _selfUser;
    private Nullable!GatewayBotInfo _gatewayInfo;
    private GatewayClient _gateway;
    private Thread _gatewayThread;
    private ShardRuntime[] _shards;
    private Thread _dispatchThread;
    private Thread _taskThread;
    private bool _taskLoopRunning;
    private bool _dispatchLoopRunning;
    private bool _pluginsActive;
    private Mutex _dispatchMutex;
    private Condition _dispatchAvailable;
    private DispatchItem[] _dispatchQueue;
    private size_t _dispatchQueueHead;
    private ulong _nextHelpQueryTokenId;
    private size_t _peakDispatchQueueDepth;
    private ulong _droppedDispatchItems;

    this(ClientConfig config)
    {
        this.config = config;
        services = new ServiceContainer;
        commands = new CommandRegistry(services);
        events = new EventDispatcher;
        plugins = new PluginRegistry;
        tasks = new TaskScheduler;
        logger = new Logger(config.logLevel);
        RestClientConfig restConfig;
        restConfig.token = config.token;
        restConfig.applicationId = config.applicationId;
        if (!config.transport.isNull)
            restConfig.transport = config.transport;
        rest = new RestClient(restConfig);
        cache = new CacheStore;
        state = new StateStore;
        plugins.logger = logger;
        plugins.security.allowLooseScripts = config.allowLoosePlugins;
        plugins.security.allowEntrypointOutsidePluginDirectory = config.allowPluginEntrypointEscape;
        plugins.security.requireDeclaredPermissionsForUntrusted = config.requireExplicitPluginPermissions;
        tasks.logger = logger;
        _dispatchMutex = new Mutex;
        _dispatchAvailable = new Condition(_dispatchMutex);

        services.add!Client(this);
        services.add!ServiceContainer(services);
        services.add!CommandRegistry(commands);
        services.add!EventDispatcher(events);
        services.add!PluginRegistry(plugins);
        services.add!TaskScheduler(tasks);
        services.add!RestClient(rest);
        services.add!CacheStore(cache);
        services.add!StateStore(state);
        services.add!Logger(logger);
        services.add!ScriptingEngine(new ScriptingEngine);
        services.add!CommandHelpBehavior(new CommandHelpBehavior);
        services.add!CommandErrorBehavior(new CommandErrorBehavior);
        syncCommandExecutionSettings();
        registerBuiltInCommandMiddlewares();
        _selfUser.bot = true;
        _selfUser.username = "ddiscord";
        events.on!MessageComponentEvent((event) {
            handleBuiltInComponent(event);
        });
    }

    /// Starts the client.
    void run()
    {
        if (_running || _shards.length != 0 || _dispatchThread !is null || _taskThread !is null)
        {
            throw new DdiscordException(formatError(
                "client",
                "The Discord client is already running.",
                "",
                "Create a new `Client` instance or call `stop()` and wait for shutdown before starting again."
            ));
        }

        if (config.token.length == 0)
        {
            throw new DdiscordException(formatError(
                "client",
                "Client startup requires a Discord bot token.",
                "",
                "Set `ClientConfig.token` to your bot token before calling `run()`."
            ));
        }

        auto me = rest.users.me().awaitResult();
        if (me.isErr)
            throw new DdiscordException(me.error);

        auto gateway = rest.gateway.bot().awaitResult();
        if (gateway.isErr)
            throw new DdiscordException(gateway.error);

        syncCommandExecutionSettings();
        _running = true;
        uptime.reset();
        uptime.markStarted();
        resetDispatchQueue();
        _selfUser = me.value;
        _gatewayInfo = Nullable!GatewayBotInfo.of(gateway.value);
        logger.information("client", "Authenticated as `" ~ _selfUser.username ~ "` (" ~ _selfUser.id.toString ~ ").");
        logOwnerConfiguration();
        plugins.loadAll(config.pluginsDir);
        plugins.activateAll(services.get!ScriptingEngine(), state);
        _pluginsActive = true;
        if (config.autoSyncCommands)
            syncCommandsIfChanged();

        cache.store(_selfUser);
        logger.information("client", "Starting gateway and worker loops.");
        startDispatchLoop();
        startTaskLoop();
        configureAutoReshardWatchdog();
        startGateways(gateway.value.url);
    }

    /// Registers an event handler.
    void on(E)(void delegate(E) handler)
    {
        events.on!E(handler);
    }

    /// Registers a one-shot event handler.
    void once(E)(void delegate(E) handler)
    {
        events.once!E(handler);
    }

    /// Emits an event.
    void emit(E)(E event)
    {
        events.emit!E(event);
    }

    /// Registers a middleware that runs before every command execution.
    void useMiddleware(CommandMiddleware middleware)
    {
        commands.useMiddleware(middleware);
    }

    /// Registers a named middleware usable through `@UseMiddleware("name")`.
    void registerMiddleware(string name, CommandMiddleware middleware)
    {
        commands.registerMiddleware(name, middleware);
    }

    /// Registers or replaces a runtime service instance.
    void addService(T)(T instance)
    {
        services.add!T(instance);
    }

    /// Registers a default-constructed runtime service.
    void addService(T)()
        if (is(T == class) || is(T == struct))
    {
        services.add!T();
    }

    /// Registers a runtime service produced by a factory callback.
    void addServiceFactory(T)(T delegate() factory)
    {
        services.addFactory!T(factory);
    }

    /// Registers multiple runtime services in declaration order.
    void addServices(T...)(T instances)
    {
        static foreach (index, Service; T)
            services.add!Service(instances[index]);
    }

    /// Returns a runtime service by type.
    T service(T)()
    {
        return services.get!T();
    }

    /// Tries to resolve a runtime service by type.
    bool tryService(T)(out T value)
    {
        return services.tryGet!T(value);
    }

    /// Removes a runtime service registration.
    void removeService(T)()
    {
        services.remove!T();
    }

    /// Returns dispatch-loop queue telemetry for production monitoring.
    DispatchQueueHealth dispatchQueueHealth() @property
    {
        DispatchQueueHealth health;
        synchronized (_dispatchMutex)
        {
            health.queued = queueDepth(_dispatchQueue, _dispatchQueueHead);
            health.peakQueued = _peakDispatchQueueDepth;
            health.maxQueued = config.maxDispatchQueueSize;
            health.droppedTotal = _droppedDispatchItems;
        }
        return health;
    }

    /// Updates presence.
    void setPresence(StatusType status, Activity activity)
    {
        _status = status;
        _activity = activity;
        foreach (ref shard; _shards)
        {
            if (shard.gateway !is null)
                shard.gateway.updatePresence(status, activity);
        }

        PresenceUpdateEvent event;
        event.status = status;
        event.activity = activity;
        event.context = buildPresenceUpdateEventContext(status, activity);
        emit!PresenceUpdateEvent(event);
    }

    /// Direct shortcut to message REST endpoints.
    MessagesEndpoints messages() @property
    {
        return rest.messages;
    }

    /// Direct shortcut to user REST endpoints.
    UsersEndpoints users() @property
    {
        return rest.users;
    }

    /// Direct shortcut to application REST endpoints.
    ApplicationsEndpoints apps() @property
    {
        return rest.applications;
    }

    /// Long-form alias for `apps`.
    ApplicationsEndpoints applications() @property
    {
        return rest.applications;
    }

    /// Direct shortcut to gateway REST endpoints.
    GatewayEndpoints gatewayApi() @property
    {
        return rest.gateway;
    }

    /// Direct shortcut to guild REST endpoints.
    GuildsEndpoints guilds() @property
    {
        return rest.guilds;
    }

    /// Direct shortcut to channel REST endpoints.
    ChannelsEndpoints channels() @property
    {
        return rest.channels;
    }

    /// Direct shortcut to reaction REST endpoints.
    ReactionsEndpoints reactions() @property
    {
        return rest.reactions;
    }

    /// Direct shortcut to thread REST endpoints.
    ThreadsEndpoints threads() @property
    {
        return rest.threads;
    }

    /// Direct shortcut to webhook REST endpoints.
    WebhooksEndpoints webhooks() @property
    {
        return rest.webhooks;
    }

    /// Direct shortcut to interaction REST endpoints.
    InteractionsEndpoints interactions() @property
    {
        return rest.interactions;
    }

    /// Direct shortcut to application-command REST endpoints.
    ApplicationCommandsEndpoints slash() @property
    {
        return rest.applicationCommands;
    }

    /// Configures the built-in help command behavior.
    CommandHelpBehavior helpBehavior() @property
    {
        return services.get!CommandHelpBehavior();
    }

    /// Configures how command failures are surfaced back to users.
    CommandErrorBehavior errorBehavior() @property
    {
        return services.get!CommandErrorBehavior();
    }

    /// Builds a command context for an incoming prefix message.
    CommandContext prefixContext(
        string content,
        User invoker = User.init,
        Channel channel = Channel.init
    )
    {
        CommandContext ctx;
        ctx.source = CommandSource.Prefix;
        ctx.rest = rest;
        ctx.services = services;
        ctx.cache = cache;
        ctx.state = state;
        ctx.invoker = invoker;
        ctx.currentChannel = channel;

        Message message;
        message.content = content;
        message.author = invoker;
        message.channelId = channel.id;
        ctx.message = Nullable!Message.of(message);
        if (!message.guildId.isNull)
            ctx.currentGuild = lookupGuild(message.guildId);

        return ctx;
    }

    /// Builds a command context for an incoming interaction.
    CommandContext interactionContext(Interaction interaction, Channel channel = Channel.init)
    {
        CommandContext ctx;
        if (interaction.type == InteractionType.ApplicationCommandAutocomplete)
            ctx.source = CommandSource.Slash;
        else if (
            interaction.type == InteractionType.ApplicationCommand &&
            interaction.commandType != ApplicationCommandType.ChatInput
        )
            ctx.source = CommandSource.ContextMenu;
        else
            ctx.source = CommandSource.Slash;
        ctx.rest = rest;
        ctx.services = services;
        ctx.cache = cache;
        ctx.state = state;
        ctx.invoker = interaction.user;
        ctx.currentChannel = channel;
        if (!interaction.guildId.isNull)
            ctx.currentGuild = lookupGuild(interaction.guildId);
        ctx.currentMember = interaction.member;
        ctx.interaction = Nullable!Interaction.of(interaction);
        return ctx;
    }

    /// Parses an incoming prefix message against the command registry.
    Result!(CommandExecution, string) processPrefixMessage(
        string content,
        User invoker = User.init,
        Channel channel = Channel.init,
        ulong permissions = 0
    )
    {
        syncCommandExecutionSettings();
        auto ctx = prefixContext(content, invoker, channel);
        ctx.permissions = permissions;
        return commands.executePrefix(ctx, config.prefix, content);
    }

    /// Syncs slash and context-menu definitions to Discord REST.
    ApplicationCommandDefinition[] syncCommands()
    {
        syncBuiltInCommandSystems();
        auto synced = rest.applicationCommands.sync(commands.applicationCommands).await();
        logger.information("client", "Synchronized " ~ synced.length.to!string ~ " application command(s) with Discord.");
        return synced;
    }

    /// Syncs commands only if the remote manifest differs from the generated one.
    ApplicationCommandDefinition[] syncCommandsIfChanged()
    {
        syncBuiltInCommandSystems();
        auto local = commands.applicationCommands;
        auto remoteResult = rest.applicationCommands.list().awaitResult();
        if (remoteResult.isErr)
            throw new DdiscordException(remoteResult.error);

        if (sameCommands(remoteResult.value, local))
        {
            logger.information("client", "Application commands are already in sync with Discord.");
            return remoteResult.value;
        }

        auto synced = rest.applicationCommands.sync(local).await();
        logger.information("client", "Updated the Discord command manifest with " ~ synced.length.to!string ~ " definition(s).");
        return synced;
    }

    /// Registers free command handlers.
    void registerCommands(handlers...)()
    {
        commands.registerAll!handlers(0);
        syncBuiltInCommandSystems();
    }

    /// Registers every command declared in the calling module, with optional filters.
    void registerCommands(string moduleName = __MODULE__)(CommandRegistrationFilter filter = CommandRegistrationFilter.init)
    {
        registerModuleMembers!(moduleName, true, false, false, false)(filter);
        syncBuiltInCommandSystems();
    }

    /// Registers free event handlers declared with `@Event`.
    void registerEvents(handlers...)()
    {
        static foreach (handler; handlers)
            registerFreeEvent!handler();
    }

    /// Registers free scheduled task handlers declared with `@Task`.
    void registerTasks(handlers...)()
    {
        static foreach (handler; handlers)
            registerFreeTask!handler();
    }

    /// Registers mixed command handlers, command groups, and plugin types.
    void registerAllCommands(symbols...)()
    {
        static foreach (symbol; symbols)
        {
            static if (isCallable!symbol)
            {
                static if (hasEventAttr!symbol)
                    registerEvents!symbol();
                static if (hasTaskAttr!symbol)
                    registerTasks!symbol();
                static if (hasCommandRegistrationAttr!symbol)
                    registerCommands!symbol();
            }
            else static if (IsTypeSymbol!symbol)
            {
                static if (typeHasCommandMembers!symbol)
                    registerCommandGroup!symbol();
                static if (typeHasEventMembers!symbol)
                    registerEventGroup!symbol();
                static if (typeHasTaskMembers!symbol)
                    registerTaskGroup!symbol();
                static if (HasLuaPluginAttr!symbol)
                    registerPlugin!symbol();
            }
            else
            {
                static assert(false, "registerAllCommands only accepts callable handlers or types.");
            }
        }

        syncBuiltInCommandSystems();
    }

    /// Registers every supported symbol declared in the calling module, with optional filters.
    void registerAllCommands(string moduleName = __MODULE__)(CommandRegistrationFilter filter = CommandRegistrationFilter.init)
    {
        registerModuleMembers!(moduleName, true, true, true, true)(filter);
        syncBuiltInCommandSystems();
    }

    /// Registers every scheduled task declared in the calling module, with optional filters.
    void registerTasks(string moduleName = __MODULE__)(CommandRegistrationFilter filter = CommandRegistrationFilter.init)
    {
        registerModuleMembers!(moduleName, false, false, false, true)(filter);
    }

    /// Registers a stateful command group.
    void registerCommandGroup(T)()
    {
        commands.register!T();
        syncBuiltInCommandSystems();
    }

    /// Registers `@Event` methods from a stateful group type.
    void registerEventGroup(T)()
    {
        registerEventMembers!T();
    }

    /// Registers `@Task` methods from a stateful group type.
    void registerTaskGroup(T)()
    {
        registerTaskMembers!T();
    }

    /// Registers a plugin descriptor type.
    void registerPlugin(T)()
    {
        plugins.register!T();
        syncBuiltInCommandSystems();
    }

    /// Opens a scripting runtime using the registered scripting engine.
    LuaRuntime openLuaRuntime(T)(
        T binding,
        LuaSandboxProfile profile = LuaSandboxProfile.Untrusted,
        LuaCapability[] permissions = null
    )
    {
        return services.get!ScriptingEngine().open!T(binding, profile, permissions);
    }

    /// Ingests a message, updates cache/state, emits events, and executes prefix commands.
    Result!(CommandExecution, string) receiveMessage(Message message, ulong permissions = 0)
    {
        auto startedAt = MonoTime.currTime;
        syncCommandExecutionSettings();
        syncBuiltInCommandSystems();

        if (_selfUser.id.value != 0 && message.author.id == _selfUser.id)
        {
            CommandExecution ignored;
            return Result!(CommandExecution, string).ok(ignored);
        }

        if (message.author.id.value != 0)
            cache.store(message.author);
        foreach (mentionedUser; message.mentions)
        {
            if (mentionedUser.id.value != 0)
                cache.store(mentionedUser);
        }
        if (!message.referencedMessage.isNull)
        {
            auto referencedMessage = message.referencedMessage.get;
            if (referencedMessage.author.id.value != 0)
                cache.store(referencedMessage.author);

            Message cachedReferencedMessage;
            cachedReferencedMessage.id = referencedMessage.id;
            cachedReferencedMessage.channelId = referencedMessage.channelId;
            cachedReferencedMessage.guildId = referencedMessage.guildId;
            cachedReferencedMessage.author = referencedMessage.author;
            cachedReferencedMessage.content = referencedMessage.content;
            cache.store(cachedReferencedMessage);
        }

        Channel channel;
        channel.id = message.channelId;
        auto cachedChannel = cache.channel(channel.id);
        if (!cachedChannel.isNull)
            channel = cachedChannel.get;
        cache.store(channel);
        cache.store(message);
        state.global.set("lastMessageContent", message.content);

        MessageCreateEvent event;
        event.message = message;
        event.context = buildMessageCreateEventContext(message, channel);
        emit!MessageCreateEvent(event);

        if (!message.content.startsWith(config.prefix))
        {
            CommandExecution execution;
            execution.replyCount = rest.messages.history.length;
            return Result!(CommandExecution, string).ok(execution);
        }

        auto parsed = commands.parsePrefix(config.prefix, message.content);
        if (parsed.isErr)
        {
            auto ctx = prefixContext(message.content, message.author, channel);
            ctx.permissions = permissions;
            ctx.message = Nullable!Message.of(message);
            ctx.currentGuild = lookupGuild(message.guildId);
            ctx.currentMember = message.member;
            ctx.receiveLatencyMilliseconds = snowflakeLatencyMilliseconds(message.id);

            auto attemptedName = attemptedPrefixCommandName(config.prefix, message.content);
            auto result = Result!(CommandExecution, string).err(parsed.error);
            if (shouldSurfacePrefixFailure(parsed.error, attemptedName, ctx))
                surfacePrefixFailure(ctx, attemptedName, parsed.error);
            emitCommandOutcome(result, attemptedName, ctx, message, message.author);
            logCommandOutcome("prefix", message.author, result, (MonoTime.currTime - startedAt).total!"msecs");
            return result;
        }

        auto descriptor = parsed.value.descriptor.get;
        auto effectivePermissions = permissions;
        if (effectivePermissions == 0 && !message.member.isNull && message.member.get.permissions != 0)
            effectivePermissions = message.member.get.permissions;

        if (effectivePermissions == 0 && descriptor.policy.requiredPermissions != 0)
        {
            auto resolved = resolvePrefixPermissions(message, channel);
            if (resolved.isOk)
            {
                effectivePermissions = resolved.value;
            }
            else
            {
                logger.warning(
                    "commands",
                    "Could not resolve prefix permissions for `" ~ descriptor.displayName ~ "`: " ~ resolved.error
                );
            }
        }

        auto ctx = prefixContext(message.content, message.author, channel);
        ctx.permissions = effectivePermissions;
        ctx.message = Nullable!Message.of(message);
        ctx.currentGuild = lookupGuild(message.guildId);
        ctx.currentMember = message.member;
        ctx.receiveLatencyMilliseconds = snowflakeLatencyMilliseconds(message.id);

        auto result = commands.executeParsedPrefix(ctx, parsed.value);
        auto durationMs = (MonoTime.currTime - startedAt).total!"msecs";
        if (result.isErr && shouldSurfacePrefixFailure(result.error, descriptor.displayName, ctx))
            surfacePrefixFailure(ctx, descriptor.displayName, result.error);
        emitCommandOutcome(result, descriptor.displayName, ctx, message, message.author);
        logCommandOutcome("prefix", message.author, result, durationMs);
        return result;
    }

    /// Ingests an interaction and dispatches it to the command registry.
    Result!(CommandExecution, string) receiveInteraction(
        Interaction interaction,
        Channel channel = Channel.init,
        ulong permissions = 0
    )
    {
        auto startedAt = MonoTime.currTime;
        syncCommandExecutionSettings();
        syncBuiltInCommandSystems();

        if (interaction.user.id.value != 0)
            cache.store(interaction.user);
        foreach (user; interaction.resolvedUsers)
            cache.store(user);
        foreach (resolvedChannel; interaction.resolvedChannels)
            cache.store(resolvedChannel);

        if (permissions == 0 && interaction.permissions != 0)
            permissions = interaction.permissions;

        if (channel.id.value == 0 && interaction.channelId.value != 0)
        {
            channel.id = interaction.channelId;
            auto cached = cache.channel(channel.id);
            if (!cached.isNull)
                channel = cached.get;
        }

        if (channel.id.value != 0)
            cache.store(channel);

        InteractionCreateEvent event;
        event.interaction = interaction;
        event.context = buildInteractionCreateEventContext(interaction, channel);
        emit!InteractionCreateEvent(event);

        if (interaction.type == InteractionType.ApplicationCommandAutocomplete)
        {
            auto ctx = interactionContext(interaction, channel);
            ctx.permissions = permissions;
            ctx.receiveLatencyMilliseconds = snowflakeLatencyMilliseconds(interaction.id);

            string[string] options;
            foreach (option; interaction.options)
                options[option.name] = option.value;

            AutocompleteInteractionEvent autocompleteEvent;
            autocompleteEvent.interaction = interaction;
            autocompleteEvent.context = buildAutocompleteInteractionEventContext(interaction, channel);
            emit!AutocompleteInteractionEvent(autocompleteEvent);

            bool handledAutocomplete;
            auto autocompleteResult = commands.executeAutocomplete(
                ctx,
                interaction.commandName,
                autocompleteEvent.context.focusedName,
                autocompleteEvent.context.focusedValue,
                options,
                &handledAutocomplete
            );

            if (autocompleteResult.isErr)
            {
                surfaceInteractionFailure(ctx, interaction.commandName, autocompleteResult.error);
                emitCommandOutcome(
                    Result!(CommandExecution, string).err(autocompleteResult.error),
                    interaction.commandName,
                    ctx,
                    Message.init,
                    interaction.user
                );
                return Result!(CommandExecution, string).err(autocompleteResult.error);
            }

            if (!handledAutocomplete)
            {
                CommandExecution ignored;
                return Result!(CommandExecution, string).ok(ignored);
            }

            auto sent = ctx.autocomplete(autocompleteResult.value).awaitResult();
            if (sent.isErr)
            {
                surfaceInteractionFailure(ctx, interaction.commandName, sent.error);
                emitCommandOutcome(
                    Result!(CommandExecution, string).err(sent.error),
                    interaction.commandName,
                    ctx,
                    Message.init,
                    interaction.user
                );
                return Result!(CommandExecution, string).err(sent.error);
            }

            CommandExecution execution;
            execution.commandName = interaction.commandName;
            execution.replyCount = autocompleteResult.value.length;
            emitCommandOutcome(
                Result!(CommandExecution, string).ok(execution),
                interaction.commandName,
                ctx,
                Message.init,
                interaction.user
            );
            return Result!(CommandExecution, string).ok(execution);
        }

        if (interaction.type == InteractionType.MessageComponent)
        {
            MessageComponentEvent componentEvent;
            componentEvent.interaction = interaction;
            componentEvent.context = buildMessageComponentEventContext(interaction, channel);
            emit!MessageComponentEvent(componentEvent);
            CommandExecution ignored;
            return Result!(CommandExecution, string).ok(ignored);
        }

        if (interaction.type == InteractionType.ModalSubmit)
        {
            ModalSubmitEvent modalEvent;
            modalEvent.interaction = interaction;
            modalEvent.context = buildModalSubmitEventContext(interaction, channel);
            emit!ModalSubmitEvent(modalEvent);
            CommandExecution ignored;
            return Result!(CommandExecution, string).ok(ignored);
        }

        auto ctx = interactionContext(interaction, channel);
        ctx.permissions = permissions;
        ctx.receiveLatencyMilliseconds = snowflakeLatencyMilliseconds(interaction.id);

        string[string] options;
        foreach (option; interaction.options)
            options[option.name] = option.value;

        auto result = interaction.commandType == ApplicationCommandType.ChatInput
            ? commands.executeSlash(ctx, interaction.commandName, options)
            : commands.executeContextMenu(ctx, interaction.commandName, options);
        auto durationMs = (MonoTime.currTime - startedAt).total!"msecs";

        Message sourceMessage;
        if (!interaction.targetMessage.isNull)
            sourceMessage = interaction.targetMessage.get;

        if (result.isErr)
            surfaceInteractionFailure(ctx, interaction.commandName, result.error);
        emitCommandOutcome(result, interaction.commandName, ctx, sourceMessage, interaction.user);
        logCommandOutcome("interaction", interaction.user, result, durationMs);
        return result;
    }

    /// Blocks until the live gateway thread finishes.
    void wait()
    {
        joinShardThreads();
        if (_dispatchThread !is null)
        {
            _dispatchThread.join();
            _dispatchThread = null;
        }
        if (_taskThread !is null)
        {
            _taskThread.join();
            _taskThread = null;
        }
    }

    /// Stops the live gateway session if one is running.
    void stop()
    {
        _running = false;
        uptime.markStopped();
        _dispatchLoopRunning = false;
        _taskLoopRunning = false;
        tasks.cancel(GatewayReadyWatchdogLabel);
        tasks.cancel(GatewayAutoReshardWatchdogLabel);
        deactivatePluginsIfNeeded();
        logger.information("client", "Stopping the Discord client.");
        signalDispatchLoop();
        stopAllGateways();
        if (_dispatchThread !is null)
        {
            _dispatchThread.join();
            _dispatchThread = null;
        }
        if (_taskThread !is null)
        {
            _taskThread.join();
            _taskThread = null;
        }
    }

    /// Returns messages sent through the REST surface history.
    Message[] sentMessages() @property
    {
        return rest.messages.history;
    }

    /// Runs scheduled tasks that are currently due.
    size_t runDueTasks()
    {
        return tasks.runDue();
    }

    /// Runs a registered task immediately by label.
    bool runTaskNow(string label)
    {
        return tasks.runNow(label);
    }

    /// Returns the active gateway shard count.
    uint activeShardCount() const @property
    {
        return cast(uint) _shards.length;
    }

    /// Reconfigures shard count at runtime without restarting the process.
    void reshard(uint shardCount)
    {
        if (shardCount == 0)
        {
            throw new DdiscordException(formatError(
                "sharding",
                "Cannot reshard to zero shards.",
                "",
                "Provide a shard count >= 1."
            ));
        }

        config.enableSharding = shardCount > 1;
        config.autoSharding = false;
        config.shardCount = shardCount;

        if (!_running)
            return;

        restartGateways(activeGatewayUrl());
    }

    /// Refreshes shard topology from Discord recommendations and reapplies gateways when needed.
    bool refreshShardTopology()
    {
        auto info = rest.gateway.bot().awaitResult();
        if (info.isErr)
            throw new DdiscordException(info.error);

        _gatewayInfo = Nullable!GatewayBotInfo.of(info.value);
        if (info.value.shards == 0)
            return false;

        auto targetShardCount = info.value.shards;
        if (targetShardCount == cast(uint) _shards.length)
            return false;

        config.enableSharding = targetShardCount > 1;
        config.shardCount = targetShardCount;
        if (_running)
            restartGateways(info.value.url.length == 0 ? activeGatewayUrl() : info.value.url);
        return true;
    }

    /// Returns whether the client has been started.
    bool isRunning() const @property
    {
        return _running;
    }

    /// Returns the current presence status.
    StatusType status() const @property
    {
        return _status;
    }

    /// Returns the current activity.
    Activity activity() const @property
    {
        return _activity;
    }

    /// Returns the current bot user.
    User selfUser() const @property
    {
        return _selfUser;
    }

    /// Returns the discovered gateway metadata if the client has started.
    Nullable!GatewayBotInfo gatewayInfo() const @property
    {
        return _gatewayInfo;
    }

    private void emitCommandOutcome(
        Result!(CommandExecution, string) result,
        string attemptedName,
        CommandContext ctx,
        Message sourceMessage,
        User user
    )
    {
        if (result.isOk)
        {
            CommandExecutedEvent event;
            event.commandName = result.value.commandName;
            event.sourceMessage = sourceMessage;
            event.user = user;
            event.replyCount = result.value.replyCount;
            event.context = buildCommandExecutedEventContext(ctx, result.value.commandName);
            emit!CommandExecutedEvent(event);
        }
        else
        {
            CommandFailedEvent event;
            event.attemptedName = attemptedName;
            event.sourceMessage = sourceMessage;
            event.user = user;
            event.error = result.error;
            event.context = buildCommandFailedEventContext(ctx, attemptedName);
            emit!CommandFailedEvent(event);
        }
    }

    private void registerFreeEvent(alias handler)()
    {
        alias Subscription = EventSubscriptionType!handler;
        events.on!Subscription((event) {
            invokeFreeEvent!handler(event);
        });
    }

    private void registerFreeTask(alias handler)()
    {
        auto spec = taskSpec!handler();
        scheduleTask(spec, __traits(identifier, handler), {
            invokeFreeTask!handler(this);
        });
    }

    private void registerStatefulEvent(T, string memberName)()
    {
        mixin("alias memberSymbol = T." ~ memberName ~ ";");
        alias Subscription = EventSubscriptionType!memberSymbol;
        events.on!Subscription((event) {
            auto instance = services.get!T();
            invokeStatefulEvent!(T, memberSymbol)(instance, event);
        });
    }

    private void registerStatefulTask(T, string memberName)()
    {
        mixin("alias memberSymbol = T." ~ memberName ~ ";");
        auto spec = taskSpec!memberSymbol();
        scheduleTask(spec, T.stringof ~ "." ~ memberName, {
            auto instance = services.get!T();
            invokeStatefulTask!(T, memberSymbol)(this, instance);
        });
    }

    private void registerEventMembers(T)()
    {
        static foreach (memberName; __traits(allMembers, T))
        {
            static if (memberName != "__ctor" && memberName != "__xdtor")
            {
                mixin("alias memberSymbol = T." ~ memberName ~ ";");
                static if (isCallable!memberSymbol)
                {
                    enum hasAttrs = __traits(getAttributes, memberSymbol).length > 0;
                    static if (hasAttrs && hasEventAttr!memberSymbol)
                        registerStatefulEvent!(T, memberName)();
                }
            }
        }
    }

    private void registerTaskMembers(T)()
    {
        commands.register!T();

        static foreach (memberName; __traits(allMembers, T))
        {
            {
                static if (memberName != "__ctor" && memberName != "__xdtor")
                {
                    mixin("alias memberSymbol = T." ~ memberName ~ ";");
                    static if (isCallable!memberSymbol)
                    {
                        enum hasAttrs = __traits(getAttributes, memberSymbol).length > 0;
                        static if (hasAttrs && hasTaskAttr!memberSymbol)
                            registerStatefulTask!(T, memberName)();
                    }
                }
            }
        }
    }

    private void scheduleTask(Task spec, string fallbackLabel, void delegate() callback)
    {
        auto label = spec.label.strip.length == 0 ? fallbackLabel : spec.label.strip;
        if (label.length == 0)
            label = "task";

        void delegate() wrapped = callback;

        if (wrapped !is null && !spec.reconnect)
        {
            auto original = wrapped;
            wrapped = {
                try
                {
                    original();
                }
                catch (Throwable error)
                {
                    tasks.cancel(label);
                    throw error;
                }
            };
        }

        if (wrapped !is null && spec.count > 0)
        {
            auto remaining = spec.count;
            auto original = wrapped;
            wrapped = {
                if (remaining == 0)
                    return;

                original();
                remaining--;
                if (remaining == 0)
                    tasks.cancel(label);
            };
        }

        if (spec.runOnRegister && wrapped !is null)
            wrapped();

        final switch (spec.mode)
        {
            case TaskMode.Every:
                if (spec.interval <= Duration.zero)
                {
                    throw new DdiscordException(formatError(
                        "tasks",
                        "A scheduled task declared an invalid recurring interval.",
                        "Task `" ~ label ~ "` must use an interval greater than zero.",
                        "Use `@Task(dur!\"seconds\"(N))` with `N > 0` for recurring tasks."
                    ));
                }
                if (spec.count == 1 && spec.runOnRegister)
                    break;
                tasks.every(label, spec.interval, wrapped);
                break;
            case TaskMode.Delay:
                if (spec.interval < Duration.zero)
                {
                    throw new DdiscordException(formatError(
                        "tasks",
                        "A scheduled task declared a negative delay.",
                        "Task `" ~ label ~ "` received delay `" ~ spec.interval.to!string ~ "`.",
                        "Use `TaskMode.Delay` with a delay greater than or equal to zero."
                    ));
                }
                if (spec.count > 1)
                {
                    throw new DdiscordException(formatError(
                        "tasks",
                        "Delay-mode tasks cannot run multiple times.",
                        "Task `" ~ label ~ "` uses `TaskMode.Delay` with `count=" ~ spec.count.to!string ~ "`.",
                        "Use recurring mode (`TaskMode.Every`) for multi-run tasks."
                    ));
                }
                if (spec.count == 1 && spec.runOnRegister)
                    break;
                tasks.schedule(label, spec.interval, wrapped);
                break;
            case TaskMode.Cron:
                auto expression = spec.expression.strip;
                if (expression.length == 0)
                {
                    throw new DdiscordException(formatError(
                        "tasks",
                        "A scheduled task declared an empty cron expression.",
                        "Task `" ~ label ~ "` uses `TaskMode.Cron` but did not set `expression`.",
                        "Use `@Task(\"@every:30s\")` or set a valid cron expression string."
                    ));
                }
                if (spec.count == 1 && spec.runOnRegister)
                    break;
                tasks.cron(label, expression, wrapped);
                break;
        }
    }

    mixin ClientEventContextBuilders;

    private Nullable!InteractionOption focusedOption(Interaction interaction)
    {
        foreach (option; interaction.options)
        {
            if (option.focused)
                return typeof(return).of(option);
        }

        return typeof(return).init;
    }

    private bool sameCommands(
        ApplicationCommandDefinition[] left,
        ApplicationCommandDefinition[] right
    )
    {
        if (left.length != right.length)
            return false;

        auto normalizedLeft = normalizeCommands(left);
        auto normalizedRight = normalizeCommands(right);

        foreach (index, definition; normalizedLeft)
        {
            if (definition.toJSON.toString != normalizedRight[index].toJSON.toString)
                return false;
        }

        return true;
    }

    private void startGateways(string url)
    {
        stopAllGateways();

        auto shardCount = resolvedShardCount();
        _shards.length = 0;

        foreach (shardId; 0 .. shardCount)
            startGatewayShard(url, shardId, shardCount);

        _gateway = _shards.length == 0 ? null : _shards[0].gateway;
        _gatewayThread = _shards.length == 0 ? null : _shards[0].thread;

        tasks.cancel(GatewayReadyWatchdogLabel);
        tasks.schedule(GatewayReadyWatchdogLabel, dur!"seconds"(20), {
            if (!allShardsReady())
            {
                logger.warning(
                    "gateway",
                    "One or more shard sessions are still waiting for READY/RESUMED 20 seconds after startup. Check intents, token validity, network reachability, and identify payload correctness."
                );
            }
        });

        logger.information(
            "gateway",
            "Started `" ~ shardCount.to!string ~ "` gateway shard(s)."
        );
    }

    private void restartGateways(string url)
    {
        logger.warning(
            "gateway",
            "Restarting gateway shards with count `" ~ resolvedShardCount().to!string ~ "`."
        );
        startGateways(url);
    }

    private void startGatewayShard(string url, uint shardId, uint shardCount)
    {
        GatewayClientConfig gatewayConfig;
        gatewayConfig.token = config.token;
        gatewayConfig.intents = config.intents;
        gatewayConfig.url = url;
        gatewayConfig.shardId = shardId;
        gatewayConfig.shardCount = shardCount;
        gatewayConfig.logger = logger;
        gatewayConfig.pollTimeout = dur!"msecs"(250);
        gatewayConfig.logUnhandledDispatchEvents = config.logUnhandledGatewayDispatchEvents;
        gatewayConfig.unhandledDispatchLogEvery = config.gatewayUnhandledDispatchLogEvery;

        auto gateway = new GatewayClient(gatewayConfig);
        wireGatewayCallbacks(gateway, shardId, shardCount);

        ShardRuntime runtime;
        runtime.shardId = shardId;
        runtime.gateway = gateway;
        runtime.thread = new Thread({
            gateway.run();

            synchronized (_dispatchMutex)
            {
                if (!_running)
                    return;
                _running = false;
            }

            uptime.markStopped();
            _dispatchLoopRunning = false;
            _taskLoopRunning = false;
            tasks.cancel(GatewayReadyWatchdogLabel);
            tasks.cancel(GatewayAutoReshardWatchdogLabel);
            stopGatewaysWithoutJoin();
            signalDispatchLoop();
            deactivatePluginsIfNeeded();
            logger.warning(
                "gateway",
                "Gateway shard `" ~ shardId.to!string ~ "` loop exited."
            );
        });

        _shards ~= runtime;
        runtime.thread.start();
        _shards[$ - 1].thread = runtime.thread;
    }

    private void wireGatewayCallbacks(GatewayClient gateway, uint shardId, uint shardCount)
    {
        gateway.onReady = (GatewayReadyInfo ready) {
            if (ready.selfUser.id.value != 0)
                _selfUser = ready.selfUser;

            if (_selfUser.id.value != 0)
                cache.store(_selfUser);

            if (allShardsReady())
                tasks.cancel(GatewayReadyWatchdogLabel);

            ReadyEvent event;
            event.gatewayVersion = ready.gatewayVersion;
            event.selfUser = _selfUser;
            event.guilds = ready.guilds.dup;
            event.sessionId = ready.sessionId;
            event.resumeGatewayUrl = ready.resumeGatewayUrl;
            event.context = buildReadyEventContext(_selfUser);
            emit!ReadyEvent(event);
            logger.information(
                "gateway",
                "READY received for shard `" ~ shardId.to!string ~ "/" ~ shardCount.to!string ~ "`."
            );
            gateway.updatePresence(_status, _activity);
        };
        gateway.onResumed = () {
            if (allShardsReady())
                tasks.cancel(GatewayReadyWatchdogLabel);

            ResumedEvent event;
            event.context = buildResumedEventContext(_selfUser);
            emit!ResumedEvent(event);
            logger.information(
                "gateway",
                "RESUMED received for shard `" ~ shardId.to!string ~ "/" ~ shardCount.to!string ~ "`."
            );
            gateway.updatePresence(_status, _activity);
        };
        gateway.onGuildCreate = (Guild guild) {
            if (guild.id.value != 0)
                cache.store(guild);

            GuildCreateEvent event;
            event.guild = guild;
            event.context = buildGuildCreateEventContext(guild);
            emit!GuildCreateEvent(event);
        };
        gateway.onGuildDelete = (UnavailableGuild guild) {
            if (!guild.unavailable && guild.id.value != 0)
                cache.evictGuild(guild.id);

            GuildDeleteEvent event;
            event.guild = guild;
            event.context = buildGuildDeleteEventContext(guild);
            emit!GuildDeleteEvent(event);
        };
        gateway.onGuildMemberRemove = (GatewayGuildMemberRemoveInfo info) {
            if (info.user.id.value != 0)
                cache.store(info.user);

            GuildMemberRemoveEvent event;
            event.user = info.user;
            event.guildId = info.guildId;
            event.context = buildGuildMemberRemoveEventContext(info.user, info.guildId);
            emit!GuildMemberRemoveEvent(event);
        };
        gateway.onGuildBanAdd = (GatewayGuildBanInfo info) {
            if (info.user.id.value != 0)
                cache.store(info.user);

            GuildBanAddEvent event;
            event.guildId = info.guildId;
            event.user = info.user;
            event.context = buildGuildBanAddEventContext(info);
            emit!GuildBanAddEvent(event);
        };
        gateway.onGuildBanRemove = (GatewayGuildBanInfo info) {
            if (info.user.id.value != 0)
                cache.store(info.user);

            GuildBanRemoveEvent event;
            event.guildId = info.guildId;
            event.user = info.user;
            event.context = buildGuildBanRemoveEventContext(info);
            emit!GuildBanRemoveEvent(event);
        };
        gateway.onChannelCreate = (Channel channel) {
            if (channel.id.value != 0)
                cache.store(channel);

            ChannelCreateEvent event;
            event.channel = channel;
            event.context = buildChannelCreateEventContext(channel);
            emit!ChannelCreateEvent(event);
        };
        gateway.onChannelUpdate = (Channel channel) {
            if (channel.id.value != 0)
                cache.store(channel);

            ChannelUpdateEvent event;
            event.channel = channel;
            event.context = buildChannelUpdateEventContext(channel);
            emit!ChannelUpdateEvent(event);
        };
        gateway.onChannelDelete = (Channel channel) {
            if (channel.id.value != 0)
                cache.evictChannel(channel.id);

            ChannelDeleteEvent event;
            event.channel = channel;
            event.context = buildChannelDeleteEventContext(channel);
            emit!ChannelDeleteEvent(event);
        };
        gateway.onChannelPinsUpdate = (GatewayChannelPinsUpdateInfo info) {
            ChannelPinsUpdateEvent event;
            event.channelId = info.channelId;
            event.guildId = info.guildId;
            event.lastPinTimestamp = info.lastPinTimestamp;
            event.context = buildChannelPinsUpdateEventContext(info);
            emit!ChannelPinsUpdateEvent(event);
        };
        gateway.onMessageCreate = (Message message) {
            enqueueMessage(message);
        };
        gateway.onMessageUpdate = (Message message) {
            if (message.id.value != 0)
                cache.store(message);
            if (message.author.id.value != 0)
                cache.store(message.author);

            MessageUpdateEvent event;
            event.message = message;
            event.context = buildMessageUpdateEventContext(message);
            emit!MessageUpdateEvent(event);
        };
        gateway.onMessageDelete = (GatewayMessageDeleteInfo info) {
            auto cached = cache.message(info.messageId);
            if (info.messageId.value != 0)
                cache.evictMessage(info.messageId);

            MessageDeleteEvent event;
            event.messageId = info.messageId;
            event.channelId = info.channelId;
            event.guildId = info.guildId;
            event.context = buildMessageDeleteEventContext(info, cached);
            emit!MessageDeleteEvent(event);
        };
        gateway.onMessageReactionAdd = (GatewayMessageReactionInfo info) {
            MessageReactionAddEvent event;
            event.userId = info.userId;
            event.channelId = info.channelId;
            event.messageId = info.messageId;
            event.guildId = info.guildId;
            event.emojiName = info.emojiName;
            event.context = buildMessageReactionAddEventContext(info);
            emit!MessageReactionAddEvent(event);
        };
        gateway.onMessageReactionRemove = (GatewayMessageReactionInfo info) {
            MessageReactionRemoveEvent event;
            event.userId = info.userId;
            event.channelId = info.channelId;
            event.messageId = info.messageId;
            event.guildId = info.guildId;
            event.emojiName = info.emojiName;
            event.context = buildMessageReactionRemoveEventContext(info);
            emit!MessageReactionRemoveEvent(event);
        };
        gateway.onMessageReactionRemoveAll = (GatewayMessageReactionRemoveAllInfo info) {
            MessageReactionRemoveAllEvent event;
            event.channelId = info.channelId;
            event.messageId = info.messageId;
            event.guildId = info.guildId;
            event.context = buildMessageReactionRemoveAllEventContext(info);
            emit!MessageReactionRemoveAllEvent(event);
        };
        gateway.onMessageReactionRemoveEmoji = (GatewayMessageReactionInfo info) {
            MessageReactionRemoveEmojiEvent event;
            event.channelId = info.channelId;
            event.messageId = info.messageId;
            event.guildId = info.guildId;
            event.emojiName = info.emojiName;
            event.context = buildMessageReactionRemoveEmojiEventContext(info);
            emit!MessageReactionRemoveEmojiEvent(event);
        };
        gateway.onTypingStart = (GatewayTypingStartInfo info) {
            TypingStartEvent event;
            event.channelId = info.channelId;
            event.guildId = info.guildId;
            event.userId = info.userId;
            event.timestampUnix = info.timestampUnix;
            event.context = buildTypingStartEventContext(info);
            emit!TypingStartEvent(event);
        };
        gateway.onGuildRoleCreate = (GatewayGuildRoleInfo info) {
            if (info.role.id.value != 0)
                cache.store(info.role);

            GuildRoleCreateEvent event;
            event.guildId = info.guildId;
            event.role = info.role;
            event.context = buildGuildRoleCreateEventContext(info);
            emit!GuildRoleCreateEvent(event);
        };
        gateway.onGuildRoleUpdate = (GatewayGuildRoleInfo info) {
            if (info.role.id.value != 0)
                cache.store(info.role);

            GuildRoleUpdateEvent event;
            event.guildId = info.guildId;
            event.role = info.role;
            event.context = buildGuildRoleUpdateEventContext(info);
            emit!GuildRoleUpdateEvent(event);
        };
        gateway.onGuildRoleDelete = (GatewayGuildRoleDeleteInfo info) {
            if (info.roleId.value != 0)
                cache.evictRole(info.roleId);

            GuildRoleDeleteEvent event;
            event.guildId = info.guildId;
            event.roleId = info.roleId;
            event.context = buildGuildRoleDeleteEventContext(info);
            emit!GuildRoleDeleteEvent(event);
        };
        gateway.onInviteCreate = (GatewayInviteInfo info) {
            InviteCreateEvent event;
            event.code = info.code;
            event.channelId = info.channelId;
            event.guildId = info.guildId;
            event.context = buildInviteCreateEventContext(info);
            emit!InviteCreateEvent(event);
        };
        gateway.onInviteDelete = (GatewayInviteInfo info) {
            InviteDeleteEvent event;
            event.code = info.code;
            event.channelId = info.channelId;
            event.guildId = info.guildId;
            event.context = buildInviteDeleteEventContext(info);
            emit!InviteDeleteEvent(event);
        };
        gateway.onWebhooksUpdate = (GatewayWebhooksUpdateInfo info) {
            WebhooksUpdateEvent event;
            event.channelId = info.channelId;
            event.guildId = info.guildId;
            event.context = buildWebhooksUpdateEventContext(info);
            emit!WebhooksUpdateEvent(event);
        };
        gateway.onThreadCreate = (Channel thread) {
            if (thread.id.value != 0)
                cache.store(thread);

            ThreadCreateEvent event;
            event.thread = thread;
            event.context = buildThreadCreateEventContext(thread);
            emit!ThreadCreateEvent(event);
        };
        gateway.onThreadUpdate = (Channel thread) {
            if (thread.id.value != 0)
                cache.store(thread);

            ThreadUpdateEvent event;
            event.thread = thread;
            event.context = buildThreadUpdateEventContext(thread);
            emit!ThreadUpdateEvent(event);
        };
        gateway.onThreadDelete = (GatewayThreadDeleteInfo info) {
            if (info.threadId.value != 0)
                cache.evictChannel(info.threadId);

            ThreadDeleteEvent event;
            event.threadId = info.threadId;
            event.guildId = info.guildId;
            event.parentId = info.parentId;
            event.context = buildThreadDeleteEventContext(info);
            emit!ThreadDeleteEvent(event);
        };
        gateway.onInteractionCreate = (Interaction interaction) {
            Channel channel;
            channel.id = interaction.channelId;
            enqueueInteraction(interaction, channel);
        };
        gateway.onGuildMemberAdd = (GatewayGuildMemberAddInfo info) {
            if (!info.member.user.isNull)
                cache.store(info.member.user.get);

            GuildMemberAddEvent event;
            event.member = info.member;
            event.guild.memberCount = info.memberCount;
            event.context = buildGuildMemberAddEventContext(info.member, info.guildId);
            emit!GuildMemberAddEvent(event);
        };
        gateway.onPresenceUpdate = (GatewayPresenceUpdateInfo info) {
            if (info.user.id.value != 0)
                cache.store(info.user);

            PresenceUpdateEvent event;
            event.status = info.status;
            event.activity = info.activity;
            event.context = buildGatewayPresenceUpdateEventContext(
                info.status,
                info.activity,
                Nullable!User.of(info.user),
                info.guildId,
                info.member
            );
            emit!PresenceUpdateEvent(event);
        };
        gateway.onError = (string message) {
            CommandFailedEvent event;
            event.attemptedName = "[gateway]";
            event.error = message;
            event.user = _selfUser;
            CommandContext ctx;
            ctx.rest = rest;
            ctx.services = services;
            ctx.cache = cache;
            ctx.state = state;
            ctx.invoker = _selfUser;
            event.context = buildCommandFailedEventContext(ctx, "[gateway]");
            emit!CommandFailedEvent(event);
        };
    }

    private uint resolvedShardCount() const
    {
        if (config.shardCount > 0)
            return config.shardCount;

        if (config.enableSharding && config.autoSharding && !_gatewayInfo.isNull && _gatewayInfo.get.shards > 0)
            return _gatewayInfo.get.shards;

        return 1;
    }

    private bool allShardsReady() const
    {
        if (_shards.length == 0)
            return false;

        foreach (ref shard; _shards)
        {
            if (shard.gateway is null || !shard.gateway.isReady)
                return false;
        }

        return true;
    }

    private void stopGatewaysWithoutJoin()
    {
        foreach (ref shard; _shards)
        {
            if (shard.gateway !is null)
                shard.gateway.stop();
        }
    }

    private void stopAllGateways()
    {
        stopGatewaysWithoutJoin();
        joinShardThreads();
    }

    private void joinShardThreads()
    {
        foreach (ref shard; _shards)
        {
            if (shard.thread !is null)
            {
                shard.thread.join();
                shard.thread = null;
            }
        }

        _shards.length = 0;
        _gateway = null;
        _gatewayThread = null;
    }

    private string activeGatewayUrl() const
    {
        if (!_gatewayInfo.isNull && _gatewayInfo.get.url.length != 0)
            return _gatewayInfo.get.url;

        if (_shards.length != 0 && _shards[0].gateway !is null)
            return _shards[0].gateway.config.url;

        return "wss://gateway.discord.gg";
    }

    private void configureAutoReshardWatchdog()
    {
        tasks.cancel(GatewayAutoReshardWatchdogLabel);
        if (!config.enableSharding || !config.autoReshard)
            return;

        auto interval = config.autoReshardCheckInterval <= Duration.zero
            ? dur!"minutes"(10)
            : config.autoReshardCheckInterval;

        tasks.every(GatewayAutoReshardWatchdogLabel, interval, {
            if (!_running)
                return;

            bool changed;
            try
            {
                changed = refreshShardTopology();
            }
            catch (DdiscordException error)
            {
                logger.warning("gateway", "Auto-reshard check failed: " ~ error.msg);
                return;
            }

            if (changed)
                logger.warning("gateway", "Auto-reshard applied a new shard topology.");
        });
    }

    private void startDispatchLoop()
    {
        if (_dispatchThread !is null)
            return;

        _dispatchLoopRunning = true;
        _dispatchThread = new Thread({
            while (true)
            {
                DispatchItem item;
                bool hasItem;

                synchronized (_dispatchMutex)
                {
                    while (dispatchQueueEmpty() && _dispatchLoopRunning)
                        _dispatchAvailable.wait();

                    if (dispatchQueueEmpty() && !_dispatchLoopRunning)
                        break;

                    item = _dispatchQueue[_dispatchQueueHead];
                    _dispatchQueueHead++;
                    compactQueue(_dispatchQueue, _dispatchQueueHead);
                    hasItem = true;
                }

                if (!hasItem)
                    continue;

                try
                {
                    final switch (item.kind)
                    {
                        case DispatchItem.Kind.Message:
                            auto _ = receiveMessage(item.message, item.permissions);
                            break;
                        case DispatchItem.Kind.Interaction:
                            auto _ = receiveInteraction(item.interaction, item.channel, item.permissions);
                            break;
                    }
                }
                catch (Throwable error)
                {
                    logger.error(
                        "client",
                        formatError(
                            "client",
                            "Dispatch worker encountered an unhandled error.",
                            error.msg,
                            "The worker remained online; inspect command/event handlers for unsafe exceptions."
                        )
                    );
                }
            }
        });
        _dispatchThread.start();
    }

    private void enqueueMessage(Message message, ulong permissions = 0)
    {
        DispatchItem item;
        item.kind = DispatchItem.Kind.Message;
        item.message = message;
        item.permissions = permissions;
        synchronized (_dispatchMutex)
        {
            auto outcome = pushBounded(
                _dispatchQueue,
                _dispatchQueueHead,
                item,
                config.maxDispatchQueueSize,
                config.dropOldestDispatchOnOverflow,
                _droppedDispatchItems
            );
            if (outcome.droppedIncoming || outcome.droppedOldest)
                logDispatchOverflow(outcome, "message");
            if (outcome.accepted)
                updateDispatchQueuePeak(outcome.depth);
            _dispatchAvailable.notify();
        }
    }

    private void enqueueInteraction(
        Interaction interaction,
        Channel channel = Channel.init,
        ulong permissions = 0
    )
    {
        DispatchItem item;
        item.kind = DispatchItem.Kind.Interaction;
        item.interaction = interaction;
        item.channel = channel;
        item.permissions = permissions;
        synchronized (_dispatchMutex)
        {
            auto outcome = pushBounded(
                _dispatchQueue,
                _dispatchQueueHead,
                item,
                config.maxDispatchQueueSize,
                config.dropOldestDispatchOnOverflow,
                _droppedDispatchItems
            );
            if (outcome.droppedIncoming || outcome.droppedOldest)
                logDispatchOverflow(outcome, "interaction");
            if (outcome.accepted)
                updateDispatchQueuePeak(outcome.depth);
            _dispatchAvailable.notify();
        }
    }

    private void signalDispatchLoop()
    {
        synchronized (_dispatchMutex)
            _dispatchAvailable.notifyAll();
    }

    private bool dispatchQueueEmpty() const
    {
        return _dispatchQueueHead >= _dispatchQueue.length;
    }

    private void resetDispatchQueue()
    {
        synchronized (_dispatchMutex)
        {
            _dispatchQueue.length = 0;
            _dispatchQueueHead = 0;
            _peakDispatchQueueDepth = 0;
            _droppedDispatchItems = 0;
        }
    }

    private void updateDispatchQueuePeak(size_t depth)
    {
        if (depth > _peakDispatchQueueDepth)
            _peakDispatchQueueDepth = depth;
    }

    private void logDispatchOverflow(DispatchQueuePushOutcome outcome, string kind)
    {
        if (config.dispatchOverflowLogEvery == 0)
            return;
        if (outcome.droppedTotal % config.dispatchOverflowLogEvery != 0)
            return;

        auto action = config.dropOldestDispatchOnOverflow
            ? "dropping the oldest pending item"
            : "dropping the new incoming item";

        logger.warning(
            "client",
            "Dispatch queue overflow reached " ~ outcome.droppedTotal.to!string ~
                " dropped item(s) while enqueueing " ~ kind ~ " events; " ~ action ~
                ". queueDepth=" ~ outcome.depth.to!string ~
                ", maxDepth=" ~ config.maxDispatchQueueSize.to!string ~ "."
        );
    }

    private void startTaskLoop()
    {
        if (_taskThread !is null)
            return;

        _taskLoopRunning = true;
        _taskThread = new Thread({
            while (_taskLoopRunning)
            {
                try
                {
                    tasks.runDue();
                }
                catch (Throwable error)
                {
                    logger.error(
                        "tasks",
                        formatError(
                            "tasks",
                            "Task loop encountered an unhandled error.",
                            error.msg,
                            "The scheduler loop remained online; inspect task callbacks and scheduler state."
                        )
                    );
                }
                Thread.sleep(dur!"msecs"(250));
            }
        });
        _taskThread.start();
    }

    private void syncBuiltInCommandSystems()
    {
        commands.removeWhere((descriptor) => descriptor.builtin);

        auto help = helpBehavior;
        if (!help.enabled)
            return;

        if (!commands.find(help.commandName, CommandRoute.Prefix).isNull)
            return;
        if (!commands.find(help.commandName, CommandRoute.Slash).isNull)
            return;

        commands.registerDescriptor(buildBuiltInHelpDescriptor());
    }

    private CommandDescriptor buildBuiltInHelpDescriptor()
    {
        auto help = helpBehavior;

        CommandDescriptor descriptor;
        descriptor.displayName = help.commandName;
        descriptor.description = help.description;
        descriptor.routes = CommandRoute.Hybrid;
        descriptor.applicationType = ApplicationCommandType.ChatInput;
        descriptor.symbolName = "[built-in]help";
        descriptor.qualifiedName = "ddiscord.client.Client.help";
        descriptor.sourceModule = "ddiscord.client";
        descriptor.sourceFile = __FILE__;
        descriptor.category = "Built-in";
        descriptor.builtin = true;

        CommandOptionDescriptor query;
        query.parameterName = "query";
        query.displayName = "query";
        query.description = "Command name or text filter";
        query.typeName = "string";
        query.required = false;

        CommandOptionDescriptor page;
        page.parameterName = "page";
        page.displayName = "page";
        page.description = "Page number";
        page.typeName = "size_t";
        page.applicationType = ApplicationCommandOptionType.Integer;
        page.required = false;
        descriptor.options = [query, page];

        descriptor.prefixExecutor = (CommandContext ctx, string[] rawArgs) {
            return executeBuiltInHelpPrefix(ctx, rawArgs);
        };
        descriptor.slashExecutor = (CommandContext ctx, string[string] rawOptions) {
            return executeBuiltInHelpSlash(ctx, rawOptions);
        };

        return descriptor;
    }

    private Result!(CommandExecution, string) executeBuiltInHelpPrefix(CommandContext ctx, string[] rawArgs)
    {
        auto parsed = parseHelpPrefixRequest(rawArgs);
        if (parsed.isErr)
            return Result!(CommandExecution, string).err(parsed.error);

        return executeBuiltInHelp(ctx, parsed.value);
    }

    private Result!(CommandExecution, string) executeBuiltInHelpSlash(
        CommandContext ctx,
        string[string] rawOptions
    )
    {
        HelpRequest request;

        if (auto query = "query" in rawOptions)
            request.query = *query;

        if (auto rawPage = "page" in rawOptions)
        {
            auto parsedPage = parseHelpPage(*rawPage);
            if (parsedPage.isErr)
                return Result!(CommandExecution, string).err(parsedPage.error);
            request.page = parsedPage.value;
        }

        return executeBuiltInHelp(ctx, request);
    }

    private Result!(CommandExecution, string) executeBuiltInHelp(CommandContext ctx, HelpRequest request)
    {
        auto payload = buildHelpPayload(ctx, request.query, request.page);

        auto sent = ctx.send(payload, ctx.source != CommandSource.Prefix).awaitResult();
        if (sent.isErr)
            return Result!(CommandExecution, string).err(sent.error);

        CommandExecution execution;
        execution.commandName = helpBehavior.commandName;
        execution.replyCount = rest.messages.history.length;
        return Result!(CommandExecution, string).ok(execution);
    }

    private Result!(HelpRequest, string) parseHelpPrefixRequest(string[] rawArgs)
    {
        HelpRequest request;
        if (rawArgs.length == 0)
            return Result!(HelpRequest, string).ok(request);

        auto maybePage = parseHelpPage(rawArgs[$ - 1]);
        if (maybePage.isOk)
        {
            request.page = maybePage.value;
            if (rawArgs.length > 1)
                request.query = joinArgs(rawArgs[0 .. $ - 1]);
            return Result!(HelpRequest, string).ok(request);
        }

        request.query = joinArgs(rawArgs);
        return Result!(HelpRequest, string).ok(request);
    }

    private Result!(size_t, string) parseHelpPage(string raw)
    {
        size_t page;

        try
        {
            page = raw.to!size_t;
        }
        catch (ConvException)
        {
            return Result!(size_t, string).err(formatError(
                "help",
                "The requested help page is not a valid positive integer.",
                "Received `" ~ raw ~ "`.",
                "Provide a positive page number such as `1` or `2`."
            ));
        }

        if (page == 0)
        {
            return Result!(size_t, string).err(formatError(
                "help",
                "The requested help page must be greater than zero.",
                "Received `0`.",
                "Provide a positive page number such as `1`."
            ));
        }

        return Result!(size_t, string).ok(page);
    }

    private string joinArgs(string[] values)
    {
        string joined;

        foreach (index, value; values)
        {
            if (index != 0)
                joined ~= " ";
            joined ~= value;
        }

        return joined;
    }

    private MessageCreate buildHelpPayload(CommandContext ctx, string query, size_t requestedPage)
    {
        auto page = prepareHelpPage(ctx, query, requestedPage);
        auto help = helpBehavior;

        if (help.renderPage !is null)
            return help.renderPage(page);
        if (!help.useComponentsV2)
            return defaultEmbeddedHelpPage(page);
        return defaultComponentsHelpPage(page);
    }

    private CommandHelpPage prepareHelpPage(CommandContext ctx, string query, size_t requestedPage)
    {
        auto help = helpBehavior;
        CommandDescriptor[] descriptors;

        foreach (descriptor; commands.descriptors)
        {
            if (descriptor.hiddenFromHelp)
                continue;
            if (descriptor.builtin && !help.showBuiltinCommands)
                continue;
            if (help.includeCommand !is null && !help.includeCommand(descriptor))
                continue;
            if (!descriptorVisibleToUser(descriptor, ctx))
                continue;
            if (!helpQueryMatches(descriptor, query))
                continue;
            descriptors ~= descriptor;
        }

        sort!((left, right) { return left.displayName < right.displayName; })(descriptors);

        CommandHelpPage page;
        page.commandName = help.commandName;
        page.query = query;
        page.pageSize = help.pageSize == 0 ? BuiltInHelpDefaultPageSize : help.pageSize;
        page.totalEntries = descriptors.length;
        page.totalPages = descriptors.length == 0 ? 1 : ((descriptors.length - 1) / page.pageSize) + 1;
        page.page = requestedPage == 0 ? 1 : requestedPage;
        if (page.page > page.totalPages)
            page.page = page.totalPages;

        if (descriptors.length != 0)
        {
            auto start = (page.page - 1) * page.pageSize;
            auto finish = start + page.pageSize;
            if (finish > descriptors.length)
                finish = descriptors.length;

            foreach (descriptor; descriptors[start .. finish])
                page.entries ~= buildHelpEntry(descriptor);
        }

        page.hasPrevious = page.page > 1;
        page.hasNext = page.page < page.totalPages;

        if (page.totalPages > 1)
        {
            if (page.hasPrevious)
            {
                page.previousCustomId = buildPersistentHelpCustomId(
                    state,
                    _nextHelpQueryTokenId,
                    ctx.user.id,
                    query,
                    page.page - 1
                );
            }
            if (page.hasNext)
            {
                page.nextCustomId = buildPersistentHelpCustomId(
                    state,
                    _nextHelpQueryTokenId,
                    ctx.user.id,
                    query,
                    page.page + 1
                );
            }
        }

        return page;
    }

    private CommandHelpEntry buildHelpEntry(CommandDescriptor descriptor)
    {
        auto help = helpBehavior;
        if (help.buildEntry !is null)
            return help.buildEntry(descriptor, config.prefix);

        CommandHelpEntry entry;
        entry.name = descriptor.displayName;
        entry.description = descriptor.description.length == 0 ? "No description provided." : descriptor.description;
        entry.usage = buildHelpUsage(descriptor);
        entry.routes = routeSummary(descriptor);
        entry.category = descriptor.category.length == 0 ? "General" : descriptor.category;
        entry.sourceModule = descriptor.sourceModule;
        entry.owner = descriptor.ownerType.length == 0 ? "free function" : descriptor.ownerType;
        entry.policies = policySummary(descriptor);
        entry.descriptor = descriptor;
        return entry;
    }

    private string buildHelpUsage(CommandDescriptor descriptor)
    {
        if (descriptor.applicationType == ApplicationCommandType.Message)
            return descriptor.displayName ~ " (message context menu)";
        if (descriptor.applicationType == ApplicationCommandType.User)
            return descriptor.displayName ~ " (user context menu)";

        string[] usages;

        if ((cast(uint) descriptor.routes & cast(uint) CommandRoute.Prefix) != 0)
            usages ~= config.prefix ~ descriptor.displayName ~ helpOptionUsage(descriptor.options, false);
        if ((cast(uint) descriptor.routes & cast(uint) CommandRoute.Slash) != 0)
            usages ~= "/" ~ descriptor.displayName ~ helpOptionUsage(descriptor.options, true);

        if (usages.length == 0)
            return descriptor.displayName;

        string usage;
        foreach (index, item; usages)
        {
            if (index != 0)
                usage ~= " | ";
            usage ~= item;
        }
        return usage;
    }

    private string helpOptionUsage(CommandOptionDescriptor[] options, bool slashStyle)
    {
        string usage;

        foreach (option; options)
        {
            auto label = slashStyle ? option.displayName : option.parameterName;
            if (option.required)
                usage ~= " <" ~ label ~ ">";
            else
                usage ~= " [" ~ label ~ "]";
        }

        return usage;
    }

    private string routeSummary(CommandDescriptor descriptor)
    {
        if (descriptor.applicationType == ApplicationCommandType.Message)
            return "message context";
        if (descriptor.applicationType == ApplicationCommandType.User)
            return "user context";

        if (descriptor.routes == CommandRoute.Hybrid)
            return "prefix + slash";
        if (descriptor.routes == CommandRoute.Prefix)
            return "prefix";
        if (descriptor.routes == CommandRoute.Slash)
            return "slash";
        if (descriptor.routes == CommandRoute.ContextMenu)
            return "context menu";
        return "unknown";
    }

    private string policySummary(CommandDescriptor descriptor)
    {
        string[] parts;

        if (descriptor.policy.ownerOnly)
            parts ~= "owner only";
        if (descriptor.policy.requiredPermissions != 0)
            parts ~= "requires permissions";
        if (descriptor.policy.hasRateLimit)
        {
            parts ~= "rate limit " ~ descriptor.policy.rateLimitCount.to!string ~ "/" ~
                descriptor.policy.rateLimitWindow.total!"seconds".to!string ~ "s";
        }

        if (parts.length == 0)
            return "none";

        return joinArgs(parts);
    }

    private bool descriptorVisibleToUser(CommandDescriptor descriptor, CommandContext ctx)
    {
        if (descriptor.policy.ownerOnly)
        {
            if (config.ownerId.isNull || config.ownerId.get != ctx.user.id)
                return false;
        }

        if (descriptor.policy.requiredPermissions != 0)
        {
            if ((ctx.permissions & descriptor.policy.requiredPermissions) != descriptor.policy.requiredPermissions)
                return false;
        }

        return true;
    }

    private bool helpQueryMatches(CommandDescriptor descriptor, string query)
    {
        auto normalizedQuery = normalizeHelpQueryText(query.strip);
        if (normalizedQuery.length == 0)
            return true;

        return helpFieldMatches(descriptor.displayName, normalizedQuery) ||
            helpFieldMatches(descriptor.description, normalizedQuery) ||
            helpFieldMatches(descriptor.symbolName, normalizedQuery) ||
            helpFieldMatches(descriptor.category, normalizedQuery);
    }

    private bool helpFieldMatches(string value, string normalizedQuery)
    {
        return normalizeHelpQueryText(value).canFind(normalizedQuery);
    }

    private string normalizeHelpQueryText(string value)
    {
        string normalized;
        foreach (ch; value)
            normalized ~= toLower(ch);
        return normalized;
    }

    private void handleBuiltInComponent(MessageComponentEvent event)
    {
        if (!event.context.customId.startsWith(BuiltInHelpCustomIdPrefix))
            return;

        if (event.context.customId == BuiltInHelpNoopCustomId)
            return;

        auto parsedTarget = parsePersistentHelpCustomId(state, event.context.customId);
        if (parsedTarget.isErr)
        {
            replyToComponentError(event, "This help session expired or became invalid. Run the help command again.");
            return;
        }

        auto target = parsedTarget.value;
        if (target.ownerId.value != 0 && target.ownerId != event.context.user.getOr(User.init).id)
        {
            replyToComponentError(event, "Only the original requester can turn this help page.");
            return;
        }

        auto channel = event.context.channel.getOr(Channel.init);
        auto ctx = interactionContext(event.interaction, channel);
        auto payload = buildHelpPayload(ctx, target.query, target.page);
        auto edited = rest.interactions.update(
            event.interaction.id,
            event.interaction.token,
            payload
        ).awaitResult();
        if (edited.isErr)
            logger.error("help", "Could not edit the help message: " ~ edited.error);
    }

    private void replyToComponentError(MessageComponentEvent event, string content)
    {
        auto channel = event.context.channel.getOr(Channel.init);
        auto ctx = interactionContext(event.interaction, channel);
        auto sent = ctx.send(content, true).awaitResult();
        if (sent.isErr)
            logger.error("help", "Could not send the component error response: " ~ sent.error);
    }

    private void surfacePrefixFailure(CommandContext ctx, string commandName, string error)
    {
        if (ctx.channel.id.value == 0)
            return;

        CommandErrorContext context;
        context.kind = classifyCommandFailure(error);
        context.route = "prefix";
        context.commandName = commandName;
        context.error = error;
        context.command = ctx;

        auto payload = buildFailurePayload(errorBehavior, config.prefix, context);
        auto sent = ctx.rest.messages.create(ctx.channel.id, payload).awaitResult();
        if (sent.isErr)
        {
            logger.error(
                "commands",
                "The library could not send the prefix failure message for `" ~ commandName ~ "`: " ~ sent.error
            );
        }
    }

    private void surfaceInteractionFailure(CommandContext ctx, string commandName, string error)
    {
        if (ctx.interaction.isNull || ctx.interaction.get.token.length == 0)
            return;

        CommandErrorContext context;
        context.kind = classifyCommandFailure(error);
        context.route = "interaction";
        context.commandName = commandName;
        context.error = error;
        context.command = ctx;

        if (!shouldSurfaceFailure(errorBehavior, context))
            return;

        auto task = ctx.send(buildFailurePayload(errorBehavior, config.prefix, context), true);
        auto sent = task.awaitResult();
        if (sent.isErr)
        {
            logger.error(
                "commands",
                "The library could not send the interaction failure message for `" ~ commandName ~ "`: " ~ sent.error
            );
        }
    }

    private void logCommandOutcome(
        string route,
        User user,
        Result!(CommandExecution, string) result,
        long durationMs
    )
    {
        if (result.isOk)
        {
            logger.debugMessage(
                "commands",
                "Executed " ~ route ~ " command `" ~ result.value.commandName ~ "` for `" ~ user.username ~
                "` (" ~ user.id.toString ~ ") in " ~ durationMs.to!string ~ "ms."
            );
        }
        else
        {
            logger.error(
                "commands",
                "Failed to execute " ~ route ~ " command for `" ~ user.username ~ "` (" ~ user.id.toString ~
                ") after " ~ durationMs.to!string ~ "ms. " ~ result.error
            );
        }
    }

    private Result!(ulong, string) resolvePrefixPermissions(Message message, Channel channel)
    {
        if (message.guildId.isNull)
            return Result!(ulong, string).ok(0);

        auto guildId = message.guildId.get;

        Guild guild;
        auto cachedGuild = cache.guild(guildId);
        if (!cachedGuild.isNull)
        {
            guild = cachedGuild.get;
        }
        else
        {
            auto fetchedGuild = rest.guilds.get(guildId).awaitResult();
            if (fetchedGuild.isErr)
                return Result!(ulong, string).err(fetchedGuild.error);
            guild = fetchedGuild.value;
            cache.store(guild);
        }

        GuildMember member;
        if (!message.member.isNull)
        {
            member = message.member.get;
        }
        else
        {
            auto fetchedMember = rest.guilds.member(guildId, message.author.id).awaitResult();
            if (fetchedMember.isErr)
                return Result!(ulong, string).err(fetchedMember.error);
            member = fetchedMember.value;
        }

        if (member.user.isNull)
            member.user = Nullable!User.of(message.author);

        if (member.permissions != 0)
            return Result!(ulong, string).ok(member.permissions);

        Channel resolvedChannel = channel;
        auto cachedChannel = cache.channel(channel.id);
        if (!cachedChannel.isNull && cachedChannel.get.permissionOverwrites.length != 0)
        {
            resolvedChannel = cachedChannel.get;
        }
        else if (channel.id.value != 0)
        {
            auto fetchedChannel = rest.channels.get(channel.id).awaitResult();
            if (fetchedChannel.isErr)
                return Result!(ulong, string).err(fetchedChannel.error);
            resolvedChannel = fetchedChannel.value;
            cache.store(resolvedChannel);
        }

        auto fetchedRoles = rest.guilds.roles(guildId).awaitResult();
        if (fetchedRoles.isErr)
            return Result!(ulong, string).err(fetchedRoles.error);

        foreach (role; fetchedRoles.value)
            cache.store(role);

        auto permissions = computeEffectivePermissions(member, guild, resolvedChannel, fetchedRoles.value);
        return Result!(ulong, string).ok(permissions);
    }

    private bool shouldSurfacePrefixFailure(string error, string commandName, CommandContext ctx)
    {
        CommandErrorContext context;
        context.kind = classifyCommandFailure(error);
        context.route = "prefix";
        context.commandName = commandName;
        context.error = error;
        context.command = ctx;
        return shouldSurfaceFailure(errorBehavior, context);
    }

    private void registerModuleMembers(
        string moduleName,
        bool includeCommands,
        bool includeEvents,
        bool includePlugins,
        bool includeTasks
    )(CommandRegistrationFilter filter = CommandRegistrationFilter.init)
    {
        mixin("import " ~ moduleName ~ ";");
        mixin("alias CurrentModule = " ~ moduleName ~ ";");

        static foreach (memberName; __traits(allMembers, CurrentModule))
        {
            {
                static if (memberName != "object" && memberName != "CurrentModule")
                {
                    static if (__traits(compiles, __traits(getMember, CurrentModule, memberName)))
                    {
                        alias memberSymbol = __traits(getMember, CurrentModule, memberName);
                        static if (isCallable!memberSymbol)
                        {
                            enum bool commandLike = hasCommandRegistrationAttr!memberSymbol;
                            enum bool eventLike = hasEventAttr!memberSymbol;
                            enum bool taskLike = hasTaskAttr!memberSymbol;
                            static if (commandLike || eventLike || taskLike)
                            {
                                enum candidate = describeCallableCandidate!memberSymbol();
                                if (matchesRegistrationFilter(filter, candidate))
                                {
                                    static if (includeCommands && commandLike)
                                        commands.registerAll!memberSymbol(0);
                                    static if (includeEvents && eventLike)
                                    {
                                        if (filter.includeEvents)
                                            registerEvents!memberSymbol();
                                    }
                                    static if (includeTasks && taskLike)
                                    {
                                        if (filter.includeTasks)
                                            registerTasks!memberSymbol();
                                    }
                                }
                            }
                        }
                        else static if (IsTypeSymbol!memberSymbol)
                        {
                            enum bool pluginLike = HasLuaPluginAttr!memberSymbol;
                            enum bool commandMembers = typeHasCommandMembers!memberSymbol;
                            enum bool eventMembers = typeHasEventMembers!memberSymbol;
                            enum bool taskMembers = typeHasTaskMembers!memberSymbol;
                            static if (pluginLike || commandMembers || eventMembers || taskMembers)
                            {
                                enum candidate = describeTypeCandidate!memberSymbol();
                                if (matchesRegistrationFilter(filter, candidate))
                                {
                                    static if (includeCommands && commandMembers)
                                        registerCommandMembers!memberSymbol(filter);
                                    static if (includeEvents && eventMembers)
                                    {
                                        if (filter.includeEvents)
                                            registerEventMembersFiltered!memberSymbol(filter);
                                    }
                                    static if (includePlugins && pluginLike)
                                    {
                                        if (filter.includePlugins)
                                            registerPlugin!memberSymbol();
                                    }
                                    static if (includeTasks && taskMembers)
                                    {
                                        if (filter.includeTasks)
                                            registerTaskMembersFiltered!memberSymbol(filter);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private void registerCommandMembers(T)(CommandRegistrationFilter filter)
    {
        static foreach (memberName; __traits(allMembers, T))
        {
            {
                static if (memberName != "__ctor" && memberName != "__xdtor")
                {
                    mixin("alias memberSymbol = T." ~ memberName ~ ";");
                    static if (isCallable!memberSymbol)
                    {
                        enum hasAttrs = __traits(getAttributes, memberSymbol).length > 0;
                        static if (hasAttrs && hasCommandRegistrationAttr!memberSymbol)
                        {
                            enum candidate = describeCommandMemberCandidate!(T, memberName)();
                            if (matchesRegistrationFilter(filter, candidate))
                                commands.registerMember!(T, memberName)();
                        }
                    }
                }
            }
        }
    }

    private void registerEventMembersFiltered(T)(CommandRegistrationFilter filter)
    {
        static foreach (memberName; __traits(allMembers, T))
        {
            {
                static if (memberName != "__ctor" && memberName != "__xdtor")
                {
                    mixin("alias memberSymbol = T." ~ memberName ~ ";");
                    static if (isCallable!memberSymbol)
                    {
                        enum hasAttrs = __traits(getAttributes, memberSymbol).length > 0;
                        static if (hasAttrs && hasEventAttr!memberSymbol)
                        {
                            enum candidate = describeEventMemberCandidate!(T, memberName)();
                            if (matchesRegistrationFilter(filter, candidate))
                                registerStatefulEvent!(T, memberName)();
                        }
                    }
                }
            }
        }
    }

    private void registerTaskMembersFiltered(T)(CommandRegistrationFilter filter)
    {
        commands.register!T();

        static foreach (memberName; __traits(allMembers, T))
        {
            {
                static if (memberName != "__ctor" && memberName != "__xdtor")
                {
                    mixin("alias memberSymbol = T." ~ memberName ~ ";");
                    static if (isCallable!memberSymbol)
                    {
                        enum hasAttrs = __traits(getAttributes, memberSymbol).length > 0;
                        static if (hasAttrs && hasTaskAttr!memberSymbol)
                        {
                            enum candidate = describeTaskMemberCandidate!(T, memberName)();
                            if (matchesRegistrationFilter(filter, candidate))
                                registerStatefulTask!(T, memberName)();
                        }
                    }
                }
            }
        }
    }

    private ApplicationCommandDefinition[] normalizeCommands(ApplicationCommandDefinition[] definitions)
    {
        auto normalized = definitions.dup;
        sort!((left, right) {
            if (left.type == right.type)
                return left.name < right.name;
            return cast(int) left.type < cast(int) right.type;
        })(normalized);
        return normalized;
    }

    private void syncCommandExecutionSettings()
    {
        CommandExecutionSettings settings;
        settings.ownerId = config.ownerId;
        services.add!CommandExecutionSettings(settings);
    }

    private void registerBuiltInCommandMiddlewares()
    {
        commands.registerMiddleware("guild_only", guildOnlyMiddleware());
        commands.registerMiddleware("dm_only", directMessageOnlyMiddleware());
        commands.registerMiddleware("owner_only", ownerOnlyMiddleware());
    }

    private void logOwnerConfiguration()
    {
        auto ownerCommands = commands.ownerRestrictedCommandNames;
        if (ownerCommands.length == 0)
            return;

        if (config.ownerId.isNull)
        {
            string commandList = "`" ~ ownerCommands[0] ~ "`";
            foreach (name; ownerCommands[1 .. $])
                commandList ~= ", `" ~ name ~ "`";

            logger.warning(
                "commands",
                "Owner-restricted commands are registered (" ~ commandList ~
                "), but `ClientConfig.ownerId` is not set. Those commands will deny every invoker until an owner ID is configured."
            );
            return;
        }

        logger.information(
            "commands",
            "Configured bot owner `" ~ config.ownerId.get.toString ~ "` for owner-restricted commands."
        );
    }

    private void deactivatePluginsIfNeeded()
    {
        if (!_pluginsActive)
            return;

        plugins.deactivateAll();
        _pluginsActive = false;
    }
}

private template hasCommandRegistrationAttr(alias fn)
{
    static if (__traits(getAttributes, fn).length == 0)
    {
        enum bool hasCommandRegistrationAttr = false;
    }
    else
    {
        enum bool hasCommandRegistrationAttr = hasCommandRegistrationAttrImpl!(__traits(getAttributes, fn));
    }
}

private template hasCommandRegistrationAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasCommandRegistrationAttrImpl = false;
    }
    else static if (
        is(typeof(attrs[0]) == Command) ||
        is(typeof(attrs[0]) == HybridCommand) ||
        is(typeof(attrs[0]) == SlashCommand) ||
        is(typeof(attrs[0]) == PrefixCommand) ||
        is(typeof(attrs[0]) == MessageCommand) ||
        is(typeof(attrs[0]) == UserCommand)
    )
    {
        enum bool hasCommandRegistrationAttrImpl = true;
    }
    else
    {
        enum bool hasCommandRegistrationAttrImpl = hasCommandRegistrationAttrImpl!(attrs[1 .. $]);
    }
}

private template typeHasCommandMembers(T)
{
    enum bool typeHasCommandMembers = typeHasCommandMembersImpl!(T, __traits(allMembers, T));
}

private template typeHasCommandMembersImpl(T, members...)
{
    static if (members.length == 0)
    {
        enum bool typeHasCommandMembersImpl = false;
    }
    else static if (members[0] == "__ctor" || members[0] == "__xdtor")
    {
        enum bool typeHasCommandMembersImpl = typeHasCommandMembersImpl!(T, members[1 .. $]);
    }
    else
    {
        mixin("alias memberSymbol = T." ~ members[0] ~ ";");
        static if (isCallable!memberSymbol && __traits(getAttributes, memberSymbol).length > 0 && hasCommandRegistrationAttr!memberSymbol)
        {
            enum bool typeHasCommandMembersImpl = true;
        }
        else
        {
            enum bool typeHasCommandMembersImpl = typeHasCommandMembersImpl!(T, members[1 .. $]);
        }
    }
}

private template typeHasEventMembers(T)
{
    enum bool typeHasEventMembers = typeHasEventMembersImpl!(T, __traits(allMembers, T));
}

private template typeHasEventMembersImpl(T, members...)
{
    static if (members.length == 0)
    {
        enum bool typeHasEventMembersImpl = false;
    }
    else static if (members[0] == "__ctor" || members[0] == "__xdtor")
    {
        enum bool typeHasEventMembersImpl = typeHasEventMembersImpl!(T, members[1 .. $]);
    }
    else
    {
        mixin("alias memberSymbol = T." ~ members[0] ~ ";");
        static if (isCallable!memberSymbol && __traits(getAttributes, memberSymbol).length > 0 && hasEventAttr!memberSymbol)
        {
            enum bool typeHasEventMembersImpl = true;
        }
        else
        {
            enum bool typeHasEventMembersImpl = typeHasEventMembersImpl!(T, members[1 .. $]);
        }
    }
}

private template typeHasTaskMembers(T)
{
    enum bool typeHasTaskMembers = typeHasTaskMembersImpl!(T, __traits(allMembers, T));
}

private template typeHasTaskMembersImpl(T, members...)
{
    static if (members.length == 0)
    {
        enum bool typeHasTaskMembersImpl = false;
    }
    else static if (members[0] == "__ctor" || members[0] == "__xdtor")
    {
        enum bool typeHasTaskMembersImpl = typeHasTaskMembersImpl!(T, members[1 .. $]);
    }
    else
    {
        mixin("alias memberSymbol = T." ~ members[0] ~ ";");
        static if (isCallable!memberSymbol && __traits(getAttributes, memberSymbol).length > 0 && hasTaskAttr!memberSymbol)
        {
            enum bool typeHasTaskMembersImpl = true;
        }
        else
        {
            enum bool typeHasTaskMembersImpl = typeHasTaskMembersImpl!(T, members[1 .. $]);
        }
    }
}

private string moduleFromQualifiedName(string qualifiedName)
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

private string categoryFromAttrs(attrs...)()
{
    static foreach (attr; attrs)
    {
        static if (is(typeof(attr) == CommandCategory))
            return attr.name;
    }

    return "";
}

private RegistrationCandidate describeCallableCandidate(alias fn)()
{
    RegistrationCandidate candidate;
    candidate.moduleName = moduleFromQualifiedName(fullyQualifiedName!fn);
    candidate.symbolName = __traits(identifier, fn);
    candidate.commandName = candidate.symbolName;
    candidate.freeFunction = true;
    candidate.command = hasCommandRegistrationAttr!fn;
    candidate.event = hasEventAttr!fn;
    candidate.task = hasTaskAttr!fn;
    candidate.category = categoryFromAttrs!(__traits(getAttributes, fn))();

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (is(typeof(attr) == Command))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == HybridCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == SlashCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == PrefixCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == MessageCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == UserCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == Task))
        {
            auto label = attr.label.strip;
            if (label.length != 0)
                candidate.commandName = label;
        }
    }

    return candidate;
}

private RegistrationCandidate describeTypeCandidate(T)()
{
    RegistrationCandidate candidate;
    candidate.moduleName = moduleFromQualifiedName(fullyQualifiedName!T);
    candidate.ownerName = T.stringof;
    candidate.symbolName = T.stringof;
    candidate.typeSymbol = true;
    candidate.command = typeHasCommandMembers!T;
    candidate.event = typeHasEventMembers!T;
    candidate.plugin = HasLuaPluginAttr!T;
    candidate.task = typeHasTaskMembers!T;
    return candidate;
}

private RegistrationCandidate describeCommandMemberCandidate(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    auto candidate = describeTypeCandidate!T();
    candidate.symbolName = memberName;
    candidate.command = true;
    candidate.event = false;
    candidate.category = categoryFromAttrs!(__traits(getAttributes, memberSymbol))();
    candidate.commandName = memberName;

    static foreach (attr; __traits(getAttributes, memberSymbol))
    {
        static if (is(typeof(attr) == Command))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == HybridCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == SlashCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == PrefixCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == MessageCommand))
            candidate.commandName = attr.name;
        else static if (is(typeof(attr) == UserCommand))
            candidate.commandName = attr.name;
    }

    return candidate;
}

private RegistrationCandidate describeTaskMemberCandidate(T, string memberName)()
{
    mixin("alias memberSymbol = T." ~ memberName ~ ";");
    auto candidate = describeTypeCandidate!T();
    candidate.symbolName = memberName;
    candidate.command = false;
    candidate.event = false;
    candidate.task = true;
    candidate.commandName = memberName;

    static foreach (attr; __traits(getAttributes, memberSymbol))
    {
        static if (is(typeof(attr) == Task))
        {
            auto label = attr.label.strip;
            if (label.length != 0)
                candidate.commandName = label;
        }
    }

    return candidate;
}

private RegistrationCandidate describeEventMemberCandidate(T, string memberName)()
{
    auto candidate = describeTypeCandidate!T();
    candidate.symbolName = memberName;
    candidate.command = false;
    candidate.event = true;
    return candidate;
}

private template isEventContextType(T)
{
    enum bool isEventContextType =
        is(T == ReadyEventContext) ||
        is(T == ResumedEventContext) ||
        is(T == GuildCreateEventContext) ||
        is(T == GuildDeleteEventContext) ||
        is(T == GuildMemberRemoveEventContext) ||
        is(T == GuildMemberAddEventContext) ||
        is(T == GuildBanAddEventContext) ||
        is(T == GuildBanRemoveEventContext) ||
        is(T == ChannelCreateEventContext) ||
        is(T == ChannelUpdateEventContext) ||
        is(T == ChannelDeleteEventContext) ||
        is(T == ChannelPinsUpdateEventContext) ||
        is(T == MessageCreateEventContext) ||
        is(T == MessageUpdateEventContext) ||
        is(T == MessageDeleteEventContext) ||
        is(T == MessageReactionAddEventContext) ||
        is(T == MessageReactionRemoveEventContext) ||
        is(T == MessageReactionRemoveAllEventContext) ||
        is(T == MessageReactionRemoveEmojiEventContext) ||
        is(T == InteractionCreateEventContext) ||
        is(T == AutocompleteInteractionEventContext) ||
        is(T == MessageComponentEventContext) ||
        is(T == ModalSubmitEventContext) ||
        is(T == PresenceUpdateEventContext) ||
        is(T == TypingStartEventContext) ||
        is(T == GuildRoleCreateEventContext) ||
        is(T == GuildRoleUpdateEventContext) ||
        is(T == GuildRoleDeleteEventContext) ||
        is(T == InviteCreateEventContext) ||
        is(T == InviteDeleteEventContext) ||
        is(T == WebhooksUpdateEventContext) ||
        is(T == ThreadCreateEventContext) ||
        is(T == ThreadUpdateEventContext) ||
        is(T == ThreadDeleteEventContext) ||
        is(T == CommandExecutedEventContext) ||
        is(T == CommandFailedEventContext);
}

private template EventTypeOfContext(T)
{
    static if (is(T == ReadyEventContext))
        alias EventTypeOfContext = ReadyEvent;
    else static if (is(T == ResumedEventContext))
        alias EventTypeOfContext = ResumedEvent;
    else static if (is(T == GuildCreateEventContext))
        alias EventTypeOfContext = GuildCreateEvent;
    else static if (is(T == GuildDeleteEventContext))
        alias EventTypeOfContext = GuildDeleteEvent;
    else static if (is(T == GuildMemberRemoveEventContext))
        alias EventTypeOfContext = GuildMemberRemoveEvent;
    else static if (is(T == GuildMemberAddEventContext))
        alias EventTypeOfContext = GuildMemberAddEvent;
    else static if (is(T == GuildBanAddEventContext))
        alias EventTypeOfContext = GuildBanAddEvent;
    else static if (is(T == GuildBanRemoveEventContext))
        alias EventTypeOfContext = GuildBanRemoveEvent;
    else static if (is(T == ChannelCreateEventContext))
        alias EventTypeOfContext = ChannelCreateEvent;
    else static if (is(T == ChannelUpdateEventContext))
        alias EventTypeOfContext = ChannelUpdateEvent;
    else static if (is(T == ChannelDeleteEventContext))
        alias EventTypeOfContext = ChannelDeleteEvent;
    else static if (is(T == ChannelPinsUpdateEventContext))
        alias EventTypeOfContext = ChannelPinsUpdateEvent;
    else static if (is(T == MessageCreateEventContext))
        alias EventTypeOfContext = MessageCreateEvent;
    else static if (is(T == MessageUpdateEventContext))
        alias EventTypeOfContext = MessageUpdateEvent;
    else static if (is(T == MessageDeleteEventContext))
        alias EventTypeOfContext = MessageDeleteEvent;
    else static if (is(T == MessageReactionAddEventContext))
        alias EventTypeOfContext = MessageReactionAddEvent;
    else static if (is(T == MessageReactionRemoveEventContext))
        alias EventTypeOfContext = MessageReactionRemoveEvent;
    else static if (is(T == MessageReactionRemoveAllEventContext))
        alias EventTypeOfContext = MessageReactionRemoveAllEvent;
    else static if (is(T == MessageReactionRemoveEmojiEventContext))
        alias EventTypeOfContext = MessageReactionRemoveEmojiEvent;
    else static if (is(T == InteractionCreateEventContext))
        alias EventTypeOfContext = InteractionCreateEvent;
    else static if (is(T == AutocompleteInteractionEventContext))
        alias EventTypeOfContext = AutocompleteInteractionEvent;
    else static if (is(T == MessageComponentEventContext))
        alias EventTypeOfContext = MessageComponentEvent;
    else static if (is(T == ModalSubmitEventContext))
        alias EventTypeOfContext = ModalSubmitEvent;
    else static if (is(T == PresenceUpdateEventContext))
        alias EventTypeOfContext = PresenceUpdateEvent;
    else static if (is(T == TypingStartEventContext))
        alias EventTypeOfContext = TypingStartEvent;
    else static if (is(T == GuildRoleCreateEventContext))
        alias EventTypeOfContext = GuildRoleCreateEvent;
    else static if (is(T == GuildRoleUpdateEventContext))
        alias EventTypeOfContext = GuildRoleUpdateEvent;
    else static if (is(T == GuildRoleDeleteEventContext))
        alias EventTypeOfContext = GuildRoleDeleteEvent;
    else static if (is(T == InviteCreateEventContext))
        alias EventTypeOfContext = InviteCreateEvent;
    else static if (is(T == InviteDeleteEventContext))
        alias EventTypeOfContext = InviteDeleteEvent;
    else static if (is(T == WebhooksUpdateEventContext))
        alias EventTypeOfContext = WebhooksUpdateEvent;
    else static if (is(T == ThreadCreateEventContext))
        alias EventTypeOfContext = ThreadCreateEvent;
    else static if (is(T == ThreadUpdateEventContext))
        alias EventTypeOfContext = ThreadUpdateEvent;
    else static if (is(T == ThreadDeleteEventContext))
        alias EventTypeOfContext = ThreadDeleteEvent;
    else static if (is(T == CommandExecutedEventContext))
        alias EventTypeOfContext = CommandExecutedEvent;
    else static if (is(T == CommandFailedEventContext))
        alias EventTypeOfContext = CommandFailedEvent;
    else
        static assert(false, "Unsupported event context type.");
}

private template hasEventAttr(alias fn)
{
    static if (__traits(getAttributes, fn).length == 0)
    {
        enum bool hasEventAttr = false;
    }
    else
    {
        enum bool hasEventAttr = hasEventAttrImpl!(__traits(getAttributes, fn));
    }
}

private template hasTaskAttr(alias fn)
{
    static if (__traits(getAttributes, fn).length == 0)
    {
        enum bool hasTaskAttr = false;
    }
    else
    {
        enum bool hasTaskAttr = hasTaskAttrImpl!(__traits(getAttributes, fn));
    }
}

private template hasTaskAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasTaskAttrImpl = false;
    }
    else static if (is(typeof(attrs[0]) == Task))
    {
        enum bool hasTaskAttrImpl = true;
    }
    else
    {
        enum bool hasTaskAttrImpl = hasTaskAttrImpl!(attrs[1 .. $]);
    }
}

private Task taskSpec(alias fn)()
{
    Task spec;

    static foreach (attr; __traits(getAttributes, fn))
    {
        static if (is(typeof(attr) == Task))
        {
            spec = attr;
        }
    }

    return spec;
}

private template hasEventAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasEventAttrImpl = false;
    }
    else static if (__traits(compiles, typeof(attrs[0])) && is(typeof(attrs[0]) == Event))
    {
        enum bool hasEventAttrImpl = true;
    }
    else static if (is(attrs[0] == Event))
    {
        enum bool hasEventAttrImpl = true;
    }
    else
    {
        enum bool hasEventAttrImpl = hasEventAttrImpl!(attrs[1 .. $]);
    }
}

private template EventSubscriptionType(alias handler)
{
    static if (Parameters!handler.length != 1)
    {
        static assert(false, "@Event handlers must accept exactly one event or event-context parameter.");
    }
    else static if (isEventContextType!(Parameters!handler[0]))
    {
        alias EventSubscriptionType = EventTypeOfContext!(Parameters!handler[0]);
    }
    else
    {
        alias EventSubscriptionType = Parameters!handler[0];
    }
}

private void invokeFreeEvent(alias handler, E)(E event)
{
    alias ParamType = Parameters!handler[0];

    static if (isEventContextType!ParamType)
    {
        static if (is(E == ReadyEvent))
            handler(event.context);
        else static if (is(E == ResumedEvent))
            handler(event.context);
        else static if (is(E == GuildCreateEvent))
            handler(event.context);
        else static if (is(E == GuildDeleteEvent))
            handler(event.context);
        else static if (is(E == GuildMemberRemoveEvent))
            handler(event.context);
        else static if (is(E == GuildMemberAddEvent))
            handler(event.context);
        else static if (is(E == GuildBanAddEvent))
            handler(event.context);
        else static if (is(E == GuildBanRemoveEvent))
            handler(event.context);
        else static if (is(E == ChannelCreateEvent))
            handler(event.context);
        else static if (is(E == ChannelUpdateEvent))
            handler(event.context);
        else static if (is(E == ChannelDeleteEvent))
            handler(event.context);
        else static if (is(E == ChannelPinsUpdateEvent))
            handler(event.context);
        else static if (is(E == MessageCreateEvent))
            handler(event.context);
        else static if (is(E == MessageUpdateEvent))
            handler(event.context);
        else static if (is(E == MessageDeleteEvent))
            handler(event.context);
        else static if (is(E == MessageReactionAddEvent))
            handler(event.context);
        else static if (is(E == MessageReactionRemoveEvent))
            handler(event.context);
        else static if (is(E == MessageReactionRemoveAllEvent))
            handler(event.context);
        else static if (is(E == MessageReactionRemoveEmojiEvent))
            handler(event.context);
        else static if (is(E == InteractionCreateEvent))
            handler(event.context);
        else static if (is(E == AutocompleteInteractionEvent))
            handler(event.context);
        else static if (is(E == MessageComponentEvent))
            handler(event.context);
        else static if (is(E == ModalSubmitEvent))
            handler(event.context);
        else static if (is(E == PresenceUpdateEvent))
            handler(event.context);
        else static if (is(E == TypingStartEvent))
            handler(event.context);
        else static if (is(E == GuildRoleCreateEvent))
            handler(event.context);
        else static if (is(E == GuildRoleUpdateEvent))
            handler(event.context);
        else static if (is(E == GuildRoleDeleteEvent))
            handler(event.context);
        else static if (is(E == InviteCreateEvent))
            handler(event.context);
        else static if (is(E == InviteDeleteEvent))
            handler(event.context);
        else static if (is(E == WebhooksUpdateEvent))
            handler(event.context);
        else static if (is(E == ThreadCreateEvent))
            handler(event.context);
        else static if (is(E == ThreadUpdateEvent))
            handler(event.context);
        else static if (is(E == ThreadDeleteEvent))
            handler(event.context);
        else static if (is(E == CommandExecutedEvent))
            handler(event.context);
        else static if (is(E == CommandFailedEvent))
            handler(event.context);
        else
            static assert(false, "Unsupported @Event payload type.");
    }
    else
    {
        handler(event);
    }
}

private void invokeStatefulEvent(T, alias member, E)(T instance, E event)
{
    alias ParamType = Parameters!member[0];

    static if (isEventContextType!ParamType)
    {
        mixin("instance." ~ __traits(identifier, member) ~ "(event.context);");
    }
    else
    {
        mixin("instance." ~ __traits(identifier, member) ~ "(event);");
    }
}

private Arg resolveTaskArgument(Arg)(Client client)
{
    static if (is(Arg == Client))
    {
        return client;
    }
    else static if (is(Arg == ServiceContainer))
    {
        return client.services;
    }
    else static if (is(Arg == TaskScheduler))
    {
        return client.tasks;
    }
    else static if (is(Arg == RestClient))
    {
        return client.rest;
    }
    else static if (is(Arg == CacheStore))
    {
        return client.cache;
    }
    else static if (is(Arg == StateStore))
    {
        return client.state;
    }
    else static if (is(Arg == Logger))
    {
        return client.logger;
    }
    else
    {
        return client.services.get!Arg();
    }
}

private void invokeFreeTask(alias handler)(Client client)
{
    alias Params = Parameters!handler;
    Tuple!Params bound;

    static foreach (index, Param; Params)
    {
        bound[index] = resolveTaskArgument!Param(client);
    }

    handler(bound.expand);
}

private void invokeStatefulTask(T, alias member)(Client client, T instance)
{
    alias Params = Parameters!member;
    Tuple!Params bound;

    static foreach (index, Param; Params)
    {
        bound[index] = resolveTaskArgument!Param(client);
    }

    mixin("instance." ~ __traits(identifier, member) ~ "(bound.expand);");
}

private template IsTypeSymbol(alias symbol)
{
    enum bool IsTypeSymbol = is(symbol == class) || is(symbol == struct) || is(symbol == interface);
}

private template HasLuaPluginAttr(T)
{
    static if (__traits(getAttributes, T).length == 0)
    {
        enum bool HasLuaPluginAttr = false;
    }
    else
    {
        enum bool HasLuaPluginAttr = hasLuaPluginAttrImpl!(__traits(getAttributes, T));
    }
}

private template hasLuaPluginAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasLuaPluginAttrImpl = false;
    }
    else static if (is(typeof(attrs[0]) == LuaPlugin))
    {
        enum bool hasLuaPluginAttrImpl = true;
    }
    else
    {
        enum bool hasLuaPluginAttrImpl = hasLuaPluginAttrImpl!(attrs[1 .. $]);
    }
}

private @Command("ping", routes: CommandRoute.Prefix)
void clientUnittestPing(CommandContext ctx)
{
    ctx.send("pong").await();
}

@UserCommand("inspect-user")
private void clientUnittestInspectUser(ContextMenuContext ctx)
{
    assert(ctx.isContextMenu);
    ctx.send("inspected").await();
}

@CommandCategory("Testing")
private @HybridCommand("alpha", "Alpha command for builtin help")
void clientUnittestAlpha(HybridContext ctx)
{
    ctx.send("alpha").await();
}

@HideFromHelp
private @Command("hidden-alpha", routes: CommandRoute.Prefix)
void clientUnittestHiddenAlpha(CommandContext ctx)
{
    ctx.send("hidden").await();
}

private AutocompleteChoice[] clientUnittestSongAutocomplete(string partial)
{
    return [
        AutocompleteChoice("Song " ~ partial, partial ~ "-1"),
        AutocompleteChoice("Song " ~ partial ~ " 2", partial ~ "-2"),
    ];
}

@SlashCommand("play")
@Autocomplete!clientUnittestSongAutocomplete("song")
private void clientUnittestPlayAutocomplete(SlashContext ctx, string song)
{
    auto _ = ctx;
    auto __ = song;
}

private bool clientUnittestReadyEventSeen;
private int clientUnittestTaskCalls;
private bool clientUnittestTaskResolved;

private @Event
void clientUnittestOnReady(ReadyEventContext ctx)
{
    clientUnittestReadyEventSeen = ctx.selfUser.username == "tester";
}

@Task(dur!"seconds"(30), label: "free-task")
private void clientUnittestFreeTask()
{
    clientUnittestTaskCalls++;
}

@Task(dur!"seconds"(30), label: "task-with-params")
private void clientUnittestTaskWithParams(
    TaskScheduler scheduler,
    ServiceContainer services,
    Client client
)
{
    clientUnittestTaskResolved = scheduler !is null && services !is null && client !is null;
}

@Task(dur!"seconds"(1), label: "counted-task", count: 2)
private void clientUnittestCountedTask()
{
    clientUnittestTaskCalls++;
}

static assert(hasEventAttr!clientUnittestOnReady);

@RequirePermissions(Permissions.SendMessages)
private @Command("secure-ping", routes: CommandRoute.Prefix)
void clientUnittestSecurePing(CommandContext ctx)
{
    ctx.send("allowed").await();
}

private bool clientUnittestMessageEventSeen;

private @Event
void clientUnittestOnMessage(MessageCreateEventContext ctx)
{
    clientUnittestMessageEventSeen = ctx.message.content == "hello" &&
        !ctx.user.isNull &&
        ctx.user.get.username == "alice";
}

static assert(hasEventAttr!clientUnittestOnMessage);

private struct ClientUnittestEventGroup
{
    @Event
    void onMessage(MessageCreateEventContext ctx)
    {
        clientUnittestMessageEventSeen = ctx.message.content == "group" &&
            !ctx.user.isNull &&
            ctx.user.get.username == "group-user";
    }
}

static assert(hasEventAttr!(ClientUnittestEventGroup.onMessage));

@LuaPlugin("counter")
private struct ClientUnittestCounterPlugin
{
}

private struct ClientUnittestAdminGroup
{
    @Command("group-ping", routes: CommandRoute.Prefix)
    void run(CommandContext ctx)
    {
        auto _ = ctx;
    }
}

private struct ClientUnittestAutoGroup
{
    @CommandCategory("Testing")
    @Command("group-auto", routes: CommandRoute.Prefix)
    void run(CommandContext ctx)
    {
        ctx.send("group-auto").await();
    }
}

private final class CounterService
{
    size_t hits;
}

private struct ClientUnittestTaskGroup
{
    @Inject CounterService counter;

    @Task(dur!"seconds"(30), label: "group-task")
    void tick()
    {
        counter.hits++;
    }
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    bool seen;

    client.on!int((value) { seen = value == 5; });
    client.emit!int(5);

    assert(seen);
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    auto filter = CommandRegistrationFilter.names("alpha", "group-auto");

    client.registerAllCommands(filter);

    assert(!client.commands.find("alpha", CommandRoute.Prefix).isNull);
    assert(!client.commands.find("group-auto", CommandRoute.Prefix).isNull);
    assert(client.commands.find("hidden-alpha", CommandRoute.Prefix).isNull);
}

unittest
{
    string[] bodies;
    HttpTransport transport = (request) {
        bodies ~= cast(string) request.body;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"ok","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.logger.minimumLevel = cast(LogLevel) -1;
    client.helpBehavior.pageSize = 1;
    client.registerCommands(CommandRegistrationFilter.names("alpha", "ping", "hidden-alpha"));

    Message message;
    message.channelId = Snowflake(10);
    message.content = "!help";
    message.author.id = Snowflake(22);
    message.author.username = "alice";

    auto result = client.receiveMessage(message);
    assert(result.isOk);
    assert(bodies.length == 1);
    assert(bodies[0].canFind(`"flags":32768`));
    assert(bodies[0].canFind(`"type":17`));
    assert(!client.commands.find("help", CommandRoute.Prefix).isNull);
    assert(client.commands.find("hidden-alpha", CommandRoute.Prefix).get.hiddenFromHelp);
}

unittest
{
    string[] bodies;
    HttpTransport transport = (request) {
        bodies ~= cast(string) request.body;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"ok","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.logger.minimumLevel = cast(LogLevel) -1;
    client.registerCommands(CommandRegistrationFilter.names("alpha", "ping"));

    Message message;
    message.channelId = Snowflake(10);
    message.content = "!help ALPHA";
    message.author.id = Snowflake(22);
    message.author.username = "alice";

    auto result = client.receiveMessage(message);
    assert(result.isOk);
    assert(bodies.length == 1);
    assert(bodies[0].canFind("Filter: `ALPHA`"));
    assert(bodies[0].canFind("**alpha**"));
    assert(!bodies[0].canFind("**ping**"));
}

unittest
{
    string[] bodies;
    HttpTransport transport = (request) {
        bodies ~= cast(string) request.body;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"ok","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.logger.minimumLevel = cast(LogLevel) -1;

    Message message;
    message.channelId = Snowflake(10);
    message.content = "!missing-command";
    message.author.id = Snowflake(22);
    message.author.username = "alice";

    auto result = client.receiveMessage(message);
    assert(result.isErr);
    assert(bodies.length == 1);
    assert(bodies[0].canFind("was not found"));

    bodies.length = 0;
    client.errorBehavior.surfaceUnknownCommand = false;
    auto hidden = client.receiveMessage(message);
    assert(hidden.isErr);
    assert(bodies.length == 0);
}

unittest
{
    clientUnittestReadyEventSeen = false;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerAllCommands!clientUnittestOnReady();

    ReadyEvent event;
    event.selfUser.username = "tester";
    event.context.selfUser = event.selfUser;
    client.emit!ReadyEvent(event);

    assert(clientUnittestReadyEventSeen);
}

unittest
{
    clientUnittestMessageEventSeen = false;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerAllCommands!clientUnittestOnMessage();

    MessageCreateEvent event;
    event.message.content = "hello";
    event.message.author.username = "alice";
    event.context.message = event.message;
    event.context.event.currentUser = Nullable!User.of(event.message.author);
    client.emit!MessageCreateEvent(event);

    assert(clientUnittestMessageEventSeen);
}

unittest
{
    clientUnittestMessageEventSeen = false;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerAllCommands!ClientUnittestEventGroup();

    MessageCreateEvent event;
    event.message.content = "group";
    event.message.author.username = "group-user";
    event.context.message = event.message;
    event.context.event.currentUser = Nullable!User.of(event.message.author);
    client.emit!MessageCreateEvent(event);

    assert(clientUnittestMessageEventSeen);
}

unittest
{
    import std.exception : assertThrown;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client._running = true;
    assertThrown!DdiscordException(client.run());
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    bool sawAutocomplete;
    bool sawCommandFailure;

    client.on!AutocompleteInteractionEvent((_event) {
        sawAutocomplete = true;
    });
    client.on!CommandFailedEvent((_event) {
        sawCommandFailure = true;
    });

    Interaction interaction;
    interaction.id = Snowflake(1);
    interaction.type = InteractionType.ApplicationCommandAutocomplete;
    interaction.commandName = "ping";
    interaction.token = "abc";

    auto result = client.receiveInteraction(interaction);
    assert(result.isOk);
    assert(sawAutocomplete);
    assert(!sawCommandFailure);
}

unittest
{
    import std.json : JSONValue, parseJSON;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.registerCommands!clientUnittestPlayAutocomplete();

    Interaction interaction;
    interaction.id = Snowflake(1);
    interaction.type = InteractionType.ApplicationCommandAutocomplete;
    interaction.commandName = "play";
    interaction.token = "autocomplete-token";
    interaction.user.id = Snowflake(100);
    interaction.user.username = "autocomplete-user";

    InteractionOption option;
    option.name = "song";
    option.value = "hea";
    option.focused = true;
    interaction.options = [option];

    auto result = client.receiveInteraction(interaction);
    assert(result.isOk);

    assert(captured.length == 1);
    assert(captured[0].url.canFind("/interactions/1/autocomplete-token/callback"));
    auto payload = parseJSON(cast(string) captured[0].body);
    assert(payload.object.get("type", JSONValue.init).integer == 8);
    auto choices = payload.object.get("data", JSONValue.init).object.get("choices", JSONValue.init).array;
    assert(choices.length == 2);
    assert(choices[0].object.get("name", JSONValue.init).str == "Song hea");
}

unittest
{
    import std.json : JSONValue, parseJSON;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.registerCommands!clientUnittestInspectUser();

    Interaction interaction;
    interaction.id = Snowflake(42);
    interaction.type = InteractionType.ApplicationCommand;
    interaction.commandType = ApplicationCommandType.User;
    interaction.commandName = "inspect-user";
    interaction.token = "context-token";
    interaction.user.id = Snowflake(101);
    interaction.user.username = "context-user";

    auto result = client.receiveInteraction(interaction);
    assert(result.isOk);
    assert(captured.length == 1);
    assert(captured[0].url.canFind("/interactions/42/context-token/callback"));

    auto payload = parseJSON(cast(string) captured[0].body);
    assert(payload.object.get("type", JSONValue.init).integer == 4);
    assert(payload.object.get("data", JSONValue.init).object.get("content", JSONValue.init).str == "inspected");
}

unittest
{
    HttpTransport transport = (request) {
        HttpResponse response;

        if (request.url.canFind("/channels/10/messages"))
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"pong","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.statusCode = 404;
        response.body = cast(ubyte[]) `{"message":"Not Found"}`.dup;
        return Result!(HttpResponse, HttpError).err(HttpError(
            kind: HttpErrorKind.NotFound,
            message: "not found",
            method: "POST",
            url: request.url
        ));
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.registerCommands!clientUnittestPing();

    Message message;
    message.channelId = Snowflake(10);
    message.content = "!ping";
    message.author.id = Snowflake(22);
    message.author.username = "alice";

    auto result = client.receiveMessage(message);
    assert(result.isOk);
    assert(client.sentMessages.length == 1);
    assert(client.sentMessages[0].content == "pong");
}

unittest
{
    HttpTransport transport = (request) {
        HttpResponse response;
        response.statusCode = 200;

        if (request.url.canFind("/guilds/77") && !request.url.canFind("/members/") && !request.url.canFind("/roles"))
        {
            response.body = cast(ubyte[]) `{"id":"77","name":"Guild","owner_id":"999"}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.url.canFind("/guilds/77/members/22"))
        {
            response.body = cast(ubyte[]) `{"user":{"id":"22","username":"alice"},"roles":["5"]}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.url.canFind("/guilds/77/roles"))
        {
            response.body = cast(ubyte[]) `[
                {"id":"77","name":"@everyone","permissions":"0"},
                {"id":"5","name":"writer","permissions":"2048"}
            ]`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.url.canFind("/channels/10") && !request.url.canFind("/messages"))
        {
            response.body = cast(ubyte[]) `{"id":"10","guild_id":"77","name":"general","type":0}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.url.canFind("/channels/10/messages"))
        {
            response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"allowed","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.statusCode = 404;
        response.body = cast(ubyte[]) `{"message":"Not Found"}`.dup;
        return Result!(HttpResponse, HttpError).err(HttpError(
            kind: HttpErrorKind.NotFound,
            message: "not found",
            method: "GET",
            url: request.url
        ));
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.registerAllCommands!clientUnittestSecurePing();

    Message message;
    message.id = Snowflake(1UL << 22);
    message.guildId = Nullable!Snowflake.of(Snowflake(77));
    message.channelId = Snowflake(10);
    message.content = "!secure-ping";
    message.author.id = Snowflake(22);
    message.author.username = "alice";

    auto result = client.receiveMessage(message);
    assert(result.isOk);
    assert(client.sentMessages.length == 1);
    assert(client.sentMessages[0].content == "allowed");
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerAllCommands!(clientUnittestPing, ClientUnittestAdminGroup, ClientUnittestCounterPlugin);

    assert(!client.commands.find("ping", CommandRoute.Prefix).isNull);
    assert(!client.commands.find("group-ping", CommandRoute.Prefix).isNull);
    assert(client.plugins.registeredNames.canFind("counter"));
}

unittest
{
    clientUnittestTaskCalls = 0;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerTasks!clientUnittestFreeTask();

    assert(client.runTaskNow("free-task"));
    assert(clientUnittestTaskCalls == 1);
}

unittest
{
    clientUnittestTaskResolved = false;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerTasks!clientUnittestTaskWithParams();

    assert(client.runTaskNow("task-with-params"));
    assert(clientUnittestTaskResolved);
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.addService!CounterService(new CounterService);
    client.registerTaskGroup!ClientUnittestTaskGroup();

    assert(client.runTaskNow("group-task"));
    assert(client.service!CounterService().hits == 1);
}

unittest
{
    clientUnittestTaskCalls = 0;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerAllCommands!clientUnittestFreeTask();

    assert(client.runTaskNow("free-task"));
    assert(clientUnittestTaskCalls == 1);
}

unittest
{
    clientUnittestTaskCalls = 0;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    auto filter = CommandRegistrationFilter.names("free-task").withoutTasks();
    client.registerAllCommands(filter);

    assert(!client.runTaskNow("free-task"));
}

unittest
{
    clientUnittestTaskCalls = 0;

    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.registerTasks!clientUnittestCountedTask();

    assert(client.runTaskNow("counted-task"));
    assert(client.runTaskNow("counted-task"));
    assert(!client.runTaskNow("counted-task"));
    assert(clientUnittestTaskCalls == 2);
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.config.enableSharding = true;
    client.config.autoSharding = true;

    GatewayBotInfo info;
    info.shards = 4;
    info.url = "wss://gateway.discord.gg";
    client._gatewayInfo = Nullable!GatewayBotInfo.of(info);

    assert(client.resolvedShardCount() == 4);
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));
    client.reshard(3);

    assert(client.config.enableSharding);
    assert(!client.config.autoSharding);
    assert(client.config.shardCount == 3);
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));

    assert(client.messages is client.rest.messages);
    assert(client.users is client.rest.users);
    assert(client.apps is client.rest.applications);
    assert(client.applications is client.rest.applications);
    assert(client.channels is client.rest.channels);
    assert(client.reactions is client.rest.reactions);
    assert(client.threads is client.rest.threads);
    assert(client.webhooks is client.rest.webhooks);
    assert(client.guilds is client.rest.guilds);
    assert(client.interactions is client.rest.interactions);
    assert(client.slash is client.rest.applicationCommands);
    assert(client.gatewayApi is client.rest.gateway);
}

unittest
{
    struct OwnerGroup
    {
        @RequireOwner
        @Command("owner-only", routes: CommandRoute.Prefix)
        void run(CommandContext ctx)
        {
            ctx.send("should not send").await();
        }
    }

    HttpTransport transport = (request) {
        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"should not send","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        ownerId: Nullable!Snowflake.of(Snowflake(999)),
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.logger.minimumLevel = cast(LogLevel) -1;
    client.registerAllCommands!OwnerGroup();

    Message message;
    message.channelId = Snowflake(10);
    message.content = "!owner-only";
    message.author.id = Snowflake(22);
    message.author.username = "alice";

    auto result = client.receiveMessage(message);
    assert(result.isErr);
    assert(client.sentMessages.length == 0);
}

unittest
{
    struct OwnerGroup
    {
        @RequireOwner
        @Command("owner-refresh", routes: CommandRoute.Prefix)
        void run(CommandContext ctx)
        {
            ctx.send("ok").await();
        }
    }

    HttpTransport transport = (request) {
        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"10","content":"ok","author":{"id":"999","username":"ddiscord","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        transport: Nullable!HttpTransport.of(transport)
    ));
    client.registerAllCommands!OwnerGroup();
    client.config.ownerId = Nullable!Snowflake.of(Snowflake(42));

    Message message;
    message.channelId = Snowflake(10);
    message.content = "!owner-refresh";
    message.author.id = Snowflake(42);
    message.author.username = "owner";

    auto result = client.receiveMessage(message);
    assert(result.isOk);
    assert(client.sentMessages.length == 1);
    assert(client.sentMessages[0].content == "ok");
}

unittest
{
    auto client = new Client(ClientConfig(
        "token",
        cast(uint) GatewayIntent.Guilds,
        maxDispatchQueueSize: 2,
        dropOldestDispatchOnOverflow: false,
        dispatchOverflowLogEvery: 0
    ));

    Message one;
    one.content = "!one";
    Message two;
    two.content = "!two";
    Message three;
    three.content = "!three";

    client.enqueueMessage(one);
    client.enqueueMessage(two);
    client.enqueueMessage(three);

    auto health = client.dispatchQueueHealth;
    assert(health.maxQueued == 2);
    assert(health.queued == 2);
    assert(health.peakQueued == 2);
    assert(health.droppedTotal == 1);
}

unittest
{
    auto client = new Client(ClientConfig("token", cast(uint) GatewayIntent.Guilds));

    ApplicationCommandDefinition leftRoll;
    leftRoll.name = "roll";
    leftRoll.description = "Roll";
    ApplicationCommandOption leftRollOption;
    leftRollOption.name = "sides";
    leftRollOption.description = "sides";
    leftRollOption.type = ApplicationCommandOptionType.Integer;
    leftRollOption.required = false;
    leftRoll.options = [leftRollOption];

    ApplicationCommandDefinition leftInfo;
    leftInfo.name = "info";
    leftInfo.description = "Info";

    ApplicationCommandDefinition rightInfo;
    rightInfo.name = "info";
    rightInfo.description = "Info";

    ApplicationCommandDefinition rightRoll;
    rightRoll.name = "roll";
    rightRoll.description = "Roll";
    ApplicationCommandOption rightRollOption;
    rightRollOption.name = "sides";
    rightRollOption.description = "sides";
    rightRollOption.type = ApplicationCommandOptionType.Integer;
    rightRollOption.required = false;
    rightRoll.options = [rightRollOption];

    assert(client.sameCommands([leftRoll, leftInfo], [rightInfo, rightRoll]));
}
