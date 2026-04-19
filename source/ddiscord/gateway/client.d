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
import ddiscord.models.interaction : Interaction;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.user : User;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.optional : Nullable;
import requests.streams : ConnectError, NetworkStream, SSLSocketStream,
    SSLOptions, TCPSocketStream, TimeoutException;
import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.random : uniform;
import std.string : endsWith, startsWith;

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
    Duration connectTimeout = dur!"seconds"(15);
    Duration pollTimeout = dur!"msecs"(250);
    Duration reconnectDelay = dur!"seconds"(2);
    Duration maxReconnectDelay = dur!"seconds"(30);
    bool autoReconnect = true;
}

/// READY payload values surfaced to the high-level client.
struct GatewayReadyInfo
{
    User selfUser;
    string sessionId;
    string resumeGatewayUrl;
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
    GatewayClientConfig config;
    void delegate(GatewayReadyInfo) onReady;
    void delegate() onResumed;
    void delegate(string) onStatus;
    void delegate(Message) onMessageCreate;
    void delegate(Interaction) onInteractionCreate;
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

    this(GatewayClientConfig config)
    {
        this.config = config;
        _sendMutex = new Mutex;
        _heartbeatMutex = new Mutex;
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
            catch (Throwable error)
            {
                _lastError = formatError(
                    "gateway",
                    "The Discord gateway session ended unexpectedly.",
                    error.msg,
                    "The client will reconnect automatically unless `autoReconnect` is disabled."
                );

                if (onError !is null)
                    onError(_lastError);

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
        if (onStatus !is null)
            onStatus("Opened the Discord gateway TCP/TLS connection to `" ~ parsed.host ~ "`.");

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
        if (onStatus !is null)
            onStatus("Received HELLO from Discord with heartbeat interval `" ~ heartbeatInterval.total!"msecs".to!string ~ "ms`.");
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

    private void handleDispatch(GatewayEnvelope envelope)
    {
        if (envelope.eventName == "READY")
        {
            auto sessionIdValue = envelope.data.object.get("session_id", JSONValue.init);
            if (sessionIdValue.type != JSONType.null_)
                _sessionId = sessionIdValue.str;

            auto resumeUrlValue = envelope.data.object.get("resume_gateway_url", JSONValue.init);
            if (resumeUrlValue.type != JSONType.null_)
                _resumeGatewayUrl = resumeUrlValue.str;

            GatewayReadyInfo info;
            auto userValue = envelope.data.object.get("user", JSONValue.init);
            if (userValue.type != JSONType.null_)
                info.selfUser = User.fromJSON(userValue);
            info.sessionId = _sessionId;
            info.resumeGatewayUrl = _resumeGatewayUrl;
            _ready = true;
            _nextSessionMode = GatewaySessionMode.Resume;

            if (onReady !is null)
                onReady(info);
            return;
        }

        if (envelope.eventName == "RESUMED")
        {
            _ready = true;
            _nextSessionMode = GatewaySessionMode.Resume;
            if (onResumed !is null)
                onResumed();
            return;
        }

        if (envelope.eventName == "MESSAGE_CREATE")
        {
            if (onMessageCreate !is null)
                onMessageCreate(Message.fromJSON(envelope.data));
            return;
        }

        if (envelope.eventName == "INTERACTION_CREATE")
        {
            if (onInteractionCreate !is null)
                onInteractionCreate(Interaction.fromJSON(envelope.data));
        }
    }

    private GatewayEnvelope receiveEnvelope()
    {
        auto message = _socket.receive();
        if (message.type != MessageType.Text)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "Discord sent a non-text WebSocket payload.",
                "Only JSON text frames are currently supported.",
                "Disable compression and ETF when building the gateway URL."
            ));
        }

        JSONValue json;
        try
        {
            json = parseJSON(message.text);
        }
        catch (Exception error)
        {
            throw new DdiscordException(formatError(
                "gateway",
                "Discord sent a payload that could not be parsed as JSON.",
                error.msg,
                "Check whether the gateway connection negotiated JSON encoding."
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

        JSONValue properties;
        properties["os"] = runtimeOs();
        properties["browser"] = "ddiscord";
        properties["device"] = "ddiscord";
        payload["properties"] = properties;

        sendPayload(GatewayOpcode.Identify, payload);
        if (onStatus !is null)
            onStatus("Sent IDENTIFY to the Discord gateway.");
    }

    private void sendResume()
    {
        _nextSessionMode = GatewaySessionMode.Resume;
        JSONValue payload;
        payload["token"] = gatewayToken(config.token);
        payload["session_id"] = _sessionId;
        payload["seq"] = _sequence.get;
        sendPayload(GatewayOpcode.Resume, payload);
        if (onStatus !is null)
            onStatus("Sent RESUME to the Discord gateway.");
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
                catch (Throwable)
                {
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
            catch (Exception)
            {
            }
            _socket = null;
        }

        if (_stream !is null)
        {
            _stream.close();
            _stream = null;
        }
    }
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
    if (!url.canFind("encoding="))
        url ~= url.canFind("?") ? "&encoding=json" : gatewayQueryPrefix(url) ~ "encoding=json";
    if (!url.canFind("v="))
        url ~= url.canFind("?") ? "&v=10" : gatewayQueryPrefix(url) ~ "v=10";
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
    assert(url == "wss://gateway.discord.gg/?encoding=json&v=10");
    assert(gatewayToken("Bot secret") == "secret");
    assert(gatewayToken("secret") == "secret");
}
