/**
 * ddiscord — live Discord gateway client.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.gateway.client;

import aurora_websocket.client : WebSocketClient, parseWebSocketUrl;
import aurora_websocket.connection : ConnectionMode, WebSocketClosedException, WebSocketConfig,
    WebSocketConnection;
import aurora_websocket.message : MessageType;
import aurora_websocket.stream : IWebSocketStream, WebSocketStreamException;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;
import ddiscord.logging : ILogger, LogLevel;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild, UnavailableGuild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, ActivityType, StatusType, statusFromDiscord;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.limits : DiscordGatewayVersion;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import requests.streams : ConnectError, NetworkStream, SSLSocketStream,
    SSLOptions, TCPSocketStream, TimeoutException;
import std.algorithm : canFind, filter;
import std.array : array;
import std.conv : ConvException, to;
import std.json : JSONType, JSONValue, parseJSON;
import std.random : uniform;
import std.string : endsWith, startsWith;
import std.variant : Variant;

/// Gateway opcode values used by Discord.
enum GatewayOpcode : int
{
    Dispatch = 0,
    Heartbeat = 1,
    Identify = 2,
    PresenceUpdate = 3,
    Resume = 6,
    Reconnect = 7,
    InvalidSession = 9,
    Hello = 10,
    HeartbeatAck = 11,
}

/// Runtime configuration for the gateway client.
struct GatewayClientConfig
{
    string token;
    uint intents;
    string url;
    uint shardId;
    uint shardCount = 1;
    ILogger logger;
    Duration connectTimeout = dur!"seconds"(15);
    Duration pollTimeout = dur!"msecs"(250);
    Duration reconnectDelay = dur!"seconds"(2);
    Duration maxReconnectDelay = dur!"seconds"(30);
    bool autoReconnect = true;
    bool logUnhandledDispatchEvents = false;
    size_t unhandledDispatchLogEvery = 100;
}

/// READY payload values surfaced to the high-level client.
struct GatewayReadyInfo
{
    uint gatewayVersion;
    User selfUser;
    UnavailableGuild[] guilds;
    string sessionId;
    string resumeGatewayUrl;
}

/// Typed payload for `RESUMED`.
struct GatewayResumedInfo
{
}

/// Typed payload for `GUILD_MEMBER_ADD`.
struct GatewayGuildMemberAddInfo
{
    GuildMember member;
    Nullable!Snowflake guildId;
    size_t memberCount;
}

/// Typed payload for `PRESENCE_UPDATE`.
struct GatewayPresenceUpdateInfo
{
    Nullable!Snowflake guildId;
    User user;
    Nullable!GuildMember member;
    StatusType status = StatusType.Offline;
    Activity activity;
}

/// Typed payload for `MESSAGE_DELETE`.
struct GatewayMessageDeleteInfo
{
    Snowflake messageId;
    Nullable!Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Typed payload for `MESSAGE_CREATE`.
struct GatewayMessageCreateEvent
{
    Message message;
}

/// Typed payload for `MESSAGE_UPDATE`.
struct GatewayMessageUpdateEvent
{
    Message message;
}

/// Typed payload for `GUILD_MEMBER_REMOVE`.
struct GatewayGuildMemberRemoveInfo
{
    User user;
    Nullable!Snowflake guildId;
}

/// Typed payload for `GUILD_BAN_ADD` and `GUILD_BAN_REMOVE`.
struct GatewayGuildBanInfo
{
    Snowflake guildId;
    User user;
}

/// Typed payload for `TYPING_START`.
struct GatewayTypingStartInfo
{
    Snowflake channelId;
    Nullable!Snowflake guildId;
    Snowflake userId;
    long timestampUnix;
}

/// Typed payload for `CHANNEL_PINS_UPDATE`.
struct GatewayChannelPinsUpdateInfo
{
    Snowflake channelId;
    Nullable!Snowflake guildId;
    string lastPinTimestamp;
}

/// Typed payload for reaction gateway events.
struct GatewayMessageReactionInfo
{
    Snowflake userId;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
}

/// Typed payload for `MESSAGE_REACTION_REMOVE_ALL`.
struct GatewayMessageReactionRemoveAllInfo
{
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
}

/// Typed payload for guild role create/update gateway events.
struct GatewayGuildRoleInfo
{
    Snowflake guildId;
    Role role;
}

/// Typed payload for `GUILD_ROLE_DELETE`.
struct GatewayGuildRoleDeleteInfo
{
    Snowflake guildId;
    Snowflake roleId;
}

/// Typed payload for invite create/delete gateway events.
struct GatewayInviteInfo
{
    string code;
    Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Typed payload for `WEBHOOKS_UPDATE`.
struct GatewayWebhooksUpdateInfo
{
    Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Typed payload for `THREAD_DELETE`.
struct GatewayThreadDeleteInfo
{
    Snowflake threadId;
    Nullable!Snowflake guildId;
    Nullable!Snowflake parentId;
}

/// Typed payload for `CHANNEL_CREATE`.
struct GatewayChannelCreateEvent
{
    Channel channel;
}

/// Typed payload for `CHANNEL_UPDATE`.
struct GatewayChannelUpdateEvent
{
    Channel channel;
}

/// Typed payload for `CHANNEL_DELETE`.
struct GatewayChannelDeleteEvent
{
    Channel channel;
}

/// Typed payload for `THREAD_CREATE`.
struct GatewayThreadCreateEvent
{
    Channel thread;
}

/// Typed payload for `THREAD_UPDATE`.
struct GatewayThreadUpdateEvent
{
    Channel thread;
}

private struct GatewayEnvelope
{
    GatewayOpcode opcode;
    Nullable!long sequence;
    string eventName;
    JSONValue data;
}

private enum GatewaySessionMode
{
    Identify,
    Resume,
}

private enum GatewayCloseCode : int
{
    NormalClosure = 1000,
    GoingAway = 1001,
    AuthenticationFailed = 4004,
    InvalidSeq = 4007,
    SessionTimedOut = 4009,
    InvalidShard = 4010,
    ShardingRequired = 4011,
    InvalidApiVersion = 4012,
    InvalidIntents = 4013,
    DisallowedIntents = 4014,
}

private final class RequestsWebSocketStreamAdapter : IWebSocketStream
{
    private NetworkStream _stream;
    private bool _closed;

    this(NetworkStream stream)
    {
        _stream = stream;
        _closed = stream is null;
    }

    override ubyte[] read(ubyte[] buffer) @trusted
    {
        enforceOpen();

            try
            {
                auto received = _stream.receive(buffer);
                if (received <= 0)
                {
                    _closed = true;
                    return [];
                }
                return buffer[0 .. received];
            }
        catch (TimeoutException)
        {
            return [];
        }
        catch (Exception e)
        {
            throw streamError("read from the Discord gateway", e.msg);
        }
    }

    override ubyte[] readExactly(size_t n) @trusted
    {
        enforceOpen();
        if (n == 0)
            return [];

        auto buffer = new ubyte[](n);
        size_t offset;

        while (offset < n)
        {
            try
            {
                auto received = _stream.receive(buffer[offset .. $]);
                if (received <= 0)
                {
                    _closed = true;
                    throw streamError("read from the Discord gateway", "The socket closed before the requested payload was fully received.");
                }
                offset += cast(size_t) received;
            }
            catch (TimeoutException)
            {
                throw streamError("read from the Discord gateway", "Timed out while waiting for the next WebSocket frame from Discord.");
            }
            catch (WebSocketStreamException e)
            {
                throw e;
            }
            catch (Exception e)
            {
                throw streamError("read from the Discord gateway", e.msg);
            }
        }

        return buffer;
    }

    override void write(const(ubyte)[] data) @trusted
    {
        enforceOpen();

        size_t offset;
        while (offset < data.length)
        {
            try
            {
                auto sent = _stream.send(data[offset .. $]);
                if (sent <= 0)
                {
                    _closed = true;
                    throw streamError("write to the Discord gateway", "The socket closed before the frame was sent.");
                }
                offset += cast(size_t) sent;
            }
            catch (Exception e)
            {
                throw streamError("write to the Discord gateway", e.msg);
            }
        }
    }

    override void flush() @trusted
    {
    }

    override @property bool connected() @trusted nothrow
    {
        return _stream !is null && !_closed;
    }

    override void close() @trusted
    {
        _closed = true;
        if (_stream !is null)
            _stream.close();
    }

    private void enforceOpen() @trusted
    {
        if (!connected)
            throw streamError("use the Discord gateway", "The WebSocket stream is not connected.");
    }

    private WebSocketStreamException streamError(string action, string detail) @trusted
    {
        return new WebSocketStreamException(formatError(
            "gateway",
            "The Discord gateway stream failed while trying to " ~ action ~ ".",
            detail,
            "Check the network connection or allow the client to reconnect."
        ));
    }
}

/// Blocking Discord gateway session manager.
final class GatewayClient
{
    private struct DispatchSubscription(E)
    {
        bool once;
        void delegate(E) handler;
    }

    private alias DispatchHandler = void delegate(JSONValue);

    GatewayClientConfig config;
    void delegate(GatewayReadyInfo) onReady;
    void delegate() onResumed;
    void delegate(Guild) onGuildCreate;
    void delegate(UnavailableGuild) onGuildDelete;
    void delegate(GatewayGuildMemberRemoveInfo) onGuildMemberRemove;
    void delegate(GatewayGuildBanInfo) onGuildBanAdd;
    void delegate(GatewayGuildBanInfo) onGuildBanRemove;
    void delegate(string) onStatus;
    void delegate(Channel) onChannelCreate;
    void delegate(Channel) onChannelUpdate;
    void delegate(Channel) onChannelDelete;
    void delegate(GatewayChannelPinsUpdateInfo) onChannelPinsUpdate;
    void delegate(Message) onMessageCreate;
    void delegate(Message) onMessageUpdate;
    void delegate(GatewayMessageDeleteInfo) onMessageDelete;
    void delegate(GatewayMessageReactionInfo) onMessageReactionAdd;
    void delegate(GatewayMessageReactionInfo) onMessageReactionRemove;
    void delegate(GatewayMessageReactionRemoveAllInfo) onMessageReactionRemoveAll;
    void delegate(GatewayMessageReactionInfo) onMessageReactionRemoveEmoji;
    void delegate(GatewayTypingStartInfo) onTypingStart;
    void delegate(GatewayGuildRoleInfo) onGuildRoleCreate;
    void delegate(GatewayGuildRoleInfo) onGuildRoleUpdate;
    void delegate(GatewayGuildRoleDeleteInfo) onGuildRoleDelete;
    void delegate(GatewayInviteInfo) onInviteCreate;
    void delegate(GatewayInviteInfo) onInviteDelete;
    void delegate(GatewayWebhooksUpdateInfo) onWebhooksUpdate;
    void delegate(Channel) onThreadCreate;
    void delegate(Channel) onThreadUpdate;
    void delegate(GatewayThreadDeleteInfo) onThreadDelete;
    void delegate(Interaction) onInteractionCreate;
    void delegate(GatewayGuildMemberAddInfo) onGuildMemberAdd;
    void delegate(GatewayPresenceUpdateInfo) onPresenceUpdate;
    void delegate(string) onError;

    private bool _running;
    private bool _stopRequested;
    private bool _ready;
    private Nullable!long _sequence;
    private string _sessionId;
    private string _resumeGatewayUrl;
    private string _lastError;
    private GatewaySessionMode _nextSessionMode = GatewaySessionMode.Identify;
    private bool _fatalShutdownRequested;
    private Mutex _sendMutex;
    private Mutex _heartbeatMutex;
    private Thread _heartbeatThread;
    private bool _heartbeatLoopRunning;
    private bool _awaitingHeartbeatAck;
    private RequestsWebSocketStreamAdapter _stream;
    private WebSocketConnection _socket;
    private Mutex _dispatchSubscriptionsMutex;
    private Variant[string] _dispatchSubscriptions;
    private DispatchHandler[string] _dispatchHandlers;
    private size_t[string] _unhandledDispatchEventCounts;

    this(GatewayClientConfig config)
    {
        this.config = config;
        _sendMutex = new Mutex;
        _heartbeatMutex = new Mutex;
        _dispatchSubscriptionsMutex = new Mutex;
        registerDispatchHandlers();
    }

    /// Registers a typed dispatch listener.
    /// Listeners are keyed by payload type; if multiple Discord dispatch names
    /// map to the same payload type, all mapped events will invoke this listener.
    void on(E)(void delegate(E) handler)
    {
        auto key = typeid(E).toString;
        synchronized (_dispatchSubscriptionsMutex)
        {
            auto handlers = subscriptionEntries!E(key);
            handlers ~= DispatchSubscription!E(false, handler);
            _dispatchSubscriptions[key] = Variant(handlers);
        }
    }

    /// Registers a one-shot typed dispatch listener.
    /// One-shot listeners follow the same payload-type routing semantics as `on`.
    void once(E)(void delegate(E) handler)
    {
        auto key = typeid(E).toString;
        synchronized (_dispatchSubscriptionsMutex)
        {
            auto handlers = subscriptionEntries!E(key);
            handlers ~= DispatchSubscription!E(true, handler);
            _dispatchSubscriptions[key] = Variant(handlers);
        }
    }

    /// Removes a typed dispatch listener.
    void off(E)(void delegate(E) handler)
    {
        auto key = typeid(E).toString;
        synchronized (_dispatchSubscriptionsMutex)
        {
            auto handlers = subscriptionEntries!E(key);
            handlers = handlers.filter!(entry => entry.handler != handler).array;
            _dispatchSubscriptions[key] = Variant(handlers);
        }
    }

    /// Runs the gateway loop until stopped or a fatal error occurs.
    void run()
    {
        _running = true;
        _fatalShutdownRequested = false;
        auto reconnectDelay = config.reconnectDelay;

        while (!_stopRequested && !_fatalShutdownRequested)
        {
            try
            {
                connectAndRun();
                reconnectDelay = config.reconnectDelay;

                if (_stopRequested || _fatalShutdownRequested || !config.autoReconnect)
                    break;
            }
            catch (Exception error)
            {
                _lastError = formatError(
                    "gateway",
                    "The Discord gateway session ended unexpectedly.",
                    error.msg,
                    "The client will reconnect automatically unless `autoReconnect` is disabled."
                );

                reportError(_lastError);

                if (_stopRequested || _fatalShutdownRequested || !config.autoReconnect)
                    break;
            }

            if (!_stopRequested)
            {
                Thread.sleep(reconnectDelay);
                reconnectDelay = minDuration(reconnectDelay + reconnectDelay, config.maxReconnectDelay);
            }
        }

        close(_stopRequested);
        _running = false;
    }

    /// Requests a graceful shutdown of the current session.
    void stop()
    {
        _stopRequested = true;
        stopHeartbeatLoop();
        abortCurrentConnection();
    }

    /// Returns whether the gateway loop is active.
    bool isRunning() const @property
    {
        return _running;
    }

    /// Returns whether a READY or RESUMED event has been observed.
    bool isReady() const @property
    {
        return _ready;
    }

    /// Returns the last gateway error recorded by the loop.
    string lastError() const @property
    {
        return _lastError;
    }

    /// Sends a presence update over the live gateway session.
    void updatePresence(StatusType status, Activity activity)
    {
        if (_socket is null || !_socket.connected)
            return;

        JSONValue data;
        data["since"] = JSONValue.init;
        data["status"] = cast(string) status;
        data["afk"] = false;

        JSONValue[] activities;
        if (activity.name.length != 0)
        {
            JSONValue activityJson;
            activityJson["name"] = activity.name;
            activityJson["type"] = cast(int) activity.type;
            activities ~= activityJson;
        }
        data["activities"] = activities;

        sendPayload(GatewayOpcode.PresenceUpdate, data);
    }

    private void connectAndRun()
    {
        _ready = false;
        scope(exit)
        {
            stopHeartbeatLoop();
            close(_stopRequested || _fatalShutdownRequested);
        }

        auto url = normalizedGatewayUrl(activeGatewayUrl());
        auto parsed = parseWebSocketUrl(url);
        if (!parsed.valid)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "The Discord gateway URL was invalid.",
                parsed.error,
                "Use the `url` field returned by `GET /gateway/bot`."
            ));
        }

        auto networkStream = openNetworkStream(parsed.host, parsed.port, parsed.isSecure);
        networkStream.readTimeout = config.connectTimeout;
        reportStatus("Opened the Discord gateway TCP/TLS connection to `" ~ parsed.host ~ "`.");

        _stream = new RequestsWebSocketStreamAdapter(networkStream);

        WebSocketConfig wsConfig;
        wsConfig.mode = ConnectionMode.client;
        wsConfig.maxFrameSize = 8 * 1024 * 1024;
        wsConfig.maxMessageSize = 8 * 1024 * 1024;
        _socket = WebSocketClient.connect(_stream, url, wsConfig);
        networkStream.readTimeout = Duration.init;

        auto hello = receiveEnvelope();
        if (hello.opcode != GatewayOpcode.Hello)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "Discord did not begin the session with a HELLO payload.",
                "Received opcode `" ~ (cast(int) hello.opcode).to!string ~ "` instead.",
                "Reconnect and verify that the URL came from `GET /gateway/bot`."
            ));
        }

        auto heartbeatInterval = parseHeartbeatInterval(hello.data);
        reportStatus("Received HELLO from Discord with heartbeat interval `" ~ heartbeatInterval.total!"msecs".to!string ~ "ms`.");
        startHeartbeatLoop(firstHeartbeatDelay(heartbeatInterval), heartbeatInterval);
        if (_nextSessionMode == GatewaySessionMode.Resume && canResumeSession())
            sendResume();
        else
            sendIdentify();

        while (!_stopRequested && _socket !is null)
        {
            try
            {
                auto envelope = receiveEnvelope();
                if (!envelope.sequence.isNull)
                    _sequence = envelope.sequence;

                final switch (envelope.opcode)
                {
                    case GatewayOpcode.Dispatch:
                        handleDispatch(envelope);
                        break;

                    case GatewayOpcode.Heartbeat:
                        sendHeartbeat();
                        break;

                    case GatewayOpcode.HeartbeatAck:
                        synchronized (_heartbeatMutex)
                            _awaitingHeartbeatAck = false;
                        break;

                    case GatewayOpcode.PresenceUpdate:
                        break;

                    case GatewayOpcode.Reconnect:
                        _nextSessionMode = GatewaySessionMode.Resume;
                        throw new DdiscordException(formatError(
                            "gateway",
                            "Discord requested a gateway reconnect.",
                            "",
                            "The client will reopen the session automatically."
                        ));

                    case GatewayOpcode.InvalidSession:
                        auto resumable = parseInvalidSessionFlag(envelope.data);
                        if (resumable && canResumeSession())
                            _nextSessionMode = GatewaySessionMode.Resume;
                        else
                        {
                            clearSession();
                            _nextSessionMode = GatewaySessionMode.Identify;
                        }
                        Thread.sleep(invalidSessionReconnectDelay());
                        throw new DdiscordException(formatError(
                            "gateway",
                            "Discord invalidated the current gateway session.",
                            resumable
                                ? "Discord indicated that the session may still be resumable."
                                : "Discord indicated that a fresh IDENTIFY is required.",
                            "The client will reconnect automatically."
                        ));

                    case GatewayOpcode.Hello:
                    case GatewayOpcode.Identify:
                    case GatewayOpcode.Resume:
                        break;
                }
            }
            catch (WebSocketClosedException error)
            {
                auto closeCode = cast(int) error.code;
                if (isFatalCloseCode(closeCode))
                {
                    clearSession();
                    _fatalShutdownRequested = true;
                }
                else if (requiresFreshIdentify(closeCode))
                {
                    clearSession();
                    _nextSessionMode = GatewaySessionMode.Identify;
                }
                else if (canResumeSession())
                {
                    _nextSessionMode = GatewaySessionMode.Resume;
                }
                else
                {
                    _nextSessionMode = GatewaySessionMode.Identify;
                }

                throw new DdiscordException(formatError(
                    "gateway",
                    "The Discord gateway connection closed.",
                    "Code `" ~ (cast(int) error.code).to!string ~ "` reason `" ~ error.reason ~ "`.",
                    fatalCloseHint(closeCode)
                ));
            }
            catch (WebSocketStreamException error)
            {
                if (isTimeoutError(error))
                    continue;
                if (canResumeSession())
                    _nextSessionMode = GatewaySessionMode.Resume;
                throw new DdiscordException(error.msg);
            }
        }
    }

    private void registerDispatchHandlers()
    {
        _dispatchHandlers["READY"] = (JSONValue data) {
            handleReadyDispatch(data);
        };
        _dispatchHandlers["RESUMED"] = (JSONValue data) {
            handleResumedDispatch(data);
        };

        _dispatchHandlers["GUILD_CREATE"] = (JSONValue data) {
            invokeFromJSON!Guild(data, onGuildCreate);
        };
        _dispatchHandlers["GUILD_DELETE"] = (JSONValue data) {
            invokeFromJSON!UnavailableGuild(data, onGuildDelete);
        };
        _dispatchHandlers["GUILD_MEMBER_REMOVE"] = (JSONValue data) {
            invokeParsed!(GatewayGuildMemberRemoveInfo, parseGuildMemberRemove)(data, onGuildMemberRemove);
        };
        _dispatchHandlers["GUILD_BAN_ADD"] = (JSONValue data) {
            invokeParsed!(GatewayGuildBanInfo, parseGuildBan)(data, onGuildBanAdd);
        };
        _dispatchHandlers["GUILD_BAN_REMOVE"] = (JSONValue data) {
            invokeParsed!(GatewayGuildBanInfo, parseGuildBan)(data, onGuildBanRemove);
        };

        _dispatchHandlers["CHANNEL_CREATE"] = (JSONValue data) {
            handleChannelCreateDispatch(data);
        };
        _dispatchHandlers["CHANNEL_UPDATE"] = (JSONValue data) {
            handleChannelUpdateDispatch(data);
        };
        _dispatchHandlers["CHANNEL_DELETE"] = (JSONValue data) {
            handleChannelDeleteDispatch(data);
        };
        _dispatchHandlers["CHANNEL_PINS_UPDATE"] = (JSONValue data) {
            invokeParsed!(GatewayChannelPinsUpdateInfo, parseChannelPinsUpdate)(data, onChannelPinsUpdate);
        };

        _dispatchHandlers["MESSAGE_CREATE"] = (JSONValue data) {
            handleMessageCreateDispatch(data);
        };
        _dispatchHandlers["MESSAGE_UPDATE"] = (JSONValue data) {
            handleMessageUpdateDispatch(data);
        };
        _dispatchHandlers["MESSAGE_DELETE"] = (JSONValue data) {
            invokeParsed!(GatewayMessageDeleteInfo, parseMessageDelete)(data, onMessageDelete);
        };
        _dispatchHandlers["MESSAGE_REACTION_ADD"] = (JSONValue data) {
            invokeParsed!(GatewayMessageReactionInfo, parseMessageReaction)(data, onMessageReactionAdd);
        };
        _dispatchHandlers["MESSAGE_REACTION_REMOVE"] = (JSONValue data) {
            invokeParsed!(GatewayMessageReactionInfo, parseMessageReaction)(data, onMessageReactionRemove);
        };
        _dispatchHandlers["MESSAGE_REACTION_REMOVE_ALL"] = (JSONValue data) {
            invokeParsed!(GatewayMessageReactionRemoveAllInfo, parseMessageReactionRemoveAll)(data, onMessageReactionRemoveAll);
        };
        _dispatchHandlers["MESSAGE_REACTION_REMOVE_EMOJI"] = (JSONValue data) {
            invokeParsed!(GatewayMessageReactionInfo, parseMessageReaction)(data, onMessageReactionRemoveEmoji);
        };

        _dispatchHandlers["TYPING_START"] = (JSONValue data) {
            invokeParsed!(GatewayTypingStartInfo, parseTypingStart)(data, onTypingStart);
        };

        _dispatchHandlers["GUILD_ROLE_CREATE"] = (JSONValue data) {
            invokeParsed!(GatewayGuildRoleInfo, parseGuildRole)(data, onGuildRoleCreate);
        };
        _dispatchHandlers["GUILD_ROLE_UPDATE"] = (JSONValue data) {
            invokeParsed!(GatewayGuildRoleInfo, parseGuildRole)(data, onGuildRoleUpdate);
        };
        _dispatchHandlers["GUILD_ROLE_DELETE"] = (JSONValue data) {
            invokeParsed!(GatewayGuildRoleDeleteInfo, parseGuildRoleDelete)(data, onGuildRoleDelete);
        };

        _dispatchHandlers["INVITE_CREATE"] = (JSONValue data) {
            invokeParsed!(GatewayInviteInfo, parseInvite)(data, onInviteCreate);
        };
        _dispatchHandlers["INVITE_DELETE"] = (JSONValue data) {
            invokeParsed!(GatewayInviteInfo, parseInvite)(data, onInviteDelete);
        };
        _dispatchHandlers["WEBHOOKS_UPDATE"] = (JSONValue data) {
            invokeParsed!(GatewayWebhooksUpdateInfo, parseWebhooksUpdate)(data, onWebhooksUpdate);
        };

        _dispatchHandlers["THREAD_CREATE"] = (JSONValue data) {
            handleThreadCreateDispatch(data);
        };
        _dispatchHandlers["THREAD_UPDATE"] = (JSONValue data) {
            handleThreadUpdateDispatch(data);
        };
        _dispatchHandlers["THREAD_DELETE"] = (JSONValue data) {
            invokeParsed!(GatewayThreadDeleteInfo, parseThreadDelete)(data, onThreadDelete);
        };

        _dispatchHandlers["INTERACTION_CREATE"] = (JSONValue data) {
            invokeFromJSON!Interaction(data, onInteractionCreate);
        };
        _dispatchHandlers["GUILD_MEMBER_ADD"] = (JSONValue data) {
            invokeParsed!(GatewayGuildMemberAddInfo, parseGuildMemberAdd)(data, onGuildMemberAdd);
        };
        _dispatchHandlers["PRESENCE_UPDATE"] = (JSONValue data) {
            invokeParsed!(GatewayPresenceUpdateInfo, parsePresenceUpdate)(data, onPresenceUpdate);
        };
    }

    private void handleReadyDispatch(JSONValue data)
    {
        auto sessionIdValue = data.object.get("session_id", JSONValue.init);
        if (sessionIdValue.type != JSONType.null_)
            _sessionId = sessionIdValue.str;

        auto resumeUrlValue = data.object.get("resume_gateway_url", JSONValue.init);
        if (resumeUrlValue.type != JSONType.null_)
            _resumeGatewayUrl = resumeUrlValue.str;

        GatewayReadyInfo info;
        auto versionValue = data.object.get("v", JSONValue.init);
        if (versionValue.type != JSONType.null_)
            info.gatewayVersion = cast(uint) versionValue.integer;

        auto userValue = data.object.get("user", JSONValue.init);
        if (userValue.type != JSONType.null_)
            info.selfUser = User.fromJSON(userValue);

        auto guildsValue = data.object.get("guilds", JSONValue.init);
        if (guildsValue.type == JSONType.array)
        {
            foreach (item; guildsValue.array)
                info.guilds ~= UnavailableGuild.fromJSON(item);
        }

        info.sessionId = _sessionId;
        info.resumeGatewayUrl = _resumeGatewayUrl;
        _ready = true;
        _nextSessionMode = GatewaySessionMode.Resume;

        if (onReady !is null)
            onReady(info);

        emitDispatch!GatewayReadyInfo(info);
    }

    private void handleResumedDispatch(JSONValue data)
    {
        auto _ = data;
        _ready = true;
        _nextSessionMode = GatewaySessionMode.Resume;
        if (onResumed !is null)
            onResumed();

        emitDispatch!GatewayResumedInfo(GatewayResumedInfo.init);
    }

    private void handleMessageCreateDispatch(JSONValue data)
    {
        auto message = Message.fromJSON(data);

        if (onMessageCreate !is null)
            onMessageCreate(message);

        GatewayMessageCreateEvent event;
        event.message = message;
        emitDispatch!GatewayMessageCreateEvent(event);
        emitDispatch!Message(message);
    }

    private void handleMessageUpdateDispatch(JSONValue data)
    {
        auto message = Message.fromJSON(data);

        if (onMessageUpdate !is null)
            onMessageUpdate(message);

        GatewayMessageUpdateEvent event;
        event.message = message;
        emitDispatch!GatewayMessageUpdateEvent(event);
        emitDispatch!Message(message);
    }

    private void handleChannelCreateDispatch(JSONValue data)
    {
        auto channel = Channel.fromJSON(data);

        if (onChannelCreate !is null)
            onChannelCreate(channel);

        GatewayChannelCreateEvent event;
        event.channel = channel;
        emitDispatch!GatewayChannelCreateEvent(event);
        emitDispatch!Channel(channel);
    }

    private void handleChannelUpdateDispatch(JSONValue data)
    {
        auto channel = Channel.fromJSON(data);

        if (onChannelUpdate !is null)
            onChannelUpdate(channel);

        GatewayChannelUpdateEvent event;
        event.channel = channel;
        emitDispatch!GatewayChannelUpdateEvent(event);
        emitDispatch!Channel(channel);
    }

    private void handleChannelDeleteDispatch(JSONValue data)
    {
        auto channel = Channel.fromJSON(data);

        if (onChannelDelete !is null)
            onChannelDelete(channel);

        GatewayChannelDeleteEvent event;
        event.channel = channel;
        emitDispatch!GatewayChannelDeleteEvent(event);
        emitDispatch!Channel(channel);
    }

    private void handleThreadCreateDispatch(JSONValue data)
    {
        auto thread = Channel.fromJSON(data);

        if (onThreadCreate !is null)
            onThreadCreate(thread);

        GatewayThreadCreateEvent event;
        event.thread = thread;
        emitDispatch!GatewayThreadCreateEvent(event);
        emitDispatch!Channel(thread);
    }

    private void handleThreadUpdateDispatch(JSONValue data)
    {
        auto thread = Channel.fromJSON(data);

        if (onThreadUpdate !is null)
            onThreadUpdate(thread);

        GatewayThreadUpdateEvent event;
        event.thread = thread;
        emitDispatch!GatewayThreadUpdateEvent(event);
        emitDispatch!Channel(thread);
    }

    private void invokeFromJSON(T)(JSONValue data, void delegate(T) callback)
    {
        if (callback is null && !hasDispatchSubscribers!T())
            return;

        auto value = T.fromJSON(data);

        if (callback !is null)
            callback(value);

        emitDispatch!T(value);
    }

    private void invokeParsed(T, alias parser)(JSONValue data, void delegate(T) callback)
    {
        if (callback is null && !hasDispatchSubscribers!T())
            return;

        auto value = parser(data);

        if (callback !is null)
            callback(value);

        emitDispatch!T(value);
    }

    private void handleDispatch(GatewayEnvelope envelope)
    {
        auto handler = envelope.eventName in _dispatchHandlers;
        if (handler is null)
        {
            reportUnhandledDispatch(envelope.eventName);
            return;
        }

        (*handler)(envelope.data);
    }

    private DispatchSubscription!E[] subscriptionEntries(E)(string key)
    {
        if (auto existing = key in _dispatchSubscriptions)
            return (*existing).get!(DispatchSubscription!E[]).dup;
        return null;
    }

    private bool hasDispatchSubscribers(E)()
    {
        auto key = typeid(E).toString;
        synchronized (_dispatchSubscriptionsMutex)
        {
            auto handlers = subscriptionEntries!E(key);
            return handlers.length != 0;
        }
    }

    private void emitDispatch(E)(E value)
    {
        auto key = typeid(E).toString;

        DispatchSubscription!E[] handlers;
        synchronized (_dispatchSubscriptionsMutex)
            handlers = subscriptionEntries!E(key);

        if (handlers.length == 0)
            return;

        DispatchSubscription!E[] survivors;
        foreach (entry; handlers)
        {
            try
            {
                entry.handler(value);
            }
            catch (Exception error)
            {
                reportError(formatError(
                    "gateway",
                    "A typed gateway listener raised an exception.",
                    "Listener for `" ~ typeid(E).toString ~ "` failed with `" ~ error.msg ~ "`.",
                    "Inspect the listener implementation. Remaining listeners continued."
                ));
            }

            if (!entry.once)
                survivors ~= entry;
        }

        synchronized (_dispatchSubscriptionsMutex)
            _dispatchSubscriptions[key] = Variant(survivors);
    }

    private GatewayEnvelope receiveEnvelope()
    {
        auto message = _socket.receive();
        string rawPayload;

        if (message.type == MessageType.Text)
        {
            rawPayload = message.text;
        }
        else if (message.type == MessageType.Binary)
        {
            rawPayload = cast(string) message.data;
        }
        else
        {
            throw new DdiscordException(formatError(
                "gateway",
                "Discord sent an unsupported gateway frame type.",
                "Received WebSocket frame type `" ~ (cast(int) message.type).to!string ~ "`.",
                "Use data frames (`Text`/`Binary`) for gateway envelopes."
            ));
        }

        JSONValue json;
        try
        {
            json = parseJSON(rawPayload);
        }
        catch (Exception error)
        {
            auto hint = message.type == MessageType.Binary
                ? "Binary gateway payloads that are not JSON usually indicate ETF or compression. Use `encoding=json` without compression or add an ETF/decoder layer."
                : "Check whether the gateway connection negotiated JSON encoding.";
            throw new DdiscordException(formatError(
                "gateway",
                "Discord sent a payload that could not be parsed as JSON.",
                error.msg,
                hint
            ));
        }

        GatewayEnvelope envelope;

        auto opValue = json.object.get("op", JSONValue.init);
        if (opValue.type == JSONType.null_)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "A gateway payload was missing its opcode.",
                json.toString(),
                "This usually indicates an unexpected protocol change or malformed frame."
            ));
        }

        envelope.opcode = cast(GatewayOpcode) opValue.integer;

        auto sequenceValue = json.object.get("s", JSONValue.init);
        if (sequenceValue.type != JSONType.null_)
            envelope.sequence = Nullable!long.of(cast(long) sequenceValue.integer);

        auto eventValue = json.object.get("t", JSONValue.init);
        if (eventValue.type != JSONType.null_)
            envelope.eventName = eventValue.str;

        auto dataValue = json.object.get("d", JSONValue.init);
        if (dataValue.type != JSONType.null_)
            envelope.data = dataValue;

        return envelope;
    }

    private void sendHeartbeat()
    {
        JSONValue payload;
        if (_sequence.isNull)
            payload = JSONValue.init;
        else
            payload = JSONValue(_sequence.get);
        sendPayload(GatewayOpcode.Heartbeat, payload);
    }

    private void sendIdentify()
    {
        _nextSessionMode = GatewaySessionMode.Identify;
        JSONValue payload;
        payload["token"] = gatewayToken(config.token);
        payload["intents"] = config.intents;

        if (config.shardCount > 1)
        {
            JSONValue[] shard;
            shard ~= JSONValue(cast(long) config.shardId);
            shard ~= JSONValue(cast(long) config.shardCount);
            payload["shard"] = shard;
        }

        JSONValue properties;
        properties["os"] = runtimeOs();
        properties["browser"] = "ddiscord";
        properties["device"] = "ddiscord";
        payload["properties"] = properties;

        sendPayload(GatewayOpcode.Identify, payload);
        reportStatus("Sent IDENTIFY to the Discord gateway.");
    }

    private void sendResume()
    {
        _nextSessionMode = GatewaySessionMode.Resume;
        JSONValue payload;
        payload["token"] = gatewayToken(config.token);
        payload["session_id"] = _sessionId;
        payload["seq"] = _sequence.get;
        sendPayload(GatewayOpcode.Resume, payload);
        reportStatus("Sent RESUME to the Discord gateway.");
    }

    private void sendPayload(GatewayOpcode opcode, JSONValue data)
    {
        JSONValue payload;
        payload["op"] = cast(int) opcode;
        payload["d"] = data;
        synchronized (_sendMutex)
        {
            if (_socket is null)
                throw new DdiscordException("The Discord gateway socket is not available.");
            _socket.send(payload.toString());
        }
    }

    private Duration parseHeartbeatInterval(JSONValue data)
    {
        auto value = data.object.get("heartbeat_interval", JSONValue.init);
        if (value.type == JSONType.null_)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "Discord did not provide a heartbeat interval.",
                data.toString(),
                "Without a heartbeat interval the session cannot remain connected."
            ));
        }

        return dur!"msecs"(cast(long) value.integer);
    }

    private NetworkStream openNetworkStream(string host, ushort port, bool secure)
    {
        try
        {
            if (secure)
            {
                auto socket = new SSLSocketStream(SSLOptions());
                return socket.connect(host, port, config.connectTimeout);
            }

            auto socket = new TCPSocketStream;
            return socket.connect(host, port, config.connectTimeout);
        }
        catch (ConnectError error)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "Could not connect to the Discord gateway.",
                error.msg,
                "Check DNS resolution, outbound network access, or Discord availability."
            ));
        }
    }

    private string activeGatewayUrl() const
    {
        return _resumeGatewayUrl.length != 0 ? _resumeGatewayUrl : config.url;
    }

    private bool canResumeSession() const
    {
        return _sessionId.length != 0 && !_sequence.isNull;
    }

    private void startHeartbeatLoop(Duration initialDelay, Duration interval)
    {
        stopHeartbeatLoop();

        synchronized (_heartbeatMutex)
        {
            _heartbeatLoopRunning = true;
            _awaitingHeartbeatAck = false;
        }

        _heartbeatThread = new Thread({
            if (!sleepHeartbeatDelay(initialDelay))
                return;

            while (heartbeatLoopActive())
            {
                bool missedAck;
                synchronized (_heartbeatMutex)
                    missedAck = _awaitingHeartbeatAck;

                if (missedAck)
                {
                    abortCurrentConnection();
                    return;
                }

                try
                {
                    sendHeartbeat();
                }
                catch (Exception error)
                {
                    reportError("Heartbeat send failed; resetting gateway connection. detail=" ~ error.msg);
                    abortCurrentConnection();
                    return;
                }

                synchronized (_heartbeatMutex)
                    _awaitingHeartbeatAck = true;

                if (!sleepHeartbeatDelay(interval))
                    return;
            }
        });
        _heartbeatThread.start();
    }

    private void stopHeartbeatLoop()
    {
        synchronized (_heartbeatMutex)
        {
            _heartbeatLoopRunning = false;
            _awaitingHeartbeatAck = false;
        }

        if (_heartbeatThread !is null)
        {
            _heartbeatThread.join();
            _heartbeatThread = null;
        }
    }

    private bool heartbeatLoopActive()
    {
        synchronized (_heartbeatMutex)
            return _heartbeatLoopRunning && !_stopRequested;
    }

    private bool sleepHeartbeatDelay(Duration delay)
    {
        if (delay <= Duration.zero)
            return heartbeatLoopActive();

        auto remaining = delay;
        auto slice = dur!"msecs"(100);
        while (remaining > Duration.zero)
        {
            if (!heartbeatLoopActive())
                return false;

            auto currentSlice = remaining < slice ? remaining : slice;
            Thread.sleep(currentSlice);
            remaining -= currentSlice;
        }

        return heartbeatLoopActive();
    }

    private void abortCurrentConnection()
    {
        if (_stream !is null)
            _stream.close();
    }

    private void clearSession()
    {
        _ready = false;
        _sessionId = "";
        _resumeGatewayUrl = "";
        _sequence = Nullable!long.init;
    }

    private void close(bool graceful = false)
    {
        if (_socket !is null)
        {
            try
            {
                if (graceful)
                    _socket.close();
            }
            catch (Exception error)
            {
                reportError("Graceful gateway socket close failed. detail=" ~ error.msg);
            }
            _socket = null;
        }

        if (_stream !is null)
        {
            _stream.close();
            _stream = null;
        }
    }

    private void reportStatus(string message)
    {
        if (config.logger !is null)
            config.logger.log(LogLevel.Information, "gateway", message);
        if (onStatus !is null)
            onStatus(message);
    }

    private void reportError(string message)
    {
        if (config.logger !is null)
            config.logger.log(LogLevel.Error, "gateway", message);
        if (onError !is null)
            onError(message);
    }

    private void reportUnhandledDispatch(string eventName)
    {
        if (!config.logUnhandledDispatchEvents)
            return;

        auto current = _unhandledDispatchEventCounts.get(eventName, 0) + 1;
        _unhandledDispatchEventCounts[eventName] = current;

        auto every = config.unhandledDispatchLogEvery == 0 ? 1 : config.unhandledDispatchLogEvery;
        if (current == 1 || (current % every) == 0)
        {
            reportStatus(
                "Received unhandled gateway dispatch `" ~ eventName ~ "` (" ~ current.to!string ~ " observed)."
            );
        }
    }
}

private GatewayGuildMemberAddInfo parseGuildMemberAdd(JSONValue data)
{
    GatewayGuildMemberAddInfo info;
    info.member = GuildMember.fromJSON(data);

    auto guildIdValue = data.object.get("guild_id", JSONValue.init);
    if (guildIdValue.type != JSONType.null_)
    {
        try
        {
            info.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));
        }
        catch (ConvException)
        {
        }
    }

    auto memberCountValue = data.object.get("member_count", JSONValue.init);
    if (memberCountValue.type != JSONType.null_)
        info.memberCount = cast(size_t) memberCountValue.integer;

    return info;
}

private GatewayPresenceUpdateInfo parsePresenceUpdate(JSONValue data)
{
    GatewayPresenceUpdateInfo info;

    auto guildIdValue = data.object.get("guild_id", JSONValue.init);
    if (guildIdValue.type != JSONType.null_)
    {
        try
        {
            info.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));
        }
        catch (ConvException)
        {
        }
    }

    auto userValue = data.object.get("user", JSONValue.init);
    if (userValue.type != JSONType.null_)
        info.user = User.fromJSON(userValue);

    auto memberValue = data.object.get("member", JSONValue.init);
    if (memberValue.type != JSONType.null_)
        info.member = Nullable!GuildMember.of(GuildMember.fromJSON(memberValue));

    auto statusValue = data.object.get("status", JSONValue.init);
    if (statusValue.type != JSONType.null_)
        info.status = statusFromDiscord(statusValue.str);

    auto activitiesValue = data.object.get("activities", JSONValue.init);
    if (activitiesValue.type == JSONType.array && activitiesValue.array.length != 0)
        info.activity = Activity.fromJSON(activitiesValue.array[0]);

    return info;
}

private GatewayMessageDeleteInfo parseMessageDelete(JSONValue data)
{
    GatewayMessageDeleteInfo info;

    auto messageId = parseSnowflakeField(data, "id");
    if (!messageId.isNull)
        info.messageId = messageId.get;

    info.channelId = parseSnowflakeField(data, "channel_id");
    info.guildId = parseSnowflakeField(data, "guild_id");
    return info;
}

private GatewayGuildMemberRemoveInfo parseGuildMemberRemove(JSONValue data)
{
    GatewayGuildMemberRemoveInfo info;

    auto userValue = data.object.get("user", JSONValue.init);
    if (userValue.type != JSONType.null_)
        info.user = User.fromJSON(userValue);

    info.guildId = parseSnowflakeField(data, "guild_id");
    return info;
}

private GatewayGuildBanInfo parseGuildBan(JSONValue data)
{
    GatewayGuildBanInfo info;

    auto guildId = parseSnowflakeField(data, "guild_id");
    if (!guildId.isNull)
        info.guildId = guildId.get;

    auto userValue = data.object.get("user", JSONValue.init);
    if (userValue.type != JSONType.null_)
        info.user = User.fromJSON(userValue);

    return info;
}

private GatewayTypingStartInfo parseTypingStart(JSONValue data)
{
    GatewayTypingStartInfo info;

    auto channelId = parseSnowflakeField(data, "channel_id");
    if (!channelId.isNull)
        info.channelId = channelId.get;

    auto userId = parseSnowflakeField(data, "user_id");
    if (!userId.isNull)
        info.userId = userId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");

    auto timestampValue = data.object.get("timestamp", JSONValue.init);
    if (timestampValue.type != JSONType.null_)
    {
        if (timestampValue.type == JSONType.string)
        {
            try
                info.timestampUnix = timestampValue.str.to!long;
            catch (ConvException)
            {
            }
        }
        else if (timestampValue.type == JSONType.integer || timestampValue.type == JSONType.uinteger)
        {
            info.timestampUnix = cast(long) timestampValue.integer;
        }
    }

    return info;
}

private GatewayChannelPinsUpdateInfo parseChannelPinsUpdate(JSONValue data)
{
    GatewayChannelPinsUpdateInfo info;

    auto channelId = parseSnowflakeField(data, "channel_id");
    if (!channelId.isNull)
        info.channelId = channelId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");

    auto lastPinTimestampValue = data.object.get("last_pin_timestamp", JSONValue.init);
    if (lastPinTimestampValue.type != JSONType.null_)
        info.lastPinTimestamp = lastPinTimestampValue.str;

    return info;
}

private GatewayMessageReactionInfo parseMessageReaction(JSONValue data)
{
    GatewayMessageReactionInfo info;

    auto userId = parseSnowflakeField(data, "user_id");
    if (!userId.isNull)
        info.userId = userId.get;

    auto channelId = parseSnowflakeField(data, "channel_id");
    if (!channelId.isNull)
        info.channelId = channelId.get;

    auto messageId = parseSnowflakeField(data, "message_id");
    if (!messageId.isNull)
        info.messageId = messageId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");

    auto emojiValue = data.object.get("emoji", JSONValue.init);
    if (emojiValue.type != JSONType.null_)
    {
        auto nameValue = emojiValue.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            info.emojiName = nameValue.str;
    }

    return info;
}

private GatewayMessageReactionRemoveAllInfo parseMessageReactionRemoveAll(JSONValue data)
{
    GatewayMessageReactionRemoveAllInfo info;

    auto channelId = parseSnowflakeField(data, "channel_id");
    if (!channelId.isNull)
        info.channelId = channelId.get;

    auto messageId = parseSnowflakeField(data, "message_id");
    if (!messageId.isNull)
        info.messageId = messageId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");
    return info;
}

private GatewayGuildRoleInfo parseGuildRole(JSONValue data)
{
    GatewayGuildRoleInfo info;

    auto guildId = parseSnowflakeField(data, "guild_id");
    if (!guildId.isNull)
        info.guildId = guildId.get;

    auto roleValue = data.object.get("role", JSONValue.init);
    if (roleValue.type != JSONType.null_)
        info.role = Role.fromJSON(roleValue);

    return info;
}

private GatewayGuildRoleDeleteInfo parseGuildRoleDelete(JSONValue data)
{
    GatewayGuildRoleDeleteInfo info;

    auto guildId = parseSnowflakeField(data, "guild_id");
    if (!guildId.isNull)
        info.guildId = guildId.get;

    auto roleId = parseSnowflakeField(data, "role_id");
    if (!roleId.isNull)
        info.roleId = roleId.get;

    return info;
}

private GatewayInviteInfo parseInvite(JSONValue data)
{
    GatewayInviteInfo info;

    auto codeValue = data.object.get("code", JSONValue.init);
    if (codeValue.type != JSONType.null_)
        info.code = codeValue.str;

    auto channelId = parseSnowflakeField(data, "channel_id");
    if (!channelId.isNull)
        info.channelId = channelId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");
    return info;
}

private GatewayWebhooksUpdateInfo parseWebhooksUpdate(JSONValue data)
{
    GatewayWebhooksUpdateInfo info;

    auto channelId = parseSnowflakeField(data, "channel_id");
    if (!channelId.isNull)
        info.channelId = channelId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");
    return info;
}

private GatewayThreadDeleteInfo parseThreadDelete(JSONValue data)
{
    GatewayThreadDeleteInfo info;

    auto threadId = parseSnowflakeField(data, "id");
    if (!threadId.isNull)
        info.threadId = threadId.get;

    info.guildId = parseSnowflakeField(data, "guild_id");
    info.parentId = parseSnowflakeField(data, "parent_id");
    return info;
}

private Nullable!Snowflake parseSnowflakeField(JSONValue data, string key)
{
    auto value = data.object.get(key, JSONValue.init);
    if (value.type == JSONType.null_)
        return Nullable!Snowflake.init;

    try
    {
        if (value.type == JSONType.string)
            return Nullable!Snowflake.of(Snowflake(value.str.to!ulong));
        if (value.type == JSONType.integer || value.type == JSONType.uinteger)
            return Nullable!Snowflake.of(Snowflake(cast(ulong) value.integer));
    }
    catch (ConvException)
    {
    }

    return Nullable!Snowflake.init;
}

private Duration firstHeartbeatDelay(Duration heartbeatInterval)
{
    if (heartbeatInterval <= Duration.zero)
        return Duration.zero;

    auto factor = uniform(0.0, 1.0);
    auto delayMs = cast(long) (heartbeatInterval.total!"msecs" * factor);
    return dur!"msecs"(delayMs);
}

private Duration invalidSessionReconnectDelay()
{
    return dur!"msecs"(uniform(1_000, 5_001));
}

private bool parseInvalidSessionFlag(JSONValue value)
{
    return value.type == JSONType.true_;
}

private bool requiresFreshIdentify(int closeCode)
{
    return closeCode == GatewayCloseCode.NormalClosure ||
        closeCode == GatewayCloseCode.GoingAway ||
        closeCode == GatewayCloseCode.InvalidSeq ||
        closeCode == GatewayCloseCode.SessionTimedOut;
}

private bool isFatalCloseCode(int closeCode)
{
    return closeCode == GatewayCloseCode.AuthenticationFailed ||
        closeCode == GatewayCloseCode.InvalidShard ||
        closeCode == GatewayCloseCode.ShardingRequired ||
        closeCode == GatewayCloseCode.InvalidApiVersion ||
        closeCode == GatewayCloseCode.InvalidIntents ||
        closeCode == GatewayCloseCode.DisallowedIntents;
}

private string fatalCloseHint(int closeCode)
{
    if (isFatalCloseCode(closeCode))
        return "Discord reported a non-recoverable gateway error. Fix the token, shard, version, or intent configuration before reconnecting.";

    if (requiresFreshIdentify(closeCode))
        return "The client will reconnect automatically and start a fresh gateway session.";

    return "The client will reconnect automatically unless shutdown was requested.";
}

private string normalizedGatewayUrl(string url)
{
    immutable gatewayVersion = DiscordGatewayVersion.to!string;
    if (!url.canFind("encoding="))
        url ~= url.canFind("?") ? "&encoding=json" : gatewayQueryPrefix(url) ~ "encoding=json";
    if (!url.canFind("v="))
        url ~= url.canFind("?") ? "&v=" ~ gatewayVersion : gatewayQueryPrefix(url) ~ "v=" ~ gatewayVersion;
    return url;
}

private string gatewayQueryPrefix(string url)
{
    return url.endsWith("/") ? "?" : "/?";
}

private bool isTimeoutError(Exception error)
{
    return error.msg.canFind("Timed out");
}

private string gatewayToken(string token)
{
    return token.startsWith("Bot ") ? token["Bot ".length .. $] : token;
}

private string runtimeOs()
{
    version (Windows)
        return "windows";
    else version (OSX)
        return "macos";
    else version (linux)
        return "linux";
    else
        return "unknown";
}

private Duration minDuration(Duration left, Duration right)
{
    return left <= right ? left : right;
}

unittest
{
    final class CapturingGatewayLogger : ILogger
    {
        string[] entries;

        override void log(LogLevel level, string category, string message)
        {
            entries ~= category ~ ":" ~ (cast(int) level).to!string ~ ":" ~ message;
        }
    }

    auto logger = new CapturingGatewayLogger;
    GatewayClientConfig config = GatewayClientConfig("token", 0, "wss://gateway.discord.gg");
    config.logger = logger;

    auto client = new GatewayClient(config);
    size_t statusCalls;
    size_t errorCalls;
    client.onStatus = (string message) {
        auto _ = message;
        statusCalls++;
    };
    client.onError = (string message) {
        auto _ = message;
        errorCalls++;
    };

    client.reportStatus("connected");
    client.reportError("failed");

    assert(statusCalls == 1);
    assert(errorCalls == 1);
    assert(logger.entries.length == 2);
    assert(logger.entries[0].canFind("connected"));
    assert(logger.entries[1].canFind("failed"));
}

unittest
{
    auto client = new GatewayClient(GatewayClientConfig("token", 0, "wss://gateway.discord.gg"));

    Guild capturedGuild;
    UnavailableGuild deletedGuild;
    size_t createCalls;
    size_t deleteCalls;
    client.onGuildCreate = (Guild guild) {
        capturedGuild = guild;
        createCalls++;
    };
    client.onGuildDelete = (UnavailableGuild guild) {
        deletedGuild = guild;
        deleteCalls++;
    };

    GatewayEnvelope guildCreate;
    guildCreate.opcode = GatewayOpcode.Dispatch;
    guildCreate.eventName = "GUILD_CREATE";
    guildCreate.data = JSONValue(["id": JSONValue("10"), "name": JSONValue("home"), "owner_id": JSONValue("7")]);
    client.handleDispatch(guildCreate);

    GatewayEnvelope guildDelete;
    guildDelete.opcode = GatewayOpcode.Dispatch;
    guildDelete.eventName = "GUILD_DELETE";
    guildDelete.data = JSONValue(["id": JSONValue("10"), "unavailable": JSONValue(true)]);
    client.handleDispatch(guildDelete);

    assert(createCalls == 1);
    assert(capturedGuild.id == Snowflake(10));
    assert(capturedGuild.name == "home");
    assert(deleteCalls == 1);
    assert(deletedGuild.id == Snowflake(10));
    assert(deletedGuild.unavailable);
}

unittest
{
    auto client = new GatewayClient(GatewayClientConfig("token", 0, "wss://gateway.discord.gg"));

    size_t regularCalls;
    size_t onceCalls;

    void delegate(Guild) regular = (Guild guild) {
        auto _ = guild;
        regularCalls++;
    };

    client.on!Guild(regular);
    client.once!Guild((Guild guild) {
        auto _ = guild;
        onceCalls++;
    });

    auto makeEnvelope = (string eventName, JSONValue payload) {
        GatewayEnvelope envelope;
        envelope.opcode = GatewayOpcode.Dispatch;
        envelope.eventName = eventName;
        envelope.data = payload;
        return envelope;
    };

    auto payload = JSONValue(["id": JSONValue("10"), "name": JSONValue("home"), "owner_id": JSONValue("7")]);
    client.handleDispatch(makeEnvelope("GUILD_CREATE", payload));
    client.handleDispatch(makeEnvelope("GUILD_CREATE", payload));
    client.off!Guild(regular);
    client.handleDispatch(makeEnvelope("GUILD_CREATE", payload));

    assert(regularCalls == 2);
    assert(onceCalls == 1);
}

unittest
{
    auto client = new GatewayClient(GatewayClientConfig("token", 0, "wss://gateway.discord.gg"));

    size_t anyMessageCalls;
    size_t createCalls;
    size_t updateCalls;

    client.on!Message((Message message) {
        auto _ = message;
        anyMessageCalls++;
    });
    client.on!GatewayMessageCreateEvent((GatewayMessageCreateEvent event) {
        auto _ = event;
        createCalls++;
    });
    client.on!GatewayMessageUpdateEvent((GatewayMessageUpdateEvent event) {
        auto _ = event;
        updateCalls++;
    });

    auto makeEnvelope = (string eventName, JSONValue payload) {
        GatewayEnvelope envelope;
        envelope.opcode = GatewayOpcode.Dispatch;
        envelope.eventName = eventName;
        envelope.data = payload;
        return envelope;
    };

    auto createPayload = JSONValue([
        "id": JSONValue("100"),
        "channel_id": JSONValue("10"),
        "content": JSONValue("hello"),
        "author": JSONValue([
            "id": JSONValue("9"),
            "username": JSONValue("u")
        ])
    ]);

    auto updatePayload = JSONValue([
        "id": JSONValue("100"),
        "channel_id": JSONValue("10"),
        "author": JSONValue([
            "id": JSONValue("9"),
            "username": JSONValue("u")
        ])
    ]);

    client.handleDispatch(makeEnvelope("MESSAGE_CREATE", createPayload));
    client.handleDispatch(makeEnvelope("MESSAGE_UPDATE", updatePayload));

    assert(anyMessageCalls == 2);
    assert(createCalls == 1);
    assert(updateCalls == 1);
}

unittest
{
    auto client = new GatewayClient(GatewayClientConfig("token", 0, "wss://gateway.discord.gg"));

    size_t channelCreates;
    size_t channelUpdates;
    size_t channelDeletes;
    size_t messageUpdates;
    size_t messageDeletes;
    size_t pinsUpdates;
    size_t reactionAdds;
    size_t reactionRemoves;
    size_t reactionRemoveAll;
    size_t reactionRemoveEmoji;
    size_t memberRemoves;
    size_t guildBanAdds;
    size_t guildBanRemoves;
    size_t typingStarts;
    size_t roleCreates;
    size_t roleUpdates;
    size_t roleDeletes;
    size_t inviteCreates;
    size_t inviteDeletes;
    size_t webhooksUpdates;
    size_t threadCreates;
    size_t threadUpdates;
    size_t threadDeletes;

    client.onChannelCreate = (Channel channel) {
        auto _ = channel;
        channelCreates++;
    };
    client.onChannelUpdate = (Channel channel) {
        auto _ = channel;
        channelUpdates++;
    };
    client.onChannelDelete = (Channel channel) {
        auto _ = channel;
        channelDeletes++;
    };
    client.onMessageUpdate = (Message message) {
        auto _ = message;
        messageUpdates++;
    };
    client.onMessageDelete = (GatewayMessageDeleteInfo info) {
        auto _ = info;
        messageDeletes++;
    };
    client.onChannelPinsUpdate = (GatewayChannelPinsUpdateInfo info) {
        auto _ = info;
        pinsUpdates++;
    };
    client.onMessageReactionAdd = (GatewayMessageReactionInfo info) {
        auto _ = info;
        reactionAdds++;
    };
    client.onMessageReactionRemove = (GatewayMessageReactionInfo info) {
        auto _ = info;
        reactionRemoves++;
    };
    client.onMessageReactionRemoveAll = (GatewayMessageReactionRemoveAllInfo info) {
        auto _ = info;
        reactionRemoveAll++;
    };
    client.onMessageReactionRemoveEmoji = (GatewayMessageReactionInfo info) {
        auto _ = info;
        reactionRemoveEmoji++;
    };
    client.onGuildMemberRemove = (GatewayGuildMemberRemoveInfo info) {
        auto _ = info;
        memberRemoves++;
    };
    client.onGuildBanAdd = (GatewayGuildBanInfo info) {
        auto _ = info;
        guildBanAdds++;
    };
    client.onGuildBanRemove = (GatewayGuildBanInfo info) {
        auto _ = info;
        guildBanRemoves++;
    };
    client.onTypingStart = (GatewayTypingStartInfo info) {
        auto _ = info;
        typingStarts++;
    };
    client.onGuildRoleCreate = (GatewayGuildRoleInfo info) {
        auto _ = info;
        roleCreates++;
    };
    client.onGuildRoleUpdate = (GatewayGuildRoleInfo info) {
        auto _ = info;
        roleUpdates++;
    };
    client.onGuildRoleDelete = (GatewayGuildRoleDeleteInfo info) {
        auto _ = info;
        roleDeletes++;
    };
    client.onInviteCreate = (GatewayInviteInfo info) {
        auto _ = info;
        inviteCreates++;
    };
    client.onInviteDelete = (GatewayInviteInfo info) {
        auto _ = info;
        inviteDeletes++;
    };
    client.onWebhooksUpdate = (GatewayWebhooksUpdateInfo info) {
        auto _ = info;
        webhooksUpdates++;
    };
    client.onThreadCreate = (Channel channel) {
        auto _ = channel;
        threadCreates++;
    };
    client.onThreadUpdate = (Channel channel) {
        auto _ = channel;
        threadUpdates++;
    };
    client.onThreadDelete = (GatewayThreadDeleteInfo info) {
        auto _ = info;
        threadDeletes++;
    };

    auto makeEnvelope = (string eventName, JSONValue payload) {
        GatewayEnvelope envelope;
        envelope.opcode = GatewayOpcode.Dispatch;
        envelope.eventName = eventName;
        envelope.data = payload;
        return envelope;
    };

    client.handleDispatch(makeEnvelope("CHANNEL_CREATE", JSONValue(["id": JSONValue("1"), "name": JSONValue("a"), "type": JSONValue(0L)])));
    client.handleDispatch(makeEnvelope("CHANNEL_UPDATE", JSONValue(["id": JSONValue("1"), "name": JSONValue("b"), "type": JSONValue(0L)])));
    client.handleDispatch(makeEnvelope("CHANNEL_DELETE", JSONValue(["id": JSONValue("1"), "name": JSONValue("c"), "type": JSONValue(0L)])));
    client.handleDispatch(makeEnvelope("MESSAGE_UPDATE", JSONValue(["id": JSONValue("2"), "channel_id": JSONValue("1"), "author": JSONValue(["id": JSONValue("9"), "username": JSONValue("u")])])));
    client.handleDispatch(makeEnvelope("MESSAGE_DELETE", JSONValue(["id": JSONValue("2"), "channel_id": JSONValue("1"), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("CHANNEL_PINS_UPDATE", JSONValue(["channel_id": JSONValue("1"), "guild_id": JSONValue("7"), "last_pin_timestamp": JSONValue("2026-04-23T00:00:00.000000+00:00")])));
    client.handleDispatch(makeEnvelope("MESSAGE_REACTION_ADD", JSONValue(["user_id": JSONValue("9"), "channel_id": JSONValue("1"), "message_id": JSONValue("2"), "guild_id": JSONValue("7"), "emoji": JSONValue(["name": JSONValue("fire")])])));
    client.handleDispatch(makeEnvelope("MESSAGE_REACTION_REMOVE", JSONValue(["user_id": JSONValue("9"), "channel_id": JSONValue("1"), "message_id": JSONValue("2"), "guild_id": JSONValue("7"), "emoji": JSONValue(["name": JSONValue("fire")])])));
    client.handleDispatch(makeEnvelope("MESSAGE_REACTION_REMOVE_ALL", JSONValue(["channel_id": JSONValue("1"), "message_id": JSONValue("2"), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("MESSAGE_REACTION_REMOVE_EMOJI", JSONValue(["channel_id": JSONValue("1"), "message_id": JSONValue("2"), "guild_id": JSONValue("7"), "emoji": JSONValue(["name": JSONValue("fire")])])));
    client.handleDispatch(makeEnvelope("GUILD_MEMBER_REMOVE", JSONValue(["guild_id": JSONValue("7"), "user": JSONValue(["id": JSONValue("9"), "username": JSONValue("u")])])));
    client.handleDispatch(makeEnvelope("GUILD_BAN_ADD", JSONValue(["guild_id": JSONValue("7"), "user": JSONValue(["id": JSONValue("9"), "username": JSONValue("u")])])));
    client.handleDispatch(makeEnvelope("GUILD_BAN_REMOVE", JSONValue(["guild_id": JSONValue("7"), "user": JSONValue(["id": JSONValue("9"), "username": JSONValue("u")])])));
    client.handleDispatch(makeEnvelope("TYPING_START", JSONValue(["channel_id": JSONValue("1"), "guild_id": JSONValue("7"), "user_id": JSONValue("9"), "timestamp": JSONValue(123L)])));
    client.handleDispatch(makeEnvelope("GUILD_ROLE_CREATE", JSONValue(["guild_id": JSONValue("7"), "role": JSONValue(["id": JSONValue("55"), "name": JSONValue("mod"), "permissions": JSONValue("0")])])));
    client.handleDispatch(makeEnvelope("GUILD_ROLE_UPDATE", JSONValue(["guild_id": JSONValue("7"), "role": JSONValue(["id": JSONValue("55"), "name": JSONValue("admin"), "permissions": JSONValue("0")])])));
    client.handleDispatch(makeEnvelope("GUILD_ROLE_DELETE", JSONValue(["guild_id": JSONValue("7"), "role_id": JSONValue("55")])));
    client.handleDispatch(makeEnvelope("INVITE_CREATE", JSONValue(["code": JSONValue("abc"), "channel_id": JSONValue("1"), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("INVITE_DELETE", JSONValue(["code": JSONValue("abc"), "channel_id": JSONValue("1"), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("WEBHOOKS_UPDATE", JSONValue(["channel_id": JSONValue("1"), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("THREAD_CREATE", JSONValue(["id": JSONValue("88"), "name": JSONValue("thread-a"), "type": JSONValue(11L), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("THREAD_UPDATE", JSONValue(["id": JSONValue("88"), "name": JSONValue("thread-b"), "type": JSONValue(11L), "guild_id": JSONValue("7")])));
    client.handleDispatch(makeEnvelope("THREAD_DELETE", JSONValue(["id": JSONValue("88"), "guild_id": JSONValue("7"), "parent_id": JSONValue("1")])));

    assert(channelCreates == 1);
    assert(channelUpdates == 1);
    assert(channelDeletes == 1);
    assert(messageUpdates == 1);
    assert(messageDeletes == 1);
    assert(pinsUpdates == 1);
    assert(reactionAdds == 1);
    assert(reactionRemoves == 1);
    assert(reactionRemoveAll == 1);
    assert(reactionRemoveEmoji == 1);
    assert(memberRemoves == 1);
    assert(guildBanAdds == 1);
    assert(guildBanRemoves == 1);
    assert(typingStarts == 1);
    assert(roleCreates == 1);
    assert(roleUpdates == 1);
    assert(roleDeletes == 1);
    assert(inviteCreates == 1);
    assert(inviteDeletes == 1);
    assert(webhooksUpdates == 1);
    assert(threadCreates == 1);
    assert(threadUpdates == 1);
    assert(threadDeletes == 1);
}

unittest
{
    JSONValue payload;
    payload["guild_id"] = "42";
    payload["member_count"] = 123;

    JSONValue user;
    user["id"] = "9";
    user["username"] = "alice";
    payload["user"] = user;
    JSONValue[] roles;
    payload["roles"] = roles;
    payload["permissions"] = "0";

    auto info = parseGuildMemberAdd(payload);
    assert(!info.guildId.isNull);
    assert(info.guildId.get == Snowflake(42));
    assert(info.memberCount == 123);
    assert(!info.member.user.isNull);
    assert(info.member.user.get.username == "alice");
}

unittest
{
    JSONValue payload;
    payload["guild_id"] = "77";
    payload["user"] = JSONValue([
        "id": JSONValue("11"),
        "username": JSONValue("banned-user")
    ]);

    auto info = parseGuildBan(payload);
    assert(info.guildId == Snowflake(77));
    assert(info.user.id == Snowflake(11));
    assert(info.user.username == "banned-user");
}

unittest
{
    JSONValue payload;
    payload["guild_id"] = "77";
    payload["status"] = "online";

    JSONValue user;
    user["id"] = "11";
    user["username"] = "presence-user";
    payload["user"] = user;

    JSONValue[] activities;
    JSONValue activity;
    activity["type"] = 2;
    activity["name"] = "spotify";
    activities ~= activity;
    payload["activities"] = activities;

    auto info = parsePresenceUpdate(payload);
    assert(!info.guildId.isNull);
    assert(info.guildId.get == Snowflake(77));
    assert(info.user.username == "presence-user");
    assert(info.status == StatusType.Online);
    assert(info.activity.type == ActivityType.Listening);
    assert(info.activity.name == "spotify");
}

unittest
{
    final class CapturingGatewayLogger : ILogger
    {
        string[] entries;

        override void log(LogLevel level, string category, string message)
        {
            entries ~= category ~ ":" ~ (cast(int) level).to!string ~ ":" ~ message;
        }
    }

    auto logger = new CapturingGatewayLogger;
    GatewayClientConfig config = GatewayClientConfig("token", 0, "wss://gateway.discord.gg");
    config.logger = logger;
    config.logUnhandledDispatchEvents = true;
    config.unhandledDispatchLogEvery = 2;
    auto client = new GatewayClient(config);

    GatewayEnvelope envelope;
    envelope.opcode = GatewayOpcode.Dispatch;
    envelope.eventName = "THREAD_LIST_SYNC";
    client.handleDispatch(envelope);
    client.handleDispatch(envelope);

    assert(logger.entries.length >= 2);
    assert(logger.entries[0].canFind("THREAD_LIST_SYNC"));
    assert(logger.entries[$ - 1].canFind("(2 observed)"));
}

unittest
{
    assert(requiresFreshIdentify(cast(int) GatewayCloseCode.NormalClosure));
    assert(requiresFreshIdentify(cast(int) GatewayCloseCode.InvalidSeq));
    assert(requiresFreshIdentify(cast(int) GatewayCloseCode.SessionTimedOut));
    assert(!requiresFreshIdentify(4000));
}

unittest
{
    assert(isFatalCloseCode(cast(int) GatewayCloseCode.AuthenticationFailed));
    assert(isFatalCloseCode(cast(int) GatewayCloseCode.InvalidIntents));
    assert(!isFatalCloseCode(4000));
}

unittest
{
    auto delay = firstHeartbeatDelay(dur!"seconds"(10));
    assert(delay >= Duration.zero);
    assert(delay <= dur!"seconds"(10));
}

unittest
{
    auto client = new GatewayClient(GatewayClientConfig("token", 0, "wss://gateway.discord.gg"));
    assert(client.sleepHeartbeatDelay(Duration.zero) == false);
}

unittest
{
    auto url = normalizedGatewayUrl("wss://gateway.discord.gg");
    assert(url == "wss://gateway.discord.gg/?encoding=json&v=" ~ DiscordGatewayVersion.to!string);
    assert(gatewayToken("Bot secret") == "secret");
    assert(gatewayToken("secret") == "secret");
}
