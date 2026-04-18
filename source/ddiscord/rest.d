/**
 * ddiscord — Discord REST client surface.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.rest;

import ddiscord.core.http.client : HttpClient, HttpClientConfig, HttpError, HttpErrorKind,
    HttpMethod, HttpRequest, HttpResponse, HttpTransport;
import ddiscord.core.rest.rate_limiter : RestRateLimiter;
import ddiscord.models.application_command : ApplicationCommandDefinition;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.message : Message, MessageCreate, MessageFlags;
import ddiscord.models.user : User;
import ddiscord.tasks : Task;
import ddiscord.util.errors : formatError;
import ddiscord.util.limits : DiscordApiBase;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.algorithm : canFind;
import std.datetime : Clock, Duration, dur;
import std.json : JSONType, JSONValue;

/// Minimal latency sample.
struct LatencySample
{
    long milliseconds;

    /// Returns the latency in the requested unit.
    long total(string unit)() const
    {
        static if (unit == "msecs")
            return milliseconds;
        else
            return milliseconds;
    }
}

/// Runtime configuration for the public REST client.
struct RestClientConfig
{
    string token;
    Nullable!Snowflake applicationId;
    string apiBase = DiscordApiBase;
    string userAgent = "DiscordBot (https://github.com/yourorg/ddiscord, 0.1.0)";
    Duration timeout = dur!"seconds"(15);
    Nullable!HttpTransport transport;
}

/// Session start limits returned by `GET /gateway/bot`.
struct GatewaySessionStartLimit
{
    uint total;
    uint remaining;
    uint resetAfterMilliseconds;
    uint maxConcurrency;
}

/// Gateway discovery payload returned by Discord.
struct GatewayBotInfo
{
    string url;
    uint shards;
    GatewaySessionStartLimit sessionStartLimit;
}

/// Interaction callback type.
enum InteractionCallbackType : int
{
    ChannelMessageWithSource = 4,
    DeferredChannelMessageWithSource = 5,
    ApplicationCommandAutocompleteResult = 8,
}

private final class MessageHistory
{
    private Message[] _messages;
    private ulong _nextId = 1;

    void store(Message message)
    {
        if (message.id.value == 0)
            message.id = Snowflake(_nextId++);
        _messages ~= message;
    }

    Message[] items()
    {
        return _messages.dup;
    }

    Message[] inChannel(Snowflake channelId)
    {
        Message[] items;
        foreach (message; _messages)
        {
            if (message.channelId == channelId)
                items ~= message;
        }
        return items;
    }
}

private final class ApplicationCommandStore
{
    private ApplicationCommandDefinition[] _commands;

    ApplicationCommandDefinition[] overwrite(ApplicationCommandDefinition[] definitions)
    {
        _commands = definitions.dup;
        return _commands.dup;
    }

    ApplicationCommandDefinition[] items()
    {
        return _commands.dup;
    }
}

private final class RealDiscordRest
{
    private RestClientConfig _config;
    private HttpClient _http;
    private RestRateLimiter _limiter;
    private Nullable!Snowflake _resolvedApplicationId;

    this(RestClientConfig config)
    {
        _config = config;

        HttpClientConfig httpConfig;
        httpConfig.baseUrl = config.apiBase;
        httpConfig.token = config.token;
        httpConfig.userAgent = config.userAgent;
        httpConfig.timeout = config.timeout;
        if (!config.transport.isNull)
            httpConfig.transport = config.transport;

        _http = new HttpClient(httpConfig);
        _limiter = new RestRateLimiter;
        _resolvedApplicationId = config.applicationId;
    }

    Result!(Message, string) createMessage(Snowflake channelId, MessageCreate payload)
    {
        auto validation = payload.validate();
        if (validation.isErr)
            return Result!(Message, string).err(formatError("rest", "Cannot create a Discord message.", validation.error));

        auto request = jsonRequest(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/messages",
            "/channels/" ~ channelId.toString ~ "/messages",
            payload.toJSON()
        );

        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned a message response that was not valid JSON.", json.error));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    Result!(ApplicationCommandDefinition[], string) listGlobalCommands()
    {
        auto applicationId = resolveApplicationId();
        if (applicationId.isErr)
            return Result!(ApplicationCommandDefinition[], string).err(applicationId.error);

        auto request = perform(
            HttpMethod.Get,
            "GET:/applications/{application_id}/commands",
            "/applications/" ~ applicationId.value.toString ~ "/commands"
        );
        if (request.isErr)
            return Result!(ApplicationCommandDefinition[], string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(ApplicationCommandDefinition[], string).err(formatError("rest", "Discord returned an invalid application command list.", json.error));

        ApplicationCommandDefinition[] definitions;
        foreach (item; json.value.array)
            definitions ~= commandDefinitionFromJSON(item);
        return Result!(ApplicationCommandDefinition[], string).ok(definitions);
    }

    Result!(ApplicationCommandDefinition[], string) bulkOverwriteGlobalCommands(ApplicationCommandDefinition[] definitions)
    {
        auto applicationId = resolveApplicationId();
        if (applicationId.isErr)
            return Result!(ApplicationCommandDefinition[], string).err(applicationId.error);

        JSONValue[] payload;
        foreach (definition; definitions)
            payload ~= definition.toJSON();

        auto request = jsonRequest(
            HttpMethod.Put,
            "PUT:/applications/{application_id}/commands",
            "/applications/" ~ applicationId.value.toString ~ "/commands",
            JSONValue(payload)
        );
        if (request.isErr)
            return Result!(ApplicationCommandDefinition[], string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(ApplicationCommandDefinition[], string).err(formatError("rest", "Discord returned an invalid bulk-overwrite response.", json.error));

        ApplicationCommandDefinition[] synced;
        foreach (item; json.value.array)
            synced ~= commandDefinitionFromJSON(item);
        return Result!(ApplicationCommandDefinition[], string).ok(synced);
    }

    Result!(User, string) currentUser()
    {
        auto request = perform(HttpMethod.Get, "GET:/users/@me", "/users/@me");
        if (request.isErr)
            return Result!(User, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(User, string).err(formatError("rest", "Discord returned an invalid current-user payload.", json.error));

        auto user = User.fromJSON(json.value);
        if (_resolvedApplicationId.isNull && user.id.value != 0)
            _resolvedApplicationId = Nullable!Snowflake.of(user.id);

        return Result!(User, string).ok(user);
    }

    Result!(GatewayBotInfo, string) gatewayBot()
    {
        auto request = perform(HttpMethod.Get, "GET:/gateway/bot", "/gateway/bot");
        if (request.isErr)
            return Result!(GatewayBotInfo, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(GatewayBotInfo, string).err(formatError("rest", "Discord returned an invalid gateway discovery payload.", json.error));

        GatewayBotInfo info;
        auto urlValue = json.value.object.get("url", JSONValue.init);
        if (urlValue.type != JSONType.null_)
            info.url = urlValue.str;

        auto shardsValue = json.value.object.get("shards", JSONValue.init);
        if (shardsValue.type != JSONType.null_)
            info.shards = cast(uint) shardsValue.integer;

        auto limitValue = json.value.object.get("session_start_limit", JSONValue.init);
        if (limitValue.type != JSONType.null_)
        {
            auto object = limitValue.object;
            auto total = object.get("total", JSONValue.init);
            auto remaining = object.get("remaining", JSONValue.init);
            auto resetAfter = object.get("reset_after", JSONValue.init);
            auto maxConcurrency = object.get("max_concurrency", JSONValue.init);

            if (total.type != JSONType.null_)
                info.sessionStartLimit.total = cast(uint) total.integer;
            if (remaining.type != JSONType.null_)
                info.sessionStartLimit.remaining = cast(uint) remaining.integer;
            if (resetAfter.type != JSONType.null_)
                info.sessionStartLimit.resetAfterMilliseconds = cast(uint) resetAfter.integer;
            if (maxConcurrency.type != JSONType.null_)
                info.sessionStartLimit.maxConcurrency = cast(uint) maxConcurrency.integer;
        }

        return Result!(GatewayBotInfo, string).ok(info);
    }

    Result!(bool, string) respondToInteraction(
        Snowflake interactionId,
        string interactionToken,
        InteractionCallbackType callbackType,
        MessageCreate payload = MessageCreate.init
    )
    {
        if (
            callbackType == InteractionCallbackType.ChannelMessageWithSource ||
            callbackType == InteractionCallbackType.ApplicationCommandAutocompleteResult
        )
        {
            auto validation = payload.validate();
            if (validation.isErr)
            {
                return Result!(bool, string).err(formatError(
                    "rest",
                    "Cannot send an interaction response.",
                    validation.error
                ));
            }
        }

        JSONValue body;
        body["type"] = cast(int) callbackType;
        if (
            callbackType == InteractionCallbackType.ChannelMessageWithSource ||
            callbackType == InteractionCallbackType.DeferredChannelMessageWithSource ||
            callbackType == InteractionCallbackType.ApplicationCommandAutocompleteResult
        )
            body["data"] = payload.toJSON();

        auto request = jsonRequest(
            HttpMethod.Post,
            "POST:/interactions/{interaction_id}/{interaction_token}/callback",
            "/interactions/" ~ interactionId.toString ~ "/" ~ interactionToken ~ "/callback",
            body,
            false
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    private Result!(HttpResponse, string) jsonRequest(
        HttpMethod method,
        string routeKey,
        string path,
        JSONValue payload,
        bool authenticated = true
    )
    {
        HttpRequest request;
        request.method = method;
        request.url = path;
        request.body = cast(ubyte[]) payload.toString.dup;
        request.contentType = "application/json";
        request.authenticated = authenticated;
        return performRequest(routeKey, request);
    }

    private Result!(HttpResponse, string) perform(
        HttpMethod method,
        string routeKey,
        string path
    )
    {
        HttpRequest request;
        request.method = method;
        request.url = path;
        return performRequest(routeKey, request);
    }

    private Result!(HttpResponse, string) performRequest(string routeKey, HttpRequest request)
    {
        uint attempts;

        while (true)
        {
            _limiter.acquire(routeKey);
            auto response = _http.send(request);

            if (response.isOk)
            {
                auto _ = _limiter.update(routeKey, response.value.statusCode, response.value.headers, response.value.text);
                return Result!(HttpResponse, string).ok(response.value);
            }

            auto outcome = _limiter.update(
                routeKey,
                response.error.statusCode,
                response.error.headers,
                response.error.responseBody
            );

            if (response.error.kind == HttpErrorKind.RateLimited && outcome.shouldRetry && attempts < 3)
            {
                attempts++;
                continue;
            }

            return Result!(HttpResponse, string).err(response.error.message);
        }
    }

    private Result!(Snowflake, string) resolveApplicationId()
    {
        if (!_resolvedApplicationId.isNull)
            return Result!(Snowflake, string).ok(_resolvedApplicationId.get);

        auto current = currentUser();
        if (current.isErr)
            return Result!(Snowflake, string).err(current.error);

        if (current.value.id.value == 0)
        {
            return Result!(Snowflake, string).err(formatError(
                "rest",
                "Could not determine the application ID for command synchronization.",
                "Discord returned a user payload without an `id` field.",
                "Set `ClientConfig.applicationId` explicitly if your deployment requires a non-standard application identifier."
            ));
        }

        _resolvedApplicationId = Nullable!Snowflake.of(current.value.id);
        return Result!(Snowflake, string).ok(current.value.id);
    }
}

private ApplicationCommandDefinition commandDefinitionFromJSON(JSONValue json)
{
    ApplicationCommandDefinition definition;

    auto nameValue = json.object.get("name", JSONValue.init);
    if (nameValue.type != JSONType.null_)
        definition.name = nameValue.str;

    auto descriptionValue = json.object.get("description", JSONValue.init);
    if (descriptionValue.type != JSONType.null_)
        definition.description = descriptionValue.str;

    auto typeValue = json.object.get("type", JSONValue.init);
    if (typeValue.type != JSONType.null_)
        definition.type = cast(typeof(definition.type)) cast(int) typeValue.integer;

    return definition;
}

/// Message endpoints surface.
final class MessagesEndpoints
{
    private MessageHistory _history;
    private Nullable!RealDiscordRest _real;

    this(MessageHistory history, Nullable!RealDiscordRest realTransport)
    {
        _history = history;
        _real = realTransport;
    }

    /// Creates a message in a channel.
    Task!Message create(Snowflake channelId, MessageCreate payload)
    {
        if (_real.isNull)
        {
            return Task!Message.failure(formatError(
                "rest",
                "Cannot create a Discord message because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/messages`.",
                "Configure a bot token or inject a transport before sending messages."
            ));
        }

        auto created = _real.get.createMessage(channelId, payload);
        if (created.isErr)
            return Task!Message.failure(created.error);

        _history.store(created.value);
        return Task!Message.success(created.value);
    }

    /// Returns every message sent through the REST client.
    Message[] history() @property
    {
        return _history.items;
    }

    /// Returns messages created in a specific channel.
    Message[] inChannel(Snowflake channelId)
    {
        return _history.inChannel(channelId);
    }
}

/// Application commands REST surface.
final class ApplicationCommandsEndpoints
{
    private ApplicationCommandStore _store;
    private Nullable!RealDiscordRest _real;

    this(ApplicationCommandStore store, Nullable!RealDiscordRest realTransport)
    {
        _store = store;
        _real = realTransport;
    }

    /// Replaces the global application command manifest.
    Task!(ApplicationCommandDefinition[]) bulkOverwrite(ApplicationCommandDefinition[] definitions)
    {
        if (_real.isNull)
            return Task!(ApplicationCommandDefinition[]).failure(formatError("rest", "Cannot overwrite application commands because the REST transport is not configured.", "", "Configure a bot token or inject a transport before syncing commands."));

        auto synced = _real.get.bulkOverwriteGlobalCommands(definitions);
        if (synced.isErr)
            return Task!(ApplicationCommandDefinition[]).failure(synced.error);

        _store.overwrite(synced.value);
        return Task!(ApplicationCommandDefinition[]).success(synced.value);
    }

    /// Lists globally registered application commands.
    Task!(ApplicationCommandDefinition[]) listGlobal()
    {
        if (_real.isNull)
            return Task!(ApplicationCommandDefinition[]).failure(formatError("rest", "Cannot list application commands because the REST transport is not configured.", "", "Configure a bot token or inject a transport before listing commands."));

        auto listed = _real.get.listGlobalCommands();
        if (listed.isErr)
            return Task!(ApplicationCommandDefinition[]).failure(listed.error);

        _store.overwrite(listed.value);
        return Task!(ApplicationCommandDefinition[]).success(listed.value);
    }

    /// Returns the last known command manifest.
    ApplicationCommandDefinition[] history() @property
    {
        return _store.items;
    }
}

/// Current user REST surface.
final class UsersEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Returns the current bot user.
    Task!User me()
    {
        if (_real.isNull)
            return Task!User.failure(formatError("rest", "Cannot call `/users/@me` because the REST transport is not configured.", "", "Provide a bot token or an explicit test transport before calling authenticated Discord endpoints."));

        auto user = _real.get.currentUser();
        if (user.isErr)
            return Task!User.failure(user.error);

        return Task!User.success(user.value);
    }
}

/// Gateway discovery REST surface.
final class GatewayEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Returns the recommended gateway URL and shard info.
    Task!GatewayBotInfo bot()
    {
        if (_real.isNull)
            return Task!GatewayBotInfo.failure(formatError("rest", "Cannot call `/gateway/bot` because the REST transport is not configured.", "", "Provide a bot token or an explicit test transport before gateway discovery."));

        auto info = _real.get.gatewayBot();
        if (info.isErr)
            return Task!GatewayBotInfo.failure(info.error);

        return Task!GatewayBotInfo.success(info.value);
    }
}

/// Interaction callback REST surface.
final class InteractionsEndpoints
{
    private MessageHistory _history;
    private Nullable!RealDiscordRest _real;

    this(MessageHistory history, Nullable!RealDiscordRest realTransport)
    {
        _history = history;
        _real = realTransport;
    }

    /// Sends the initial interaction response.
    Task!void respondMessage(Snowflake interactionId, string interactionToken, MessageCreate payload)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot respond to an interaction because the REST transport is not configured.", "", "Configure a bot token or inject a transport before replying to interactions."));

        auto sent = _real.get.respondToInteraction(
            interactionId,
            interactionToken,
            InteractionCallbackType.ChannelMessageWithSource,
            payload
        );
        if (sent.isErr)
            return Task!void.failure(sent.error);

        return Task!void.success();
    }

    /// Sends a deferred interaction acknowledgement.
    Task!void deferMessage(Snowflake interactionId, string interactionToken, bool ephemeral = false)
    {
        MessageCreate payload;
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot defer an interaction because the REST transport is not configured.", "", "Configure a bot token or inject a transport before deferring interactions."));

        auto sent = _real.get.respondToInteraction(
            interactionId,
            interactionToken,
            InteractionCallbackType.DeferredChannelMessageWithSource,
            payload
        );
        if (sent.isErr)
            return Task!void.failure(sent.error);

        return Task!void.success();
    }
}

/// REST client surface.
final class RestClient
{
    private RestClientConfig _config;
    private MessageHistory _history;
    private ApplicationCommandStore _commands;
    private Nullable!RealDiscordRest _real;
    MessagesEndpoints messages;
    ApplicationCommandsEndpoints applicationCommands;
    UsersEndpoints users;
    GatewayEndpoints gateway;
    InteractionsEndpoints interactions;
    LatencySample latency;

    this(RestClientConfig config = RestClientConfig.init)
    {
        _config = config;
        _history = new MessageHistory;
        _commands = new ApplicationCommandStore;

        if (config.token.length != 0 || !config.transport.isNull)
            _real = Nullable!RealDiscordRest.of(new RealDiscordRest(config));

        messages = new MessagesEndpoints(_history, _real);
        applicationCommands = new ApplicationCommandsEndpoints(_commands, _real);
        users = new UsersEndpoints(_real);
        gateway = new GatewayEndpoints(_real);
        interactions = new InteractionsEndpoints(_history, _real);
    }

    /// Returns whether this client is using the network-backed Discord REST implementation.
    bool isReal() const @property
    {
        return !_real.isNull;
    }
}

unittest
{
    HttpTransport transport = (request) {
        HttpResponse response;

        if (request.url.canFind("/users/@me"))
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"id":"42","username":"bot","bot":true}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.statusCode = 200;
        response.body = cast(ubyte[]) `[{"name":"ping","description":"Replies","type":1}]`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    ApplicationCommandDefinition ping;
    ping.name = "ping";
    ping.description = "Replies";

    auto synced = rest.applicationCommands.bulkOverwrite([ping]).await();
    assert(synced.length == 1);
    assert(rest.applicationCommands.history[0].name == "ping");
}

unittest
{
    HttpTransport transport = (request) {
        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"1","content":"hello","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto sent = rest.messages.create(Snowflake(1), MessageCreate("hello")).await();
    assert(sent.content == "hello");
    assert(rest.messages.history.length == 1);
}
