/**
 * ddiscord — client façade.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, dur;
import ddiscord.cache : CacheStore;
import ddiscord.commands : Command, CommandExecution, CommandExecutionSettings, CommandRegistry,
    CommandRoute, ParsedCommand, RequireOwner, RequirePermissions;
import ddiscord.context.command : CommandContext, CommandSource;
import ddiscord.events.dispatcher : EventDispatcher;
import ddiscord.events.types : CommandExecutedEvent, CommandFailedEvent, InteractionCreateEvent,
    MessageCreateEvent, PresenceUpdateEvent, ReadyEvent, ResumedEvent;
import ddiscord.gateway.client : GatewayClient, GatewayClientConfig, GatewayReadyInfo;
import ddiscord.gateway.intents : GatewayIntent;
import ddiscord.logging : LogLevel, Logger;
import ddiscord.models.application_command : ApplicationCommandDefinition, ApplicationCommandOption,
    ApplicationCommandOptionType, InteractionType;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message, MessageCreate;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.role : Permissions, Role;
import ddiscord.models.user : User;
import ddiscord.plugins : LuaPlugin, PluginRegistry;
import ddiscord.permissions : computeEffectivePermissions;
import ddiscord.core.http.client : HttpError, HttpErrorKind, HttpResponse, HttpTransport;
import ddiscord.rest : GatewayBotInfo, RestClient, RestClientConfig;
import ddiscord.scripting : LuaCapability, LuaRuntime, LuaSandboxProfile, ScriptingEngine;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.tasks : TaskScheduler;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.datetime : Clock;
import std.string : startsWith;
import std.traits : isCallable;

/// Client configuration.
struct ClientConfig
{
    string token;
    uint intents;
    string prefix = "!";
    string pluginsDir = "./plugins";
    Nullable!Snowflake ownerId;
    Nullable!Snowflake applicationId;
    bool autoSyncCommands = true;
    LogLevel logLevel = LogLevel.Information;
    Nullable!HttpTransport transport;
}

/// Simple uptime sample used by docs and examples.
struct UptimeSample
{
    string toString() const
    {
        return "0s";
    }
}

private enum GatewayReadyWatchdogLabel = "gateway-ready-watchdog";

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
    private Thread _dispatchThread;
    private Thread _taskThread;
    private bool _taskLoopRunning;
    private bool _dispatchLoopRunning;
    private Mutex _dispatchMutex;
    private Condition _dispatchAvailable;
    private DispatchItem[] _dispatchQueue;
    private size_t _dispatchQueueHead;

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
        tasks.logger = logger;
        _dispatchMutex = new Mutex;
        _dispatchAvailable = new Condition(_dispatchMutex);

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
        syncCommandExecutionSettings();
        _selfUser.bot = true;
        _selfUser.username = "ddiscord";
    }

    /// Starts the client.
    void run()
    {
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
        _selfUser = me.value;
        _gatewayInfo = Nullable!GatewayBotInfo.of(gateway.value);
        logger.information("client", "Authenticated as `" ~ _selfUser.username ~ "` (" ~ _selfUser.id.toString ~ ").");
        logOwnerConfiguration();
        plugins.loadAll(config.pluginsDir);
        plugins.activateAll(services.get!ScriptingEngine(), state);
        if (config.autoSyncCommands)
            syncCommandsIfChanged();

        cache.store(_selfUser);
        logger.information("client", "Starting gateway and worker loops.");
        startDispatchLoop();
        startTaskLoop();
        startGateway(gateway.value.url);
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

    /// Updates presence.
    void setPresence(StatusType status, Activity activity)
    {
        _status = status;
        _activity = activity;
        if (_gateway !is null)
            _gateway.updatePresence(status, activity);

        PresenceUpdateEvent event;
        event.status = status;
        event.activity = activity;
        emit!PresenceUpdateEvent(event);
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

        return ctx;
    }

    /// Builds a command context for an incoming interaction.
    CommandContext interactionContext(Interaction interaction, Channel channel = Channel.init)
    {
        CommandContext ctx;
        ctx.source = interaction.type == InteractionType.ApplicationCommand
            ? CommandSource.Slash
            : CommandSource.ContextMenu;
        ctx.rest = rest;
        ctx.services = services;
        ctx.cache = cache;
        ctx.state = state;
        ctx.invoker = interaction.user;
        ctx.currentChannel = channel;
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
        auto synced = rest.applicationCommands.bulkOverwrite(commands.applicationCommands).await();
        logger.information("client", "Synchronized " ~ synced.length.to!string ~ " application command(s) with Discord.");
        return synced;
    }

    /// Syncs commands only if the remote manifest differs from the generated one.
    ApplicationCommandDefinition[] syncCommandsIfChanged()
    {
        auto local = commands.applicationCommands;
        auto remoteResult = rest.applicationCommands.listGlobal().awaitResult();
        if (remoteResult.isErr)
            throw new DdiscordException(remoteResult.error);

        if (sameCommands(remoteResult.value, local))
        {
            logger.information("client", "Application commands are already in sync with Discord.");
            return remoteResult.value;
        }

        auto synced = rest.applicationCommands.bulkOverwrite(local).await();
        logger.information("client", "Updated the Discord command manifest with " ~ synced.length.to!string ~ " definition(s).");
        return synced;
    }

    /// Registers free command handlers.
    void registerCommands(handlers...)()
    {
        commands.registerAll!handlers(0);
    }

    /// Registers mixed command handlers, command groups, and plugin types.
    void registerAllCommands(symbols...)()
    {
        static foreach (symbol; symbols)
        {
            static if (isCallable!symbol)
            {
                registerCommands!symbol();
            }
            else static if (IsTypeSymbol!symbol)
            {
                registerCommandGroup!symbol();
                static if (HasLuaPluginAttr!symbol)
                    registerPlugin!symbol();
            }
            else
            {
                static assert(false, "registerAllCommands only accepts callable handlers or types.");
            }
        }
    }

    /// Registers a stateful command group.
    void registerCommandGroup(T)()
    {
        commands.register!T();
    }

    /// Registers a plugin descriptor type.
    void registerPlugin(T)()
    {
        plugins.register!T();
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

        if (_selfUser.id.value != 0 && message.author.id == _selfUser.id)
        {
            CommandExecution ignored;
            return Result!(CommandExecution, string).ok(ignored);
        }

        if (message.author.id.value != 0)
            cache.store(message.author);

        Channel channel;
        channel.id = message.channelId;
        cache.store(channel);
        cache.store(message);
        state.global.set("lastMessageContent", message.content);

        MessageCreateEvent event;
        event.message = message;
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
            if (isIgnorablePrefixFailure(parsed.error))
            {
                logger.debugMessage("commands", "Ignored prefix message `" ~ message.content ~ "` because no registered command matched.");
                CommandExecution ignored;
                ignored.replyCount = rest.messages.history.length;
                return Result!(CommandExecution, string).ok(ignored);
            }

            logger.error("commands", parsed.error);
            return Result!(CommandExecution, string).err(parsed.error);
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
        ctx.receiveLatencyMilliseconds = snowflakeLatencyMilliseconds(message.id);

        auto result = commands.executeParsedPrefix(ctx, parsed.value);
        auto durationMs = (MonoTime.currTime - startedAt).total!"msecs";
        if (result.isErr && shouldSurfacePrefixFailure(result.error))
            surfacePrefixFailure(ctx, descriptor.displayName, result.error);
        emitCommandOutcome(result, message, message.author);
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
        emit!InteractionCreateEvent(event);

        auto ctx = interactionContext(interaction, channel);
        ctx.permissions = permissions;
        ctx.receiveLatencyMilliseconds = snowflakeLatencyMilliseconds(interaction.id);

        string[string] options;
        foreach (option; interaction.options)
            options[option.name] = option.value;

        auto result = commands.executeSlash(ctx, interaction.commandName, options);
        auto durationMs = (MonoTime.currTime - startedAt).total!"msecs";

        Message sourceMessage;
        if (!interaction.targetMessage.isNull)
            sourceMessage = interaction.targetMessage.get;

        if (result.isErr)
            surfaceInteractionFailure(ctx, interaction.commandName, result.error);
        emitCommandOutcome(result, sourceMessage, interaction.user);
        logCommandOutcome("interaction", interaction.user, result, durationMs);
        return result;
    }

    /// Blocks until the live gateway thread finishes.
    void wait()
    {
        if (_gatewayThread !is null)
            _gatewayThread.join();
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
        _dispatchLoopRunning = false;
        _taskLoopRunning = false;
        plugins.deactivateAll();
        logger.information("client", "Stopping the Discord client.");
        signalDispatchLoop();
        if (_gateway !is null)
            _gateway.stop();
        if (_gatewayThread !is null)
        {
            _gatewayThread.join();
            _gatewayThread = null;
        }
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
            emit!CommandExecutedEvent(event);
        }
        else
        {
            CommandFailedEvent event;
            event.attemptedName = sourceMessage.content;
            event.sourceMessage = sourceMessage;
            event.user = user;
            event.error = result.error;
            emit!CommandFailedEvent(event);
        }
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

    private void startGateway(string url)
    {
        GatewayClientConfig gatewayConfig;
        gatewayConfig.token = config.token;
        gatewayConfig.intents = config.intents;
        gatewayConfig.url = url;
        gatewayConfig.pollTimeout = dur!"msecs"(250);

        _gateway = new GatewayClient(gatewayConfig);
        _gateway.onStatus = (string message) {
            logger.information("gateway", message);
        };
        _gateway.onReady = (GatewayReadyInfo ready) {
            tasks.cancel(GatewayReadyWatchdogLabel);
            if (ready.selfUser.id.value != 0)
                _selfUser = ready.selfUser;

            if (_selfUser.id.value != 0)
                cache.store(_selfUser);

            ReadyEvent event;
            event.selfUser = _selfUser;
            event.sessionId = ready.sessionId;
            emit!ReadyEvent(event);
            logger.information("gateway", "READY received for `" ~ _selfUser.username ~ "`.");
            _gateway.updatePresence(_status, _activity);
        };
        _gateway.onResumed = () {
            tasks.cancel(GatewayReadyWatchdogLabel);
            ResumedEvent event;
            emit!ResumedEvent(event);
            logger.information("gateway", "RESUMED received for `" ~ _selfUser.username ~ "`.");
            _gateway.updatePresence(_status, _activity);
        };
        _gateway.onMessageCreate = (Message message) {
            enqueueMessage(message);
        };
        _gateway.onInteractionCreate = (Interaction interaction) {
            if (
                (
                    interaction.type == InteractionType.ApplicationCommand ||
                    interaction.type == InteractionType.ApplicationCommandAutocomplete
                ) &&
                interaction.commandName.length != 0
            )
            {
                Channel channel;
                channel.id = interaction.channelId;
                enqueueInteraction(interaction, channel);
                return;
            }

            InteractionCreateEvent event;
            event.interaction = interaction;
            emit!InteractionCreateEvent(event);
        };
        _gateway.onError = (string message) {
            logger.error("gateway", message);
            CommandFailedEvent event;
            event.attemptedName = "[gateway]";
            event.error = message;
            event.user = _selfUser;
            emit!CommandFailedEvent(event);
        };

        tasks.cancel(GatewayReadyWatchdogLabel);
        tasks.schedule(GatewayReadyWatchdogLabel, dur!"seconds"(20), {
            if (_gateway !is null && !_gateway.isReady)
            {
                logger.warning(
                    "gateway",
                    "The gateway session is still waiting for READY or RESUMED 20 seconds after startup. Check intents, token validity, network reachability, and whether Discord is accepting the IDENTIFY payload."
                );
            }
        });

        _gatewayThread = new Thread({
            _gateway.run();
            _running = false;
            _dispatchLoopRunning = false;
            _taskLoopRunning = false;
            signalDispatchLoop();
            plugins.deactivateAll();
            logger.warning("gateway", "Gateway loop exited.");
        });
        _gatewayThread.start();
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
                    compactDispatchQueue();
                    hasItem = true;
                }

                if (!hasItem)
                    continue;

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
            _dispatchQueue ~= item;
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
            _dispatchQueue ~= item;
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

    private void compactDispatchQueue()
    {
        if (_dispatchQueueHead == 0)
            return;

        if (_dispatchQueueHead >= _dispatchQueue.length)
        {
            _dispatchQueue.length = 0;
            _dispatchQueueHead = 0;
            return;
        }

        if (_dispatchQueueHead >= 64 && _dispatchQueueHead * 2 >= _dispatchQueue.length)
        {
            _dispatchQueue = _dispatchQueue[_dispatchQueueHead .. $].dup;
            _dispatchQueueHead = 0;
        }
    }

    private void startTaskLoop()
    {
        if (_taskThread !is null)
            return;

        _taskLoopRunning = true;
        _taskThread = new Thread({
            while (_taskLoopRunning)
            {
                tasks.runDue();
                Thread.sleep(dur!"msecs"(250));
            }
        });
        _taskThread.start();
    }

    private void surfacePrefixFailure(CommandContext ctx, string commandName, string error)
    {
        if (ctx.channel.id.value == 0)
            return;

        auto payload = MessageCreate("Could not run `" ~ commandName ~ "`.\n" ~ error);
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
        auto content = "Could not run `" ~ commandName ~ "`.\n" ~ error;

        if (ctx.interaction.isNull || ctx.interaction.get.token.length == 0)
            return;

        auto task = (ctx.interactionAcknowledged || ctx.interactionResponded)
            ? ctx.followup(content, true)
            : ctx.reply(content, true);
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

    private bool isIgnorablePrefixFailure(string error)
    {
        return error.canFind("requested prefix command is not registered") ||
            error.canFind("No command name was provided after the prefix");
    }

    private bool shouldSurfacePrefixFailure(string error)
    {
        if (error.canFind("restricted to the configured bot owner"))
            return false;
        if (error.canFind("permission requirements"))
            return false;
        if (error.canFind("temporarily rate limited"))
            return false;
        return true;
    }

    private long snowflakeLatencyMilliseconds(Snowflake id)
    {
        if (id.value == 0)
            return 0;

        enum unixEpochStdTime = 621355968000000000L;
        auto nowMs = cast(long) ((Clock.currTime.stdTime - unixEpochStdTime) / 10_000);
        auto createdMs = cast(long) id.timestampMilliseconds;
        if (nowMs <= createdMs)
            return 0;
        return nowMs - createdMs;
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
    ctx.reply("pong").await();
}

@RequirePermissions(Permissions.SendMessages)
private @Command("secure-ping", routes: CommandRoute.Prefix)
void clientUnittestSecurePing(CommandContext ctx)
{
    ctx.reply("allowed").await();
}

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
    struct OwnerGroup
    {
        @RequireOwner
        @Command("owner-only", routes: CommandRoute.Prefix)
        void run(CommandContext ctx)
        {
            ctx.reply("should not send").await();
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
            ctx.reply("ok").await();
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
