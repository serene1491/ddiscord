/**
 * ddiscord — client façade.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client;

import core.thread : Thread;
import core.time : dur;
import ddiscord.cache : CacheStore;
import ddiscord.commands : Command, CommandExecution, CommandExecutionSettings, CommandRegistry,
    CommandRoute, ParsedCommand;
import ddiscord.context.command : CommandContext, CommandSource;
import ddiscord.events.dispatcher : EventDispatcher;
import ddiscord.events.types : CommandExecutedEvent, CommandFailedEvent, InteractionCreateEvent,
    MessageCreateEvent, PresenceUpdateEvent, ReadyEvent;
import ddiscord.gateway.client : GatewayClient, GatewayClientConfig, GatewayReadyInfo;
import ddiscord.gateway.intents : GatewayIntent;
import ddiscord.models.application_command : ApplicationCommandDefinition;
import ddiscord.models.application_command : InteractionType;
import ddiscord.models.channel : Channel;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.user : User;
import ddiscord.plugins : PluginRegistry;
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
import std.algorithm : canFind;
import std.string : startsWith;

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
    UptimeSample uptime;
    private bool _running;
    private StatusType _status = StatusType.Online;
    private Activity _activity;
    private User _selfUser;
    private Nullable!GatewayBotInfo _gatewayInfo;
    private GatewayClient _gateway;
    private Thread _gatewayThread;
    private Thread _taskThread;
    private bool _taskLoopRunning;

    this(ClientConfig config)
    {
        this.config = config;
        services = new ServiceContainer;
        commands = new CommandRegistry(services);
        events = new EventDispatcher;
        plugins = new PluginRegistry;
        tasks = new TaskScheduler;
        RestClientConfig restConfig;
        restConfig.token = config.token;
        restConfig.applicationId = config.applicationId;
        if (!config.transport.isNull)
            restConfig.transport = config.transport;
        rest = new RestClient(restConfig);
        cache = new CacheStore;
        state = new StateStore;

        services.add!ServiceContainer(services);
        services.add!CommandRegistry(commands);
        services.add!EventDispatcher(events);
        services.add!PluginRegistry(plugins);
        services.add!TaskScheduler(tasks);
        services.add!RestClient(rest);
        services.add!CacheStore(cache);
        services.add!StateStore(state);
        services.add!ScriptingEngine(new ScriptingEngine);
        services.add!CommandExecutionSettings(CommandExecutionSettings(config.ownerId));
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

        _running = true;
        _selfUser = me.value;
        _gatewayInfo = Nullable!GatewayBotInfo.of(gateway.value);
        plugins.loadAll(config.pluginsDir);
        plugins.activateAll(services.get!ScriptingEngine(), state);
        if (config.autoSyncCommands)
            syncCommandsIfChanged();

        cache.store(_selfUser);
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
        auto ctx = prefixContext(content, invoker, channel);
        ctx.permissions = permissions;
        return commands.executePrefix(ctx, config.prefix, content);
    }

    /// Syncs slash and context-menu definitions to Discord REST.
    ApplicationCommandDefinition[] syncCommands()
    {
        return rest.applicationCommands.bulkOverwrite(commands.applicationCommands).await();
    }

    /// Syncs commands only if the remote manifest differs from the generated one.
    ApplicationCommandDefinition[] syncCommandsIfChanged()
    {
        auto local = commands.applicationCommands;
        auto remoteResult = rest.applicationCommands.listGlobal().awaitResult();
        if (remoteResult.isErr)
            throw new DdiscordException(remoteResult.error);

        if (sameCommands(remoteResult.value, local))
            return remoteResult.value;

        return rest.applicationCommands.bulkOverwrite(local).await();
    }

    /// Registers free command handlers.
    void registerCommands(handlers...)()
    {
        commands.registerAll!handlers(0);
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

        auto ctx = prefixContext(message.content, message.author, channel);
        ctx.permissions = permissions;
        ctx.message = Nullable!Message.of(message);

        auto result = commands.executePrefix(ctx, config.prefix, message.content);
        emitCommandOutcome(result, message, message.author);
        return result;
    }

    /// Ingests an interaction and dispatches it to the command registry.
    Result!(CommandExecution, string) receiveInteraction(
        Interaction interaction,
        Channel channel = Channel.init,
        ulong permissions = 0
    )
    {
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

        string[string] options;
        foreach (option; interaction.options)
            options[option.name] = option.value;

        auto result = commands.executeSlash(ctx, interaction.commandName, options);

        Message sourceMessage;
        if (!interaction.targetMessage.isNull)
            sourceMessage = interaction.targetMessage.get;

        emitCommandOutcome(result, sourceMessage, interaction.user);
        return result;
    }

    /// Blocks until the live gateway thread finishes.
    void wait()
    {
        if (_gatewayThread !is null)
            _gatewayThread.join();
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
        _taskLoopRunning = false;
        plugins.deactivateAll();
        if (_gateway !is null)
            _gateway.stop();
        if (_gatewayThread !is null)
        {
            _gatewayThread.join();
            _gatewayThread = null;
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

        foreach (index, definition; left)
        {
            if (definition.toJSON.toString != right[index].toJSON.toString)
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

        _gateway = new GatewayClient(gatewayConfig);
        _gateway.onReady = (GatewayReadyInfo ready) {
            if (ready.selfUser.id.value != 0)
                _selfUser = ready.selfUser;

            if (_selfUser.id.value != 0)
                cache.store(_selfUser);

            ReadyEvent event;
            event.selfUser = _selfUser;
            event.sessionId = ready.sessionId;
            emit!ReadyEvent(event);
            _gateway.updatePresence(_status, _activity);
        };
        _gateway.onMessageCreate = (Message message) {
            auto _ = receiveMessage(message);
        };
        _gateway.onInteractionCreate = (Interaction interaction) {
            if (
                interaction.type == InteractionType.ApplicationCommand &&
                interaction.commandName.length != 0
            )
            {
                Channel channel;
                channel.id = interaction.channelId;
                auto _ = receiveInteraction(interaction, channel);
                return;
            }

            InteractionCreateEvent event;
            event.interaction = interaction;
            emit!InteractionCreateEvent(event);
        };
        _gateway.onError = (string message) {
            CommandFailedEvent event;
            event.attemptedName = "[gateway]";
            event.error = message;
            event.user = _selfUser;
            emit!CommandFailedEvent(event);
        };

        _gatewayThread = new Thread({
            _gateway.run();
            _running = false;
            _taskLoopRunning = false;
            plugins.deactivateAll();
        });
        _gatewayThread.start();
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
}

private @Command("ping", routes: CommandRoute.Prefix)
void clientUnittestPing(CommandContext ctx)
{
    ctx.reply("pong").await();
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
