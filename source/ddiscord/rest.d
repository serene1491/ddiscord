/**
 * ddiscord — Discord REST client surface.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.rest;

import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.time : MonoTime;
import ddiscord.core.http.client : HttpClient, HttpClientConfig, HttpError, HttpErrorKind,
    HttpMethod, HttpRequest, HttpResponse, HttpTransport;
import ddiscord.core.http.multipart : MultipartPart, encodeMultipartFormData;
import ddiscord.core.rest.rate_limiter : RestRateLimiter;
import ddiscord.interactions.components : Modal, TextInput;
import ddiscord.models.application : Application;
import ddiscord.models.application_command : ApplicationCommandDefinition, AutocompleteChoice;
import ddiscord.models.channel : Channel, ChannelType;
import ddiscord.models.guild : Guild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message, MessageAttachmentCreate, MessageCreate, MessageFlags;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.tasks : Task;
import ddiscord.util.errors : formatError;
import ddiscord.util.identity : DdiscordUserAgent;
import ddiscord.util.limits : DiscordApiBase;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.algorithm : canFind;
import std.conv : to;
import std.datetime : Clock, Duration, dur;
import std.datetime.timezone : UTC;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;
import std.uri : encodeComponent;

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
    string userAgent = DdiscordUserAgent;
    Duration timeout = dur!"seconds"(15);
    bool autoRetryRateLimits = true;
    uint maxRateLimitRetries = 3;
    bool autoRetryServerErrors = true;
    uint maxServerErrorRetries = 3;
    Duration retryBaseDelay = dur!"msecs"(500);
    Duration maxRetryDelay = dur!"seconds"(30);
    Nullable!HttpTransport transport;
    LatencySample* latencyTarget;
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
    DeferredUpdateMessage = 6,
    UpdateMessage = 7,
    ApplicationCommandAutocompleteResult = 8,
    Modal = 9,
}

/// Current-user update payload.
struct ModifyCurrentUser
{
    Nullable!string username;
    Nullable!string avatar;
    Nullable!string banner;

    JSONValue toJSON() const
    {
        JSONValue json;
        if (!username.isNull)
            json["username"] = username.get;
        if (!avatar.isNull)
            json["avatar"] = avatar.get;
        if (!banner.isNull)
            json["banner"] = banner.get;
        return json;
    }
}

/// Current-application update payload.
struct ModifyCurrentApplication
{
    Nullable!string description;

    JSONValue toJSON() const
    {
        JSONValue json;
        if (!description.isNull)
            json["description"] = description.get;
        return json;
    }
}

private final class MessageHistory
{
    private Mutex _mutex;
    private Message[] _messages;
    private ulong _nextId = 1;

    this()
    {
        _mutex = new Mutex;
    }

    void store(Message message)
    {
        synchronized (_mutex)
        {
            if (message.id.value == 0)
                message.id = Snowflake(_nextId++);
            _messages ~= message;
        }
    }

    Message[] items()
    {
        synchronized (_mutex)
            return _messages.dup;
    }

    Message[] inChannel(Snowflake channelId)
    {
        Message[] items;
        synchronized (_mutex)
        {
            foreach (message; _messages)
            {
                if (message.channelId == channelId)
                    items ~= message;
            }
        }
        return items;
    }
}

private final class ApplicationCommandStore
{
    private Mutex _mutex;
    private ApplicationCommandDefinition[] _commands;

    this()
    {
        _mutex = new Mutex;
    }

    ApplicationCommandDefinition[] overwrite(ApplicationCommandDefinition[] definitions)
    {
        synchronized (_mutex)
        {
            _commands = definitions.dup;
            return _commands.dup;
        }
    }

    ApplicationCommandDefinition[] items()
    {
        synchronized (_mutex)
            return _commands.dup;
    }
}

private final class RealDiscordRest
{
    private RestClientConfig _config;
    private HttpClient _http;
    private RestRateLimiter _limiter;
    private Nullable!Snowflake _resolvedApplicationId;
    private LatencySample* _latencyTarget;

    this(RestClientConfig config)
    {
        _config = config;
        _latencyTarget = config.latencyTarget;

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

        auto request = messageRequest(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/messages",
            "/channels/" ~ channelId.toString ~ "/messages",
            payload
        );

        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned a message response that was not valid JSON.", json.error));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    Result!(Message, string) editMessage(Snowflake channelId, Snowflake messageId, MessageCreate payload)
    {
        auto validation = payload.validate();
        if (validation.isErr)
            return Result!(Message, string).err(formatError("rest", "Cannot edit a Discord message.", validation.error));

        auto request = messageRequest(
            HttpMethod.Patch,
            "PATCH:/channels/{channel_id}/messages/{message_id}",
            "/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString,
            payload
        );
        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned a message edit response that was not valid JSON.", json.error));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    Result!(bool, string) deleteMessage(Snowflake channelId, Snowflake messageId)
    {
        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{channel_id}/messages/{message_id}",
            "/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) bulkDeleteMessages(Snowflake channelId, Snowflake[] messageIds)
    {
        if (messageIds.length < 2 || messageIds.length > 100)
        {
            return Result!(bool, string).err(formatError(
                "rest",
                "Cannot bulk-delete messages with an invalid message-id count.",
                "Discord requires between 2 and 100 message ids. Current count: " ~ messageIds.length.to!string ~ ".",
                "Pass 2..100 message ids or call `deleteMessage` for single-message deletion."
            ));
        }

        JSONValue payload;
        JSONValue[] ids;
        foreach (messageId; messageIds)
            ids ~= JSONValue(messageId.toString);
        payload["messages"] = ids;

        auto request = jsonRequest(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/messages/bulk-delete",
            "/channels/" ~ channelId.toString ~ "/messages/bulk-delete",
            payload
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
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

    Result!(User, string) modifyCurrentUser(ModifyCurrentUser payload)
    {
        auto request = jsonRequest(
            HttpMethod.Patch,
            "PATCH:/users/@me",
            "/users/@me",
            payload.toJSON()
        );
        if (request.isErr)
            return Result!(User, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(User, string).err(formatError("rest", "Discord returned an invalid modified-user payload.", json.error));

        auto user = User.fromJSON(json.value);
        if (_resolvedApplicationId.isNull && user.id.value != 0)
            _resolvedApplicationId = Nullable!Snowflake.of(user.id);

        return Result!(User, string).ok(user);
    }

    Result!(Application, string) currentApplication()
    {
        auto request = perform(
            HttpMethod.Get,
            "GET:/oauth2/applications/@me",
            "/oauth2/applications/@me"
        );
        if (request.isErr)
            return Result!(Application, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Application, string).err(formatError("rest", "Discord returned an invalid current-application payload.", json.error));
        if (json.value.type != JSONType.object)
            return Result!(Application, string).err(formatError("rest", "Discord returned an invalid current-application payload.", "Expected a JSON object."));

        auto application = Application.fromJSON(json.value);
        if (application.id.value != 0)
            _resolvedApplicationId = Nullable!Snowflake.of(application.id);

        return Result!(Application, string).ok(application);
    }

    Result!(Application, string) modifyCurrentApplication(ModifyCurrentApplication payload)
    {
        auto request = jsonRequest(
            HttpMethod.Patch,
            "PATCH:/applications/@me",
            "/applications/@me",
            payload.toJSON()
        );
        if (request.isErr)
            return Result!(Application, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Application, string).err(formatError("rest", "Discord returned an invalid modified-application payload.", json.error));
        if (json.value.type != JSONType.object)
            return Result!(Application, string).err(formatError("rest", "Discord returned an invalid modified-application payload.", "Expected a JSON object."));

        auto application = Application.fromJSON(json.value);
        if (application.id.value != 0)
            _resolvedApplicationId = Nullable!Snowflake.of(application.id);

        return Result!(Application, string).ok(application);
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

    Result!(Guild, string) getGuild(Snowflake guildId)
    {
        auto request = perform(HttpMethod.Get, "GET:/guilds/{guild_id}", "/guilds/" ~ guildId.toString);
        if (request.isErr)
            return Result!(Guild, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Guild, string).err(formatError("rest", "Discord returned an invalid guild payload.", json.error));

        return Result!(Guild, string).ok(Guild.fromJSON(json.value));
    }

    Result!(GuildMember, string) getGuildMember(Snowflake guildId, Snowflake userId)
    {
        auto request = perform(
            HttpMethod.Get,
            "GET:/guilds/{guild_id}/members/{user_id}",
            "/guilds/" ~ guildId.toString ~ "/members/" ~ userId.toString
        );
        if (request.isErr)
            return Result!(GuildMember, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(GuildMember, string).err(formatError("rest", "Discord returned an invalid guild-member payload.", json.error));

        return Result!(GuildMember, string).ok(GuildMember.fromJSON(json.value));
    }

    Result!(Role[], string) listGuildRoles(Snowflake guildId)
    {
        auto request = perform(
            HttpMethod.Get,
            "GET:/guilds/{guild_id}/roles",
            "/guilds/" ~ guildId.toString ~ "/roles"
        );
        if (request.isErr)
            return Result!(Role[], string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Role[], string).err(formatError("rest", "Discord returned an invalid guild-role list.", json.error));

        Role[] roles;
        foreach (item; json.value.array)
            roles ~= Role.fromJSON(item);
        return Result!(Role[], string).ok(roles);
    }

    Result!(GuildMember, string) timeoutGuildMember(
        Snowflake guildId,
        Snowflake userId,
        Duration duration,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (duration <= Duration.zero || duration > maxDiscordMemberTimeoutDuration())
        {
            return Result!(GuildMember, string).err(formatError(
                "rest",
                "Cannot apply a guild-member timeout with an invalid duration.",
                "Discord accepts timeout durations in the range (0, 28 days].",
                "Use a positive duration up to 28 days."
            ));
        }

        JSONValue payload;
        payload["communication_disabled_until"] = (Clock.currTime(UTC()) + duration).toISOExtString();
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(GuildMember, string).err(headers.error);

        auto request = jsonRequest(
            HttpMethod.Patch,
            "PATCH:/guilds/{guild_id}/members/{user_id}",
            "/guilds/" ~ guildId.toString ~ "/members/" ~ userId.toString,
            payload,
            true,
            headers.value
        );
        if (request.isErr)
            return Result!(GuildMember, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(GuildMember, string).err(formatError("rest", "Discord returned an invalid guild-member timeout payload.", json.error));

        return Result!(GuildMember, string).ok(GuildMember.fromJSON(json.value));
    }

    Result!(GuildMember, string) clearGuildMemberTimeout(
        Snowflake guildId,
        Snowflake userId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        JSONValue payload;
        payload["communication_disabled_until"] = JSONValue.init;
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(GuildMember, string).err(headers.error);

        auto request = jsonRequest(
            HttpMethod.Patch,
            "PATCH:/guilds/{guild_id}/members/{user_id}",
            "/guilds/" ~ guildId.toString ~ "/members/" ~ userId.toString,
            payload,
            true,
            headers.value
        );
        if (request.isErr)
            return Result!(GuildMember, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(GuildMember, string).err(formatError("rest", "Discord returned an invalid guild-member timeout-clear payload.", json.error));

        return Result!(GuildMember, string).ok(GuildMember.fromJSON(json.value));
    }

    Result!(bool, string) kickGuildMember(
        Snowflake guildId,
        Snowflake userId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(bool, string).err(headers.error);

        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/guilds/{guild_id}/members/{user_id}",
            "/guilds/" ~ guildId.toString ~ "/members/" ~ userId.toString,
            headers.value
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) banGuildMember(
        Snowflake guildId,
        Snowflake userId,
        uint deleteMessageSeconds = 0,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (deleteMessageSeconds > 604_800)
        {
            return Result!(bool, string).err(formatError(
                "rest",
                "Cannot ban a guild member with an invalid `delete_message_seconds` value.",
                "Discord accepts values from 0 to 604800 seconds (7 days). Received: " ~ deleteMessageSeconds.to!string ~ ".",
                "Pass a value within 0..604800."
            ));
        }

        JSONValue payload;
        if (deleteMessageSeconds != 0)
            payload["delete_message_seconds"] = deleteMessageSeconds;
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(bool, string).err(headers.error);

        auto request = jsonRequest(
            HttpMethod.Put,
            "PUT:/guilds/{guild_id}/bans/{user_id}",
            "/guilds/" ~ guildId.toString ~ "/bans/" ~ userId.toString,
            payload,
            true,
            headers.value
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) unbanGuildMember(
        Snowflake guildId,
        Snowflake userId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(bool, string).err(headers.error);

        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/guilds/{guild_id}/bans/{user_id}",
            "/guilds/" ~ guildId.toString ~ "/bans/" ~ userId.toString,
            headers.value
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(Channel, string) getChannel(Snowflake channelId)
    {
        auto request = perform(HttpMethod.Get, "GET:/channels/{channel_id}", "/channels/" ~ channelId.toString);
        if (request.isErr)
            return Result!(Channel, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Channel, string).err(formatError("rest", "Discord returned an invalid channel payload.", json.error));

        return Result!(Channel, string).ok(Channel.fromJSON(json.value));
    }

    Result!(bool, string) triggerTypingIndicator(Snowflake channelId)
    {
        auto request = perform(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/typing",
            "/channels/" ~ channelId.toString ~ "/typing"
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(Message, string) crosspostMessage(Snowflake channelId, Snowflake messageId)
    {
        auto request = perform(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/messages/{message_id}/crosspost",
            "/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString ~ "/crosspost"
        );
        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned an invalid crosspost payload.", json.error));
        if (json.value.type != JSONType.object)
            return Result!(Message, string).err(formatError("rest", "Discord returned an invalid crosspost payload.", "Expected a JSON object."));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    Result!(bool, string) pinMessage(
        Snowflake channelId,
        Snowflake messageId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(bool, string).err(headers.error);

        auto request = perform(
            HttpMethod.Put,
            "PUT:/channels/{channel_id}/pins/{message_id}",
            "/channels/" ~ channelId.toString ~ "/pins/" ~ messageId.toString,
            headers.value
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) unpinMessage(
        Snowflake channelId,
        Snowflake messageId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        auto headers = buildAuditReasonHeaders(auditReason);
        if (headers.isErr)
            return Result!(bool, string).err(headers.error);

        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{channel_id}/pins/{message_id}",
            "/channels/" ~ channelId.toString ~ "/pins/" ~ messageId.toString,
            headers.value
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(Message[], string) listPinnedMessages(Snowflake channelId)
    {
        auto request = perform(
            HttpMethod.Get,
            "GET:/channels/{channel_id}/pins",
            "/channels/" ~ channelId.toString ~ "/pins"
        );
        if (request.isErr)
            return Result!(Message[], string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message[], string).err(formatError("rest", "Discord returned an invalid pinned-message list payload.", json.error));
        if (json.value.type != JSONType.array)
            return Result!(Message[], string).err(formatError("rest", "Discord returned an invalid pinned-message list payload.", "Expected a JSON array."));

        Message[] messages;
        foreach (item; json.value.array)
            messages ~= Message.fromJSON(item);
        return Result!(Message[], string).ok(messages);
    }

    Result!(Channel, string) createThreadFromMessage(
        Snowflake channelId,
        Snowflake messageId,
        string name,
        ushort autoArchiveMinutes = 1440,
        uint rateLimitPerUser = 0
    )
    {
        auto normalizedName = normalizeThreadName(name);
        if (normalizedName.isNull)
        {
            return Result!(Channel, string).err(formatError(
                "rest",
                "Cannot create a thread with an empty name.",
                "",
                "Provide a non-empty thread name."
            ));
        }

        if (!isValidAutoArchiveDuration(autoArchiveMinutes))
        {
            return Result!(Channel, string).err(formatError(
                "rest",
                "Cannot create a thread with an unsupported auto-archive duration.",
                "Supported values are 60, 1440, 4320, and 10080 minutes. Received: " ~ autoArchiveMinutes.to!string ~ "."
            ));
        }

        JSONValue payload;
        payload["name"] = normalizedName.get;
        payload["auto_archive_duration"] = autoArchiveMinutes;
        if (rateLimitPerUser != 0)
            payload["rate_limit_per_user"] = rateLimitPerUser;

        auto request = jsonRequest(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/messages/{message_id}/threads",
            "/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString ~ "/threads",
            payload
        );
        if (request.isErr)
            return Result!(Channel, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Channel, string).err(formatError("rest", "Discord returned an invalid thread-create payload.", json.error));

        return Result!(Channel, string).ok(Channel.fromJSON(json.value));
    }

    Result!(Channel, string) createThread(
        Snowflake channelId,
        string name,
        ChannelType type = ChannelType.PublicThread,
        ushort autoArchiveMinutes = 1440,
        bool invitable = true,
        uint rateLimitPerUser = 0
    )
    {
        auto normalizedName = normalizeThreadName(name);
        if (normalizedName.isNull)
        {
            return Result!(Channel, string).err(formatError(
                "rest",
                "Cannot create a thread with an empty name.",
                "",
                "Provide a non-empty thread name."
            ));
        }

        if (!isThreadCreateTypeAllowed(type))
        {
            return Result!(Channel, string).err(formatError(
                "rest",
                "Cannot create a thread with an unsupported channel type.",
                "Allowed thread types are AnnouncementThread, PublicThread, and PrivateThread."
            ));
        }

        if (!isValidAutoArchiveDuration(autoArchiveMinutes))
        {
            return Result!(Channel, string).err(formatError(
                "rest",
                "Cannot create a thread with an unsupported auto-archive duration.",
                "Supported values are 60, 1440, 4320, and 10080 minutes. Received: " ~ autoArchiveMinutes.to!string ~ "."
            ));
        }

        JSONValue payload;
        payload["name"] = normalizedName.get;
        payload["auto_archive_duration"] = autoArchiveMinutes;
        payload["type"] = cast(int) type;
        if (type == ChannelType.PrivateThread)
            payload["invitable"] = invitable;
        if (rateLimitPerUser != 0)
            payload["rate_limit_per_user"] = rateLimitPerUser;

        auto request = jsonRequest(
            HttpMethod.Post,
            "POST:/channels/{channel_id}/threads",
            "/channels/" ~ channelId.toString ~ "/threads",
            payload
        );
        if (request.isErr)
            return Result!(Channel, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Channel, string).err(formatError("rest", "Discord returned an invalid thread-create payload.", json.error));

        return Result!(Channel, string).ok(Channel.fromJSON(json.value));
    }

    Result!(bool, string) joinThread(Snowflake threadId)
    {
        auto request = perform(
            HttpMethod.Put,
            "PUT:/channels/{thread_id}/thread-members/@me",
            "/channels/" ~ threadId.toString ~ "/thread-members/@me"
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) leaveThread(Snowflake threadId)
    {
        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{thread_id}/thread-members/@me",
            "/channels/" ~ threadId.toString ~ "/thread-members/@me"
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(Channel, string) archiveThread(
        Snowflake threadId,
        bool archived = true,
        bool locked = false
    )
    {
        JSONValue payload;
        payload["archived"] = archived;
        payload["locked"] = locked;

        auto request = jsonRequest(
            HttpMethod.Patch,
            "PATCH:/channels/{thread_id}",
            "/channels/" ~ threadId.toString,
            payload
        );
        if (request.isErr)
            return Result!(Channel, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Channel, string).err(formatError("rest", "Discord returned an invalid thread-update payload.", json.error));

        return Result!(Channel, string).ok(Channel.fromJSON(json.value));
    }

    Result!(bool, string) addReaction(Snowflake channelId, Snowflake messageId, string emoji)
    {
        auto routeEmoji = reactionEmojiPath(emoji);
        if (routeEmoji.isErr)
            return Result!(bool, string).err(routeEmoji.error);

        auto request = perform(
            HttpMethod.Put,
            "PUT:/channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me",
            "/channels/" ~ channelId.toString ~
                "/messages/" ~ messageId.toString ~
                "/reactions/" ~ routeEmoji.value ~ "/@me"
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) removeOwnReaction(Snowflake channelId, Snowflake messageId, string emoji)
    {
        auto routeEmoji = reactionEmojiPath(emoji);
        if (routeEmoji.isErr)
            return Result!(bool, string).err(routeEmoji.error);

        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me",
            "/channels/" ~ channelId.toString ~
                "/messages/" ~ messageId.toString ~
                "/reactions/" ~ routeEmoji.value ~ "/@me"
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) removeUserReaction(
        Snowflake channelId,
        Snowflake messageId,
        string emoji,
        Snowflake userId
    )
    {
        auto routeEmoji = reactionEmojiPath(emoji);
        if (routeEmoji.isErr)
            return Result!(bool, string).err(routeEmoji.error);

        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{channel_id}/messages/{message_id}/reactions/{emoji}/{user_id}",
            "/channels/" ~ channelId.toString ~
                "/messages/" ~ messageId.toString ~
                "/reactions/" ~ routeEmoji.value ~ "/" ~ userId.toString
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) clearReactions(Snowflake channelId, Snowflake messageId)
    {
        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{channel_id}/messages/{message_id}/reactions",
            "/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString ~ "/reactions"
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) clearEmojiReactions(Snowflake channelId, Snowflake messageId, string emoji)
    {
        auto routeEmoji = reactionEmojiPath(emoji);
        if (routeEmoji.isErr)
            return Result!(bool, string).err(routeEmoji.error);

        auto request = perform(
            HttpMethod.Delete,
            "DELETE:/channels/{channel_id}/messages/{message_id}/reactions/{emoji}",
            "/channels/" ~ channelId.toString ~
                "/messages/" ~ messageId.toString ~
                "/reactions/" ~ routeEmoji.value
        );
        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) respondToInteraction(
        Snowflake interactionId,
        string interactionToken,
        InteractionCallbackType callbackType,
        MessageCreate payload = MessageCreate.init
    )
    {
        auto encodedInteractionToken = encodeRouteToken(interactionToken, "interaction token");
        if (encodedInteractionToken.isErr)
            return Result!(bool, string).err(encodedInteractionToken.error);

        if (
            callbackType == InteractionCallbackType.ChannelMessageWithSource ||
            callbackType == InteractionCallbackType.UpdateMessage ||
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
            callbackType == InteractionCallbackType.UpdateMessage ||
            callbackType == InteractionCallbackType.ApplicationCommandAutocompleteResult
        )
            body["data"] = payload.toJSON();

        Result!(HttpResponse, string) request;
        if (payload.hasAttachments)
        {
            if (
                callbackType != InteractionCallbackType.ChannelMessageWithSource &&
                callbackType != InteractionCallbackType.UpdateMessage
            )
            {
                return Result!(bool, string).err(formatError(
                    "rest",
                    "Cannot send this interaction response with attachments.",
                    "Attachments are only supported for message-producing callbacks (type 4 or type 7)."
                ));
            }

            request = multipartJsonWithFilesRequest(
                HttpMethod.Post,
                "POST:/interactions/{interaction_id}/{interaction_token}/callback",
                "/interactions/" ~ interactionId.toString ~ "/" ~ encodedInteractionToken.value ~ "/callback",
                body,
                payload.files,
                false
            );
        }
        else
        {
            request = jsonRequest(
                HttpMethod.Post,
                "POST:/interactions/{interaction_id}/{interaction_token}/callback",
                "/interactions/" ~ interactionId.toString ~ "/" ~ encodedInteractionToken.value ~ "/callback",
                body,
                false
            );
        }

        if (request.isErr)
            return Result!(bool, string).err(request.error);

        return Result!(bool, string).ok(true);
    }

    Result!(bool, string) respondAutocomplete(
        Snowflake interactionId,
        string interactionToken,
        AutocompleteChoice[] choices
    )
    {
        JSONValue body;
        body["type"] = cast(int) InteractionCallbackType.ApplicationCommandAutocompleteResult;

        JSONValue data;
        JSONValue[] choiceValues;
        foreach (choice; choices)
        {
            JSONValue jsonChoice;
            jsonChoice["name"] = choice.name;
            jsonChoice["value"] = choice.value;
            choiceValues ~= jsonChoice;
        }
        data["choices"] = choiceValues;
        body["data"] = data;

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

    Result!(bool, string) respondWithModal(
        Snowflake interactionId,
        string interactionToken,
        Modal modal
    )
    {
        JSONValue body;
        body["type"] = cast(int) InteractionCallbackType.Modal;
        body["data"] = modal.toJSON();

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

    Result!(Message, string) createFollowupMessage(string interactionToken, MessageCreate payload)
    {
        auto encodedInteractionToken = encodeRouteToken(interactionToken, "interaction token");
        if (encodedInteractionToken.isErr)
            return Result!(Message, string).err(encodedInteractionToken.error);

        auto validation = payload.validate();
        if (validation.isErr)
            return Result!(Message, string).err(formatError("rest", "Cannot create an interaction follow-up message.", validation.error));

        auto applicationId = resolveApplicationId();
        if (applicationId.isErr)
            return Result!(Message, string).err(applicationId.error);

        auto request = messageRequest(
            HttpMethod.Post,
            "POST:/webhooks/{application_id}/{interaction_token}",
            "/webhooks/" ~ applicationId.value.toString ~ "/" ~ encodedInteractionToken.value,
            payload,
            false
        );
        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned an invalid interaction follow-up payload.", json.error));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    Result!(Message, string) editOriginalInteractionResponse(string interactionToken, MessageCreate payload)
    {
        auto encodedInteractionToken = encodeRouteToken(interactionToken, "interaction token");
        if (encodedInteractionToken.isErr)
            return Result!(Message, string).err(encodedInteractionToken.error);

        auto validation = payload.validate();
        if (validation.isErr)
            return Result!(Message, string).err(formatError("rest", "Cannot edit the original interaction response.", validation.error));

        auto applicationId = resolveApplicationId();
        if (applicationId.isErr)
            return Result!(Message, string).err(applicationId.error);

        auto request = messageRequest(
            HttpMethod.Patch,
            "PATCH:/webhooks/{application_id}/{interaction_token}/messages/@original",
            "/webhooks/" ~ applicationId.value.toString ~ "/" ~ encodedInteractionToken.value ~ "/messages/@original",
            payload,
            false
        );
        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned an invalid original-response edit payload.", json.error));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    Result!(Message, string) executeWebhookMessage(
        Snowflake webhookId,
        string webhookToken,
        MessageCreate payload,
        Nullable!Snowflake threadId = Nullable!Snowflake.init
    )
    {
        auto encodedWebhookToken = encodeRouteToken(webhookToken, "webhook token");
        if (encodedWebhookToken.isErr)
            return Result!(Message, string).err(encodedWebhookToken.error);

        auto validation = payload.validate();
        if (validation.isErr)
            return Result!(Message, string).err(formatError("rest", "Cannot execute a Discord webhook message.", validation.error));

        auto path = webhookExecutePath(webhookId, encodedWebhookToken.value, threadId);
        auto request = messageRequest(
            HttpMethod.Post,
            "POST:/webhooks/{webhook_id}/{webhook_token}",
            path,
            payload,
            false
        );
        if (request.isErr)
            return Result!(Message, string).err(request.error);

        auto json = request.value.json();
        if (json.isErr)
            return Result!(Message, string).err(formatError("rest", "Discord returned an invalid webhook execute payload.", json.error));

        return Result!(Message, string).ok(Message.fromJSON(json.value));
    }

    private Result!(HttpResponse, string) jsonRequest(
        HttpMethod method,
        string routeKey,
        string path,
        JSONValue payload,
        bool authenticated = true,
        string[string] headers = null
    )
    {
        HttpRequest request;
        request.method = method;
        request.url = path;
        request.body = cast(ubyte[]) payload.toString.dup;
        request.contentType = "application/json";
        request.authenticated = authenticated;
        request.headers = headers.dup;
        return performRequest(routeKey, request);
    }

    private Result!(HttpResponse, string) messageRequest(
        HttpMethod method,
        string routeKey,
        string path,
        MessageCreate payload,
        bool authenticated = true,
        string[string] headers = null
    )
    {
        if (!payload.hasAttachments)
            return jsonRequest(method, routeKey, path, payload.toJSON(), authenticated, headers);

        return multipartJsonWithFilesRequest(
            method,
            routeKey,
            path,
            payload.toJSON(),
            payload.files,
            authenticated,
            headers
        );
    }

    private Result!(HttpResponse, string) multipartJsonWithFilesRequest(
        HttpMethod method,
        string routeKey,
        string path,
        JSONValue payload,
        MessageAttachmentCreate[] files,
        bool authenticated = true,
        string[string] headers = null
    )
    {
        MultipartPart[] parts;
        parts ~= MultipartPart.text("payload_json", payload.toString(), "application/json");

        foreach (index, file; files)
        {
            auto partName = "files[" ~ index.to!string ~ "]";
            auto contentType = file.contentType.length == 0 ? "application/octet-stream" : file.contentType;
            parts ~= MultipartPart.file(partName, file.filename, file.data, contentType);
        }

        auto encoded = encodeMultipartFormData(parts);

        HttpRequest request;
        request.method = method;
        request.url = path;
        request.body = encoded.body;
        request.contentType = encoded.contentType;
        request.authenticated = authenticated;
        request.headers = headers.dup;
        return performRequest(routeKey, request);
    }

    private Result!(HttpResponse, string) perform(
        HttpMethod method,
        string routeKey,
        string path,
        string[string] headers = null
    )
    {
        HttpRequest request;
        request.method = method;
        request.url = path;
        request.headers = headers.dup;
        return performRequest(routeKey, request);
    }

    private Result!(HttpResponse, string) performRequest(string routeKey, HttpRequest request)
    {
        uint rateLimitRetries;
        uint serverErrorRetries;
        auto retryDelay = _config.retryBaseDelay;

        while (true)
        {
            auto startedAt = MonoTime.currTime;
            _limiter.acquire(routeKey);
            auto response = _http.send(request);
            recordLatency(startedAt);

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

            if (
                _config.autoRetryRateLimits &&
                response.error.kind == HttpErrorKind.RateLimited &&
                outcome.shouldRetry &&
                rateLimitRetries < _config.maxRateLimitRetries
            )
            {
                rateLimitRetries++;
                continue;
            }

            if (
                _config.autoRetryServerErrors &&
                shouldRetryServerError(response.error.kind) &&
                serverErrorRetries < _config.maxServerErrorRetries
            )
            {
                serverErrorRetries++;
                if (retryDelay > Duration.zero)
                    Thread.sleep(retryDelay);
                retryDelay = nextRetryDelay(retryDelay, _config.maxRetryDelay);
                continue;
            }

            return Result!(HttpResponse, string).err(response.error.message);
        }
    }

    private void recordLatency(MonoTime startedAt)
    {
        if (_latencyTarget is null)
            return;
        (*_latencyTarget).milliseconds = (MonoTime.currTime - startedAt).total!"msecs";
    }

    private Result!(Snowflake, string) resolveApplicationId()
    {
        if (!_resolvedApplicationId.isNull)
            return Result!(Snowflake, string).ok(_resolvedApplicationId.get);

        auto currentApplication = currentApplication();
        if (currentApplication.isOk && currentApplication.value.id.value != 0)
            return Result!(Snowflake, string).ok(currentApplication.value.id);

        auto currentUser = currentUser();
        if (currentUser.isErr)
            return Result!(Snowflake, string).err(currentUser.error);

        if (currentUser.value.id.value == 0)
        {
            return Result!(Snowflake, string).err(formatError(
                "rest",
                "Could not determine the application ID for command synchronization.",
                "Discord returned neither an application payload nor a user payload with an `id` field.",
                "Set `ClientConfig.applicationId` explicitly if your deployment requires a non-standard application identifier."
            ));
        }

        _resolvedApplicationId = Nullable!Snowflake.of(currentUser.value.id);
        return Result!(Snowflake, string).ok(currentUser.value.id);
    }

    private Result!(string, string) reactionEmojiPath(string emoji) const
    {
        auto trimmed = emoji.strip;
        if (trimmed.length == 0)
        {
            return Result!(string, string).err(formatError(
                "rest",
                "Cannot use an empty reaction emoji.",
                "",
                "Pass either a unicode emoji (for example `✅`) or a custom emoji in `name:id` format."
            ));
        }

        return Result!(string, string).ok(trimmed.encodeComponent());
    }

    private static Duration maxDiscordMemberTimeoutDuration()
    {
        return dur!"days"(28);
    }

    private static bool isValidAutoArchiveDuration(ushort minutes)
    {
        return minutes == 60 || minutes == 1_440 || minutes == 4_320 || minutes == 10_080;
    }

    private static bool isThreadCreateTypeAllowed(ChannelType type)
    {
        return type == ChannelType.AnnouncementThread ||
            type == ChannelType.PublicThread ||
            type == ChannelType.PrivateThread;
    }

    private static Nullable!string normalizeThreadName(string name)
    {
        auto trimmed = name.strip;
        if (trimmed.length == 0)
            return Nullable!string.init;

        if (trimmed.length > 100)
            trimmed = trimmed[0 .. 100];

        return Nullable!string.of(trimmed);
    }

    private string webhookExecutePath(
        Snowflake webhookId,
        string webhookToken,
        Nullable!Snowflake threadId
    ) const
    {
        auto path = "/webhooks/" ~ webhookId.toString ~ "/" ~ webhookToken ~ "?wait=true";
        if (!threadId.isNull)
            path ~= "&thread_id=" ~ threadId.get.toString;
        return path;
    }

    private Result!(string[string], string) buildAuditReasonHeaders(Nullable!string auditReason) const
    {
        string[string] headers;
        if (auditReason.isNull)
            return Result!(string[string], string).ok(headers);

        auto reason = normalizeAuditReason(auditReason.get);
        if (reason.isErr)
            return Result!(string[string], string).err(reason.error);
        if (reason.value.isNull)
            return Result!(string[string], string).ok(headers);

        headers["X-Audit-Log-Reason"] = reason.value.get;
        return Result!(string[string], string).ok(headers);
    }

    private Result!(Nullable!string, string) normalizeAuditReason(string rawReason) const
    {
        char[] sanitized;
        foreach (ch; rawReason)
        {
            if (ch == '\r' || ch == '\n')
                continue;
            sanitized ~= ch;
        }

        auto cleaned = sanitized.idup.strip;
        if (cleaned.length == 0)
            return Result!(Nullable!string, string).ok(Nullable!string.init);
        if (cleaned.length > 512)
        {
            return Result!(Nullable!string, string).err(formatError(
                "rest",
                "Cannot use an audit-log reason longer than Discord allows.",
                "Discord accepts audit log reasons up to 512 characters. Current length: " ~ cleaned.length.to!string ~ ".",
                "Provide a shorter reason."
            ));
        }

        return Result!(Nullable!string, string).ok(Nullable!string.of(cleaned.encodeComponent()));
    }

    private Result!(string, string) encodeRouteToken(string token, string fieldName) const
    {
        auto trimmed = token.strip;
        if (trimmed.length == 0)
        {
            return Result!(string, string).err(formatError(
                "rest",
                "Cannot call this Discord route with an empty token.",
                "Missing required " ~ fieldName ~ ".",
                "Pass a non-empty token value from the interaction or webhook payload."
            ));
        }

        return Result!(string, string).ok(trimmed.encodeComponent());
    }
}

private bool shouldRetryServerError(HttpErrorKind kind)
{
    return kind == HttpErrorKind.Server ||
        kind == HttpErrorKind.Timeout ||
        kind == HttpErrorKind.Transport;
}

private Duration nextRetryDelay(Duration delay, Duration maxDelay)
{
    if (delay <= Duration.zero)
        return delay;

    auto doubled = delay + delay;
    if (maxDelay <= Duration.zero || doubled <= maxDelay)
        return doubled;
    return maxDelay;
}

private ApplicationCommandDefinition commandDefinitionFromJSON(JSONValue json)
{
    return ApplicationCommandDefinition.fromJSON(json);
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

    /// Edits an existing message in a channel.
    Task!Message edit(Snowflake channelId, Snowflake messageId, MessageCreate payload)
    {
        if (_real.isNull)
        {
            return Task!Message.failure(formatError(
                "rest",
                "Cannot edit a Discord message because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString ~ "`.",
                "Configure a bot token or inject a transport before editing messages."
            ));
        }

        auto edited = _real.get.editMessage(channelId, messageId, payload);
        if (edited.isErr)
            return Task!Message.failure(edited.error);

        _history.store(edited.value);
        return Task!Message.success(edited.value);
    }

    /// Deletes one message from a channel.
    Task!void delete(Snowflake channelId, Snowflake messageId)
    {
        if (_real.isNull)
        {
            return Task!void.failure(formatError(
                "rest",
                "Cannot delete a Discord message because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString ~ "`.",
                "Configure a bot token or inject a transport before deleting messages."
            ));
        }

        auto deleted = _real.get.deleteMessage(channelId, messageId);
        if (deleted.isErr)
            return Task!void.failure(deleted.error);

        return Task!void.success();
    }

    /// Deletes between 2 and 100 messages from a channel.
    Task!void bulkDelete(Snowflake channelId, Snowflake[] messageIds)
    {
        if (_real.isNull)
        {
            return Task!void.failure(formatError(
                "rest",
                "Cannot bulk-delete Discord messages because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/messages/bulk-delete`.",
                "Configure a bot token or inject a transport before bulk-deleting messages."
            ));
        }

        auto deleted = _real.get.bulkDeleteMessages(channelId, messageIds);
        if (deleted.isErr)
            return Task!void.failure(deleted.error);

        return Task!void.success();
    }

    /// Crossposts a message in announcement channels.
    Task!Message crosspost(Snowflake channelId, Snowflake messageId)
    {
        if (_real.isNull)
        {
            return Task!Message.failure(formatError(
                "rest",
                "Cannot crosspost a Discord message because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/messages/" ~ messageId.toString ~ "/crosspost`.",
                "Configure a bot token or inject a transport before crossposting messages."
            ));
        }

        auto crossposted = _real.get.crosspostMessage(channelId, messageId);
        if (crossposted.isErr)
            return Task!Message.failure(crossposted.error);

        _history.store(crossposted.value);
        return Task!Message.success(crossposted.value);
    }

    /// Pins a message in a channel.
    Task!void pin(
        Snowflake channelId,
        Snowflake messageId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
        {
            return Task!void.failure(formatError(
                "rest",
                "Cannot pin a Discord message because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/pins/" ~ messageId.toString ~ "`.",
                "Configure a bot token or inject a transport before pinning messages."
            ));
        }

        auto pinned = _real.get.pinMessage(channelId, messageId, auditReason);
        if (pinned.isErr)
            return Task!void.failure(pinned.error);

        return Task!void.success();
    }

    /// Unpins a message in a channel.
    Task!void unpin(
        Snowflake channelId,
        Snowflake messageId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
        {
            return Task!void.failure(formatError(
                "rest",
                "Cannot unpin a Discord message because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/pins/" ~ messageId.toString ~ "`.",
                "Configure a bot token or inject a transport before unpinning messages."
            ));
        }

        auto unpinned = _real.get.unpinMessage(channelId, messageId, auditReason);
        if (unpinned.isErr)
            return Task!void.failure(unpinned.error);

        return Task!void.success();
    }

    /// Lists pinned messages in a channel.
    Task!(Message[]) pins(Snowflake channelId)
    {
        if (_real.isNull)
        {
            return Task!(Message[]).failure(formatError(
                "rest",
                "Cannot list pinned Discord messages because the REST transport is not configured.",
                "Attempted route: `/channels/" ~ channelId.toString ~ "/pins`.",
                "Configure a bot token or inject a transport before reading pinned messages."
            ));
        }

        auto pinned = _real.get.listPinnedMessages(channelId);
        if (pinned.isErr)
            return Task!(Message[]).failure(pinned.error);

        return Task!(Message[]).success(pinned.value);
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

/// Message reaction REST surface.
final class ReactionsEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Adds a reaction as the current bot user.
    Task!void add(Snowflake channelId, Snowflake messageId, string emoji)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot add a reaction because the REST transport is not configured.", "", "Provide a bot token or a transport before managing reactions."));

        auto added = _real.get.addReaction(channelId, messageId, emoji);
        if (added.isErr)
            return Task!void.failure(added.error);

        return Task!void.success();
    }

    /// Removes the current bot user's reaction.
    Task!void removeSelf(Snowflake channelId, Snowflake messageId, string emoji)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot remove the bot reaction because the REST transport is not configured.", "", "Provide a bot token or a transport before managing reactions."));

        auto removed = _real.get.removeOwnReaction(channelId, messageId, emoji);
        if (removed.isErr)
            return Task!void.failure(removed.error);

        return Task!void.success();
    }

    /// Removes a specific user's reaction.
    Task!void removeUser(Snowflake channelId, Snowflake messageId, string emoji, Snowflake userId)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot remove a user's reaction because the REST transport is not configured.", "", "Provide a bot token or a transport before managing reactions."));

        auto removed = _real.get.removeUserReaction(channelId, messageId, emoji, userId);
        if (removed.isErr)
            return Task!void.failure(removed.error);

        return Task!void.success();
    }

    /// Clears all reactions from a message.
    Task!void clear(Snowflake channelId, Snowflake messageId)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot clear reactions because the REST transport is not configured.", "", "Provide a bot token or a transport before managing reactions."));

        auto cleared = _real.get.clearReactions(channelId, messageId);
        if (cleared.isErr)
            return Task!void.failure(cleared.error);

        return Task!void.success();
    }

    /// Clears all reactions for one emoji from a message.
    Task!void clearEmoji(Snowflake channelId, Snowflake messageId, string emoji)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot clear emoji reactions because the REST transport is not configured.", "", "Provide a bot token or a transport before managing reactions."));

        auto cleared = _real.get.clearEmojiReactions(channelId, messageId, emoji);
        if (cleared.isErr)
            return Task!void.failure(cleared.error);

        return Task!void.success();
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

    /// Short alias for `bulkOverwrite`.
    Task!(ApplicationCommandDefinition[]) sync(ApplicationCommandDefinition[] definitions)
    {
        return bulkOverwrite(definitions);
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

    /// Short alias for `listGlobal`.
    Task!(ApplicationCommandDefinition[]) list()
    {
        return listGlobal();
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

    /// Updates the current bot user.
    Task!User update(ModifyCurrentUser payload)
    {
        if (_real.isNull)
            return Task!User.failure(formatError("rest", "Cannot call `PATCH /users/@me` because the REST transport is not configured.", "", "Provide a bot token or an explicit test transport before calling authenticated Discord endpoints."));

        auto user = _real.get.modifyCurrentUser(payload);
        if (user.isErr)
            return Task!User.failure(user.error);

        return Task!User.success(user.value);
    }
}

/// Current application REST surface.
final class ApplicationsEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Returns the current Discord application.
    Task!Application me()
    {
        if (_real.isNull)
            return Task!Application.failure(formatError("rest", "Cannot call `GET /oauth2/applications/@me` because the REST transport is not configured.", "", "Provide a bot token or an explicit test transport before calling authenticated Discord endpoints."));

        auto application = _real.get.currentApplication();
        if (application.isErr)
            return Task!Application.failure(application.error);

        return Task!Application.success(application.value);
    }

    /// Updates the current Discord application.
    Task!Application update(ModifyCurrentApplication payload)
    {
        if (_real.isNull)
            return Task!Application.failure(formatError("rest", "Cannot call `PATCH /applications/@me` because the REST transport is not configured.", "", "Provide a bot token or an explicit test transport before calling authenticated Discord endpoints."));

        auto application = _real.get.modifyCurrentApplication(payload);
        if (application.isErr)
            return Task!Application.failure(application.error);

        return Task!Application.success(application.value);
    }

    /// Short alias for `me`.
    Task!Application current()
    {
        return me();
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

/// Guild-related REST surface.
final class GuildsEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Returns a guild descriptor by id.
    Task!Guild get(Snowflake guildId)
    {
        if (_real.isNull)
            return Task!Guild.failure(formatError("rest", "Cannot fetch a guild because the REST transport is not configured.", "", "Provide a bot token or a transport before reading guild metadata."));

        auto guild = _real.get.getGuild(guildId);
        if (guild.isErr)
            return Task!Guild.failure(guild.error);

        return Task!Guild.success(guild.value);
    }

    /// Returns a guild member descriptor by guild and user id.
    Task!GuildMember member(Snowflake guildId, Snowflake userId)
    {
        if (_real.isNull)
            return Task!GuildMember.failure(formatError("rest", "Cannot fetch a guild member because the REST transport is not configured.", "", "Provide a bot token or a transport before reading guild members."));

        auto member = _real.get.getGuildMember(guildId, userId);
        if (member.isErr)
            return Task!GuildMember.failure(member.error);

        return Task!GuildMember.success(member.value);
    }

    /// Lists the roles for a guild.
    Task!(Role[]) roles(Snowflake guildId)
    {
        if (_real.isNull)
            return Task!(Role[]).failure(formatError("rest", "Cannot list guild roles because the REST transport is not configured.", "", "Provide a bot token or a transport before reading guild roles."));

        auto roles = _real.get.listGuildRoles(guildId);
        if (roles.isErr)
            return Task!(Role[]).failure(roles.error);

        return Task!(Role[]).success(roles.value);
    }

    /// Applies a timeout to a guild member for the provided duration.
    Task!GuildMember timeoutMember(
        Snowflake guildId,
        Snowflake userId,
        Duration duration,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
            return Task!GuildMember.failure(formatError("rest", "Cannot timeout a guild member because the REST transport is not configured.", "", "Provide a bot token or a transport before moderating guild members."));

        auto updated = _real.get.timeoutGuildMember(guildId, userId, duration, auditReason);
        if (updated.isErr)
            return Task!GuildMember.failure(updated.error);

        return Task!GuildMember.success(updated.value);
    }

    /// Clears timeout state for a guild member.
    Task!GuildMember clearMemberTimeout(
        Snowflake guildId,
        Snowflake userId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
            return Task!GuildMember.failure(formatError("rest", "Cannot clear a guild member timeout because the REST transport is not configured.", "", "Provide a bot token or a transport before moderating guild members."));

        auto updated = _real.get.clearGuildMemberTimeout(guildId, userId, auditReason);
        if (updated.isErr)
            return Task!GuildMember.failure(updated.error);

        return Task!GuildMember.success(updated.value);
    }

    /// Removes a member from the guild.
    Task!void kick(
        Snowflake guildId,
        Snowflake userId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot kick a guild member because the REST transport is not configured.", "", "Provide a bot token or a transport before moderating guild members."));

        auto kicked = _real.get.kickGuildMember(guildId, userId, auditReason);
        if (kicked.isErr)
            return Task!void.failure(kicked.error);

        return Task!void.success();
    }

    /// Bans a member from the guild.
    Task!void ban(
        Snowflake guildId,
        Snowflake userId,
        uint deleteMessageSeconds = 0,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot ban a guild member because the REST transport is not configured.", "", "Provide a bot token or a transport before moderating guild members."));

        auto banned = _real.get.banGuildMember(guildId, userId, deleteMessageSeconds, auditReason);
        if (banned.isErr)
            return Task!void.failure(banned.error);

        return Task!void.success();
    }

    /// Removes a ban for a guild member.
    Task!void unban(
        Snowflake guildId,
        Snowflake userId,
        Nullable!string auditReason = Nullable!string.init
    )
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot unban a guild member because the REST transport is not configured.", "", "Provide a bot token or a transport before moderating guild members."));

        auto unbanned = _real.get.unbanGuildMember(guildId, userId, auditReason);
        if (unbanned.isErr)
            return Task!void.failure(unbanned.error);

        return Task!void.success();
    }
}

/// Channel-related REST surface.
final class ChannelsEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Returns a channel descriptor by id.
    Task!Channel get(Snowflake channelId)
    {
        if (_real.isNull)
            return Task!Channel.failure(formatError("rest", "Cannot fetch a channel because the REST transport is not configured.", "", "Provide a bot token or a transport before reading channel metadata."));

        auto channel = _real.get.getChannel(channelId);
        if (channel.isErr)
            return Task!Channel.failure(channel.error);

        return Task!Channel.success(channel.value);
    }

    /// Triggers the Discord typing indicator for a channel.
    Task!void triggerTyping(Snowflake channelId)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot trigger typing because the REST transport is not configured.", "", "Provide a bot token or a transport before posting typing indicators."));

        auto triggered = _real.get.triggerTypingIndicator(channelId);
        if (triggered.isErr)
            return Task!void.failure(triggered.error);

        return Task!void.success();
    }

    /// Short alias for `triggerTyping`.
    Task!void typing(Snowflake channelId)
    {
        return triggerTyping(channelId);
    }
}

/// Thread-related REST surface.
final class ThreadsEndpoints
{
    private Nullable!RealDiscordRest _real;

    this(Nullable!RealDiscordRest realTransport)
    {
        _real = realTransport;
    }

    /// Creates a thread from an existing message.
    Task!Channel createFromMessage(
        Snowflake channelId,
        Snowflake messageId,
        string name,
        ushort autoArchiveMinutes = 1440,
        uint rateLimitPerUser = 0
    )
    {
        if (_real.isNull)
            return Task!Channel.failure(formatError("rest", "Cannot create a message thread because the REST transport is not configured.", "", "Provide a bot token or a transport before creating threads."));

        auto created = _real.get.createThreadFromMessage(
            channelId,
            messageId,
            name,
            autoArchiveMinutes,
            rateLimitPerUser
        );
        if (created.isErr)
            return Task!Channel.failure(created.error);

        return Task!Channel.success(created.value);
    }

    /// Creates a standalone thread in a channel.
    Task!Channel create(
        Snowflake channelId,
        string name,
        ChannelType type = ChannelType.PublicThread,
        ushort autoArchiveMinutes = 1440,
        bool invitable = true,
        uint rateLimitPerUser = 0
    )
    {
        if (_real.isNull)
            return Task!Channel.failure(formatError("rest", "Cannot create a thread because the REST transport is not configured.", "", "Provide a bot token or a transport before creating threads."));

        auto created = _real.get.createThread(
            channelId,
            name,
            type,
            autoArchiveMinutes,
            invitable,
            rateLimitPerUser
        );
        if (created.isErr)
            return Task!Channel.failure(created.error);

        return Task!Channel.success(created.value);
    }

    /// Joins a thread as the current bot user.
    Task!void join(Snowflake threadId)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot join a thread because the REST transport is not configured.", "", "Provide a bot token or a transport before joining threads."));

        auto joined = _real.get.joinThread(threadId);
        if (joined.isErr)
            return Task!void.failure(joined.error);

        return Task!void.success();
    }

    /// Leaves a thread as the current bot user.
    Task!void leave(Snowflake threadId)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot leave a thread because the REST transport is not configured.", "", "Provide a bot token or a transport before leaving threads."));

        auto left = _real.get.leaveThread(threadId);
        if (left.isErr)
            return Task!void.failure(left.error);

        return Task!void.success();
    }

    /// Updates archived/locked thread state.
    Task!Channel archive(Snowflake threadId, bool archived = true, bool locked = false)
    {
        if (_real.isNull)
            return Task!Channel.failure(formatError("rest", "Cannot update a thread archive state because the REST transport is not configured.", "", "Provide a bot token or a transport before updating threads."));

        auto updated = _real.get.archiveThread(threadId, archived, locked);
        if (updated.isErr)
            return Task!Channel.failure(updated.error);

        return Task!Channel.success(updated.value);
    }
}

/// Webhook execution REST surface.
final class WebhooksEndpoints
{
    private MessageHistory _history;
    private Nullable!RealDiscordRest _real;

    this(MessageHistory history, Nullable!RealDiscordRest realTransport)
    {
        _history = history;
        _real = realTransport;
    }

    /// Executes a webhook and returns the created message (`wait=true`).
    Task!Message execute(
        Snowflake webhookId,
        string webhookToken,
        MessageCreate payload,
        Nullable!Snowflake threadId = Nullable!Snowflake.init
    )
    {
        if (_real.isNull)
            return Task!Message.failure(formatError("rest", "Cannot execute a webhook because the REST transport is not configured.", "", "Provide a transport before executing webhooks."));

        auto created = _real.get.executeWebhookMessage(webhookId, webhookToken, payload, threadId);
        if (created.isErr)
            return Task!Message.failure(created.error);

        _history.store(created.value);
        return Task!Message.success(created.value);
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
    Task!void send(Snowflake interactionId, string interactionToken, MessageCreate payload)
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

    /// Sends autocomplete choices for an interaction.
    Task!void autocomplete(
        Snowflake interactionId,
        string interactionToken,
        AutocompleteChoice[] choices
    )
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot respond to autocomplete because the REST transport is not configured.", "", "Configure a bot token or inject a transport before sending autocomplete results."));

        auto sent = _real.get.respondAutocomplete(interactionId, interactionToken, choices);
        if (sent.isErr)
            return Task!void.failure(sent.error);

        return Task!void.success();
    }

    /// Responds to an interaction by opening a modal.
    Task!void modal(Snowflake interactionId, string interactionToken, Modal modal)
    {
        if (_real.isNull)
        {
            return Task!void.failure(formatError(
                "rest",
                "Cannot show an interaction modal because the REST transport is not configured.",
                "",
                "Configure a bot token or inject a transport before opening modals."
            ));
        }

        auto sent = _real.get.respondWithModal(interactionId, interactionToken, modal);
        if (sent.isErr)
            return Task!void.failure(sent.error);

        return Task!void.success();
    }

    /// Sends a deferred interaction acknowledgement.
    Task!void defer(Snowflake interactionId, string interactionToken, bool ephemeral = false)
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

    /// Updates the source message for a component interaction.
    Task!void update(Snowflake interactionId, string interactionToken, MessageCreate payload)
    {
        if (_real.isNull)
            return Task!void.failure(formatError("rest", "Cannot update an interaction message because the REST transport is not configured.", "", "Configure a bot token or inject a transport before updating component interaction messages."));

        auto sent = _real.get.respondToInteraction(
            interactionId,
            interactionToken,
            InteractionCallbackType.UpdateMessage,
            payload
        );
        if (sent.isErr)
            return Task!void.failure(sent.error);

        return Task!void.success();
    }

    /// Sends a follow-up message after the initial interaction acknowledgement.
    Task!Message followup(string interactionToken, MessageCreate payload)
    {
        if (_real.isNull)
            return Task!Message.failure(formatError("rest", "Cannot send an interaction follow-up because the REST transport is not configured.", "", "Configure a bot token or inject a transport before sending follow-up messages."));

        auto created = _real.get.createFollowupMessage(interactionToken, payload);
        if (created.isErr)
            return Task!Message.failure(created.error);

        _history.store(created.value);
        return Task!Message.success(created.value);
    }

    /// Edits the original interaction response.
    Task!Message edit(string interactionToken, MessageCreate payload)
    {
        if (_real.isNull)
            return Task!Message.failure(formatError("rest", "Cannot edit the original interaction response because the REST transport is not configured.", "", "Configure a bot token or inject a transport before editing interaction responses."));

        auto edited = _real.get.editOriginalInteractionResponse(interactionToken, payload);
        if (edited.isErr)
            return Task!Message.failure(edited.error);

        _history.store(edited.value);
        return Task!Message.success(edited.value);
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
    ApplicationsEndpoints applications;
    GatewayEndpoints gateway;
    GuildsEndpoints guilds;
    ChannelsEndpoints channels;
    ReactionsEndpoints reactions;
    ThreadsEndpoints threads;
    WebhooksEndpoints webhooks;
    InteractionsEndpoints interactions;
    LatencySample latency;

    this(RestClientConfig config = RestClientConfig.init)
    {
        _config = config;
        _history = new MessageHistory;
        _commands = new ApplicationCommandStore;

        config.latencyTarget = &latency;
        if (config.token.length != 0 || !config.transport.isNull)
            _real = Nullable!RealDiscordRest.of(new RealDiscordRest(config));

        messages = new MessagesEndpoints(_history, _real);
        applicationCommands = new ApplicationCommandsEndpoints(_commands, _real);
        users = new UsersEndpoints(_real);
        applications = new ApplicationsEndpoints(_real);
        gateway = new GatewayEndpoints(_real);
        guilds = new GuildsEndpoints(_real);
        channels = new ChannelsEndpoints(_real);
        reactions = new ReactionsEndpoints(_real);
        threads = new ThreadsEndpoints(_real);
        webhooks = new WebhooksEndpoints(_history, _real);
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
    RestClientConfig config;
    assert(config.userAgent == DdiscordUserAgent);
}

unittest
{
    uint attempts;
    HttpTransport transport = (request) {
        attempts++;

        if (attempts < 3)
        {
            HttpError error;
            error.kind = HttpErrorKind.Server;
            error.message = "temporary outage";
            error.method = "GET";
            error.url = request.url;
            error.statusCode = 503;
            return Result!(HttpResponse, HttpError).err(error);
        }

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"77","username":"retry-bot","bot":true}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);
    config.retryBaseDelay = Duration.zero;
    config.maxRetryDelay = Duration.zero;
    config.maxServerErrorRetries = 3;

    auto rest = new RestClient(config);
    auto me = rest.users.me().await();
    assert(me.username == "retry-bot");
    assert(attempts == 3);
}

unittest
{
    uint attempts;
    HttpTransport transport = (request) {
        attempts++;

        HttpError error;
        error.kind = HttpErrorKind.Server;
        error.message = "temporary outage";
        error.method = "GET";
        error.url = request.url;
        error.statusCode = 503;
        return Result!(HttpResponse, HttpError).err(error);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);
    config.autoRetryServerErrors = false;

    auto rest = new RestClient(config);
    auto result = rest.users.me().awaitResult();
    assert(result.isErr);
    assert(attempts == 1);
}

unittest
{
    uint attempts;
    HttpTransport transport = (request) {
        attempts++;

        if (attempts < 3)
        {
            HttpError error;
            error.kind = HttpErrorKind.RateLimited;
            error.message = "rate limited";
            error.method = "GET";
            error.url = request.url;
            error.statusCode = 429;
            error.headers["Retry-After"] = "0.001";
            return Result!(HttpResponse, HttpError).err(error);
        }

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"77","username":"retry-bot","bot":true}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);
    config.autoRetryRateLimits = true;
    config.maxRateLimitRetries = 3;

    auto rest = new RestClient(config);
    auto me = rest.users.me().await();
    assert(me.username == "retry-bot");
    assert(attempts == 3);
}

unittest
{
    uint attempts;
    HttpTransport transport = (request) {
        attempts++;

        HttpError error;
        error.kind = HttpErrorKind.RateLimited;
        error.message = "rate limited";
        error.method = "GET";
        error.url = request.url;
        error.statusCode = 429;
        error.headers["Retry-After"] = "0.001";
        return Result!(HttpResponse, HttpError).err(error);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);
    config.autoRetryRateLimits = false;

    auto rest = new RestClient(config);
    auto result = rest.users.me().awaitResult();
    assert(result.isErr);
    assert(attempts == 1);
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

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"1","content":"with-file","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto payload = MessageCreate("with-file").attachBytes(
        "hello.txt",
        cast(const(ubyte)[]) "hello",
        "text/plain"
    );
    auto sent = rest.messages.create(Snowflake(1), payload).await();

    assert(sent.content == "with-file");
    assert(captured.contentType.canFind("multipart/form-data; boundary="));
    auto body = cast(string) captured.body;
    assert(body.canFind(`name="payload_json"`));
    assert(body.canFind(`"content":"with-file"`));
    assert(body.canFind(`"attachments":[{`));
    assert(body.canFind(`"id":"0"`));
    assert(body.canFind(`"filename":"hello.txt"`));
    assert(body.canFind(`name="files[0]"; filename="hello.txt"`));
    assert(body.canFind("hello"));
}

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;
        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.applicationId = Nullable!Snowflake.of(Snowflake(42));
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto modal = Modal("bug_modal", "Bug Report")
        .addTextInput(TextInput("summary", "Summary"));
    auto result = rest.interactions.modal(Snowflake(9), "abc", modal).awaitResult();

    assert(result.isOk);
    assert(captured.url.canFind("/interactions/9/abc/callback"));
    auto body = cast(string) captured.body;
    assert(body.canFind(`"type":9`));
    assert(body.canFind(`"custom_id":"bug_modal"`));
    assert(body.canFind(`"title":"Bug Report"`));
    assert(body.canFind(`"custom_id":"summary"`));
}

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;
        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto payload = MessageCreate("updated");
    auto result = rest.interactions.update(Snowflake(10), "component-token", payload).awaitResult();

    assert(result.isOk);
    assert(captured.url.canFind("/interactions/10/component-token/callback"));
    auto body = cast(string) captured.body;
    assert(body.canFind(`"type":7`));
    assert(body.canFind(`"content":"updated"`));
}

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"3","channel_id":"1","content":"followup-file","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.applicationId = Nullable!Snowflake.of(Snowflake(42));
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto payload = MessageCreate("followup-file").attachBytes(
        "report.json",
        cast(const(ubyte)[]) `{"ok":true}`,
        "application/json"
    );
    auto followup = rest.interactions.followup("abc", payload).await();

    assert(followup.content == "followup-file");
    assert(!captured.authenticated);
    assert(captured.url.canFind("/webhooks/42/abc"));
    assert(captured.contentType.canFind("multipart/form-data; boundary="));
    auto body = cast(string) captured.body;
    assert(body.canFind(`name="payload_json"`));
    assert(body.canFind(`"content":"followup-file"`));
    assert(body.canFind(`name="files[0]"; filename="report.json"`));
}

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"42","username":"renamed-bot","avatar":"hash","bot":true}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    ModifyCurrentUser payload;
    payload.username = Nullable!string.of("renamed-bot");
    payload.avatar = Nullable!string.of("data:image/png;base64,abc");

    auto updated = rest.users.update(payload).await();
    assert(updated.username == "renamed-bot");
    assert(captured.method == HttpMethod.Patch);
    assert(captured.url.canFind("/users/@me"));
    auto body = parseJSON(cast(string) captured.body);
    assert(body.object.get("username", JSONValue.init).str == "renamed-bot");
    assert(body.object.get("avatar", JSONValue.init).str == "data:image/png;base64,abc");
}

unittest
{
    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 200;

        if (request.url.canFind("/oauth2/applications/@me"))
        {
            response.body = cast(ubyte[]) `{
                "id":"55",
                "description":"Helpful app",
                "owner":{"id":"7","username":"owner","bot":false},
                "team":{"id":"99","owner_user_id":"8"}
            }`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.body = cast(ubyte[]) `{
            "id":"55",
            "description":"Updated description",
            "owner":{"id":"7","username":"owner","bot":false}
        }`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto application = rest.applications.me().await();
    assert(application.id == Snowflake(55));
    assert(application.description == "Helpful app");
    assert(!application.owner.isNull);
    assert(application.owner.get.id == Snowflake(7));
    assert(!application.team.isNull);
    assert(application.team.get.ownerUserId.get == Snowflake(8));

    ModifyCurrentApplication payload;
    payload.description = Nullable!string.of("Updated description");
    auto updated = rest.applications.update(payload).await();
    assert(updated.description == "Updated description");

    assert(captured.length == 2);
    assert(captured[0].method == HttpMethod.Get);
    assert(captured[0].url.canFind("/oauth2/applications/@me"));
    assert(captured[1].method == HttpMethod.Patch);
    assert(captured[1].url.canFind("/applications/@me"));
    auto body = parseJSON(cast(string) captured[1].body);
    assert(body.object.get("description", JSONValue.init).str == "Updated description");
}

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto result = rest.channels.triggerTyping(Snowflake(77)).awaitResult();

    assert(result.isOk);
    assert(captured.method == HttpMethod.Post);
    assert(captured.url.canFind("/channels/77/typing"));
}

unittest
{
    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"11","channel_id":"77","content":"edited","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);
    auto edited = rest.messages.edit(
        Snowflake(77),
        Snowflake(11),
        MessageCreate("edited")
    ).await();

    assert(edited.content == "edited");
    assert(captured.method == HttpMethod.Patch);
    assert(captured.url.canFind("/channels/77/messages/11"));
    auto body = parseJSON(cast(string) captured.body);
    assert(body.object.get("content", JSONValue.init).str == "edited");
}

unittest
{
    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto deleted = rest.messages.delete(Snowflake(77), Snowflake(12)).awaitResult();
    assert(deleted.isOk);
    assert(captured.length == 1);
    assert(captured[0].method == HttpMethod.Delete);
    assert(captured[0].url.canFind("/channels/77/messages/12"));

    auto bulk = rest.messages.bulkDelete(
        Snowflake(77),
        [Snowflake(21), Snowflake(22)]
    ).awaitResult();
    assert(bulk.isOk);
    assert(captured.length == 2);
    assert(captured[1].method == HttpMethod.Post);
    assert(captured[1].url.canFind("/channels/77/messages/bulk-delete"));
    auto body = parseJSON(cast(string) captured[1].body);
    assert(body.object.get("messages", JSONValue.init).array.length == 2);
}

unittest
{
    RestClientConfig config;
    config.token = "token";
    auto rest = new RestClient(config);

    auto result = rest.messages.bulkDelete(Snowflake(77), [Snowflake(99)]).awaitResult();
    assert(result.isErr);
    assert(result.error.canFind("between 2 and 100"));
}

unittest
{
    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        if (request.method == HttpMethod.Get)
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `[
                {"id":"91","channel_id":"77","content":"pinned-a","author":{"id":"2","username":"bot","bot":true}},
                {"id":"92","channel_id":"77","content":"pinned-b","author":{"id":"2","username":"bot","bot":true}}
            ]`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.method == HttpMethod.Post)
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"id":"90","channel_id":"77","content":"news","author":{"id":"2","username":"bot","bot":true}}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto crossposted = rest.messages.crosspost(Snowflake(77), Snowflake(90)).awaitResult();
    assert(crossposted.isOk);
    assert(captured[0].method == HttpMethod.Post);
    assert(captured[0].url.canFind("/channels/77/messages/90/crosspost"));

    auto pinned = rest.messages.pin(
        Snowflake(77),
        Snowflake(90),
        Nullable!string.of("pin reason")
    ).awaitResult();
    assert(pinned.isOk);
    assert(captured[1].method == HttpMethod.Put);
    assert(captured[1].url.canFind("/channels/77/pins/90"));
    assert(captured[1].headers.get("X-Audit-Log-Reason", "") == "pin%20reason");

    auto unpinned = rest.messages.unpin(
        Snowflake(77),
        Snowflake(90),
        Nullable!string.of("unpin reason")
    ).awaitResult();
    assert(unpinned.isOk);
    assert(captured[2].method == HttpMethod.Delete);
    assert(captured[2].url.canFind("/channels/77/pins/90"));
    assert(captured[2].headers.get("X-Audit-Log-Reason", "") == "unpin%20reason");

    auto pins = rest.messages.pins(Snowflake(77)).awaitResult();
    assert(pins.isOk);
    assert(pins.value.length == 2);
    assert(pins.value[0].content == "pinned-a");
    assert(captured[3].method == HttpMethod.Get);
    assert(captured[3].url.canFind("/channels/77/pins"));
}

unittest
{
    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto added = rest.reactions.add(Snowflake(77), Snowflake(11), "✅").awaitResult();
    assert(added.isOk);
    assert(captured[0].method == HttpMethod.Put);
    assert(captured[0].url.canFind("/channels/77/messages/11/reactions/"));
    assert(captured[0].url.canFind("/@me"));

    auto removedSelf = rest.reactions.removeSelf(Snowflake(77), Snowflake(11), "✅").awaitResult();
    assert(removedSelf.isOk);
    assert(captured[1].method == HttpMethod.Delete);
    assert(captured[1].url.canFind("/@me"));

    auto removedUser = rest.reactions.removeUser(
        Snowflake(77),
        Snowflake(11),
        "custom:123",
        Snowflake(8)
    ).awaitResult();
    assert(removedUser.isOk);
    assert(captured[2].method == HttpMethod.Delete);
    assert(captured[2].url.canFind("/custom%3A123/8"));

    auto clearedEmoji = rest.reactions.clearEmoji(Snowflake(77), Snowflake(11), "✅").awaitResult();
    assert(clearedEmoji.isOk);
    assert(captured[3].method == HttpMethod.Delete);
    assert(captured[3].url.canFind("/channels/77/messages/11/reactions/"));

    auto cleared = rest.reactions.clear(Snowflake(77), Snowflake(11)).awaitResult();
    assert(cleared.isOk);
    assert(captured[4].method == HttpMethod.Delete);
    assert(captured[4].url.canFind("/channels/77/messages/11/reactions"));
}

unittest
{
    RestClientConfig config;
    config.token = "token";

    auto rest = new RestClient(config);
    auto invalid = rest.reactions.add(Snowflake(77), Snowflake(11), "   ").awaitResult();
    assert(invalid.isErr);
    assert(invalid.error.canFind("empty reaction emoji"));
}

unittest
{
    import std.datetime : dur;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        if (request.method == HttpMethod.Patch && request.url.canFind("/members/"))
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"user":{"id":"8","username":"target","bot":false},"roles":[]}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto timed = rest.guilds.timeoutMember(
        Snowflake(55),
        Snowflake(8),
        dur!"minutes"(10),
        Nullable!string.of("timeout reason")
    ).awaitResult();
    assert(timed.isOk);
    assert(captured[0].method == HttpMethod.Patch);
    assert(captured[0].url.canFind("/guilds/55/members/8"));
    assert(captured[0].headers.get("X-Audit-Log-Reason", "") == "timeout%20reason");
    auto timeoutBody = parseJSON(cast(string) captured[0].body);
    assert(timeoutBody.object.get("communication_disabled_until", JSONValue.init).type == JSONType.string);

    auto clearedTimeout = rest.guilds.clearMemberTimeout(
        Snowflake(55),
        Snowflake(8),
        Nullable!string.of("clear timeout")
    ).awaitResult();
    assert(clearedTimeout.isOk);
    assert(captured[1].method == HttpMethod.Patch);
    assert(captured[1].headers.get("X-Audit-Log-Reason", "") == "clear%20timeout");
    auto clearBody = parseJSON(cast(string) captured[1].body);
    assert(clearBody.object.get("communication_disabled_until", JSONValue.init).type == JSONType.null_);

    auto kicked = rest.guilds.kick(
        Snowflake(55),
        Snowflake(8),
        Nullable!string.of("kick\nwith-break")
    ).awaitResult();
    assert(kicked.isOk);
    assert(captured[2].method == HttpMethod.Delete);
    assert(captured[2].url.canFind("/guilds/55/members/8"));
    assert(captured[2].headers.get("X-Audit-Log-Reason", "") == "kickwith-break");

    auto banned = rest.guilds.ban(
        Snowflake(55),
        Snowflake(8),
        3600,
        Nullable!string.of("ban reason")
    ).awaitResult();
    assert(banned.isOk);
    assert(captured[3].method == HttpMethod.Put);
    assert(captured[3].url.canFind("/guilds/55/bans/8"));
    assert(captured[3].headers.get("X-Audit-Log-Reason", "") == "ban%20reason");
    auto banBody = parseJSON(cast(string) captured[3].body);
    assert(banBody.object.get("delete_message_seconds", JSONValue.init).integer == 3600);

    auto unbanned = rest.guilds.unban(
        Snowflake(55),
        Snowflake(8),
        Nullable!string.of("unban reason")
    ).awaitResult();
    assert(unbanned.isOk);
    assert(captured[4].method == HttpMethod.Delete);
    assert(captured[4].url.canFind("/guilds/55/bans/8"));
    assert(captured[4].headers.get("X-Audit-Log-Reason", "") == "unban%20reason");
}

unittest
{
    import std.datetime : dur;

    RestClientConfig config;
    config.token = "token";

    auto rest = new RestClient(config);

    auto timeoutZero = rest.guilds.timeoutMember(
        Snowflake(55),
        Snowflake(8),
        Duration.zero
    ).awaitResult();
    assert(timeoutZero.isErr);
    assert(timeoutZero.error.canFind("range (0, 28 days]"));

    auto timeoutTooLong = rest.guilds.timeoutMember(
        Snowflake(55),
        Snowflake(8),
        dur!"days"(29)
    ).awaitResult();
    assert(timeoutTooLong.isErr);

    auto invalidBan = rest.guilds.ban(Snowflake(55), Snowflake(8), 700_000).awaitResult();
    assert(invalidBan.isErr);
    assert(invalidBan.error.canFind("0..604800"));
}

unittest
{
    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        if (request.url.canFind("/webhooks/"))
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"id":"91","channel_id":"77","content":"webhook-ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.method == HttpMethod.Post && request.url.canFind("/threads"))
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"id":"900","name":"ops-thread","type":11}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        if (request.method == HttpMethod.Patch && request.url.canFind("/channels/900"))
        {
            response.statusCode = 200;
            response.body = cast(ubyte[]) `{"id":"900","name":"ops-thread","type":11}`.dup;
            return Result!(HttpResponse, HttpError).ok(response);
        }

        response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto fromMessage = rest.threads.createFromMessage(
        Snowflake(77),
        Snowflake(11),
        "ops-thread"
    ).awaitResult();
    assert(fromMessage.isOk);
    assert(captured[0].method == HttpMethod.Post);
    assert(captured[0].url.canFind("/channels/77/messages/11/threads"));

    auto standalone = rest.threads.create(
        Snowflake(77),
        "ops-thread-2",
        ChannelType.PublicThread
    ).awaitResult();
    assert(standalone.isOk);
    assert(captured[1].method == HttpMethod.Post);
    assert(captured[1].url.canFind("/channels/77/threads"));

    auto joined = rest.threads.join(Snowflake(900)).awaitResult();
    assert(joined.isOk);
    assert(captured[2].method == HttpMethod.Put);
    assert(captured[2].url.canFind("/channels/900/thread-members/@me"));

    auto archived = rest.threads.archive(Snowflake(900), true, true).awaitResult();
    assert(archived.isOk);
    assert(captured[3].method == HttpMethod.Patch);
    auto archiveBody = parseJSON(cast(string) captured[3].body);
    assert(archiveBody.object.get("archived", JSONValue.init).boolean);
    assert(archiveBody.object.get("locked", JSONValue.init).boolean);

    auto left = rest.threads.leave(Snowflake(900)).awaitResult();
    assert(left.isOk);
    assert(captured[4].method == HttpMethod.Delete);
    assert(captured[4].url.canFind("/channels/900/thread-members/@me"));

    auto webhook = rest.webhooks.execute(
        Snowflake(600),
        "abc-token",
        MessageCreate("webhook-ok"),
        Nullable!Snowflake.of(Snowflake(900))
    ).awaitResult();
    assert(webhook.isOk);
    assert(captured[5].method == HttpMethod.Post);
    assert(!captured[5].authenticated);
    assert(captured[5].url.canFind("/webhooks/600/abc-token?wait=true&thread_id=900"));
}

unittest
{
    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"91","channel_id":"77","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.applicationId = Nullable!Snowflake.of(Snowflake(42));
    config.transport = Nullable!HttpTransport.of(transport);

    auto rest = new RestClient(config);

    auto followup = rest.interactions.followup("abc/def?x=1", MessageCreate("ok")).awaitResult();
    assert(followup.isOk);
    assert(captured[0].url.canFind("/webhooks/42/abc%2Fdef%3Fx%3D1"));

    auto webhook = rest.webhooks.execute(
        Snowflake(600),
        "abc/def?x=1",
        MessageCreate("ok")
    ).awaitResult();
    assert(webhook.isOk);
    assert(captured[1].url.canFind("/webhooks/600/abc%2Fdef%3Fx%3D1?wait=true"));
}

unittest
{
    RestClientConfig config;
    config.token = "token";

    auto rest = new RestClient(config);

    auto followup = rest.interactions.followup("   ", MessageCreate("ok")).awaitResult();
    assert(followup.isErr);
    assert(followup.error.canFind("empty token"));

    auto webhook = rest.webhooks.execute(
        Snowflake(600),
        "",
        MessageCreate("ok")
    ).awaitResult();
    assert(webhook.isErr);
    assert(webhook.error.canFind("empty token"));

    string tooLongAuditReason;
    while (tooLongAuditReason.length < 513)
        tooLongAuditReason ~= "a";

    auto tooLongReason = rest.guilds.kick(
        Snowflake(55),
        Snowflake(8),
        Nullable!string.of(tooLongAuditReason)
    ).awaitResult();
    assert(tooLongReason.isErr);
    assert(tooLongReason.error.canFind("up to 512"));
}

unittest
{
    RestClientConfig config;
    config.token = "token";

    auto rest = new RestClient(config);

    auto emptyName = rest.threads.createFromMessage(
        Snowflake(77),
        Snowflake(11),
        "   "
    ).awaitResult();
    assert(emptyName.isErr);
    assert(emptyName.error.canFind("empty name"));

    auto invalidArchiveWindow = rest.threads.createFromMessage(
        Snowflake(77),
        Snowflake(11),
        "ops",
        120
    ).awaitResult();
    assert(invalidArchiveWindow.isErr);
    assert(invalidArchiveWindow.error.canFind("60, 1440, 4320, and 10080"));

    auto invalidType = rest.threads.create(
        Snowflake(77),
        "ops",
        ChannelType.GuildText
    ).awaitResult();
    assert(invalidType.isErr);
    assert(invalidType.error.canFind("unsupported channel type"));
}
