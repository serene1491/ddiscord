/**
 * ddiscord — command context.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.context.command;

import ddiscord.cache : CacheStore;
import ddiscord.interactions.components : Modal;
import ddiscord.models.application_command : AutocompleteChoice;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message, MessageCreate, MessageFlags;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.tasks : AsyncTask;
import ddiscord.util.errors : formatError;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;

/// Bound message operations helper for command handlers.
struct CommandMessageRef
{
    RestClient rest;
    Snowflake channelId;
    Snowflake messageId;

    /// Adds a reaction as the current bot user.
    AsyncTask!void react(string emoji)
    {
        return rest.reactions.add(channelId, messageId, emoji);
    }

    /// Removes the current bot user's reaction.
    AsyncTask!void unreact(string emoji)
    {
        return rest.reactions.removeSelf(channelId, messageId, emoji);
    }

    /// Pins this message.
    AsyncTask!void pin(Nullable!string auditReason = Nullable!string.init)
    {
        return rest.messages.pin(channelId, messageId, auditReason);
    }

    /// Unpins this message.
    AsyncTask!void unpin(Nullable!string auditReason = Nullable!string.init)
    {
        return rest.messages.unpin(channelId, messageId, auditReason);
    }

    /// Crossposts this message in announcement channels.
    AsyncTask!Message crosspost()
    {
        return rest.messages.crosspost(channelId, messageId);
    }

    /// Edits this message.
    AsyncTask!Message edit(MessageCreate payload)
    {
        return rest.messages.edit(channelId, messageId, payload);
    }

    /// Edits this message with plain-text content.
    AsyncTask!Message edit(string content)
    {
        return edit(MessageCreate(content));
    }

    /// Deletes this message.
    AsyncTask!void deleteMessage()
    {
        return rest.messages.delete(channelId, messageId);
    }
}

private struct MessageOperationTarget
{
    Snowflake channelId;
    Snowflake messageId;
}

/// Invocation source for a command.
enum CommandSource
{
    Prefix,
    Slash,
    ContextMenu,
}

/// Unified command execution context.
struct CommandContext
{
    Nullable!Message message;
    Nullable!Interaction interaction;
    CommandSource source = CommandSource.Prefix;
    RestClient rest;
    ServiceContainer services;
    CacheStore cache;
    StateStore state;
    User invoker;
    Channel currentChannel;
    Nullable!Guild currentGuild;
    Nullable!GuildMember currentMember;
    ulong permissions;
    long receiveLatencyMilliseconds;
    bool interactionAcknowledged;
    bool interactionResponded;

    /// Returns a bound helper for the source message when one is available.
    Nullable!CommandMessageRef messageRef() @property
    {
        auto target = primaryMessageTarget();
        if (target.isNull)
            return Nullable!CommandMessageRef.init;

        CommandMessageRef reference;
        reference.rest = rest;
        reference.channelId = target.get.channelId;
        reference.messageId = target.get.messageId;
        return Nullable!CommandMessageRef.of(reference);
    }

    /// Invoker shortcut.
    User user() const @property
    {
        return invoker;
    }

    /// Channel shortcut.
    const(Channel) channel() const @property
    {
        return currentChannel;
    }

    /// Guild shortcut.
    Nullable!Guild guild() @property
    {
        return currentGuild;
    }

    /// Member shortcut.
    Nullable!GuildMember member() @property
    {
        return currentMember;
    }

    /// Returns whether this command context was created from a prefix route.
    bool isPrefix() const @property
    {
        return source == CommandSource.Prefix;
    }

    /// Returns whether this command context was created from a slash route.
    bool isSlash() const @property
    {
        return source == CommandSource.Slash;
    }

    /// Returns whether this command context was created from a context-menu route.
    bool isContextMenu() const @property
    {
        return source == CommandSource.ContextMenu;
    }

    /// Returns whether this context has an active interaction token.
    bool isInteraction() const @property
    {
        return hasInteractionToken;
    }

    /// Sends a message in the current command context.
    AsyncTask!void send(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        return send(payload, ephemeral);
    }

    /// Sends a payload in the current command context.
    AsyncTask!void send(MessageCreate payload, bool ephemeral = false)
    {
        auto ephemeralError = validateEphemeralUsage(ephemeral, "send");
        if (!ephemeralError.isNull)
            return AsyncTask!void.failure(ephemeralError.get);

        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (hasInteractionToken)
        {
            if (interactionAcknowledged || interactionResponded)
            {
                auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
                if (created.isErr)
                    return AsyncTask!void.failure(created.error);

                return AsyncTask!void.success();
            }

            auto sent = rest.interactions.send(interaction.get.id, interaction.get.token, payload).awaitResult();
            if (sent.isErr)
                return AsyncTask!void.failure(sent.error);

            interactionResponded = true;
            return AsyncTask!void.success();
        }

        auto channelId = currentChannel.id;
        if (!message.isNull)
            channelId = message.get.channelId;

        auto created = rest.messages.create(channelId, payload).awaitResult();
        if (created.isErr)
            return AsyncTask!void.failure(created.error);

        return AsyncTask!void.success();
    }

    /// Sends a message with one binary attachment in the current command context.
    AsyncTask!void sendFile(
        string filename,
        const(ubyte)[] data,
        string content = "",
        string contentType = "application/octet-stream",
        bool ephemeral = false
    )
    {
        MessageCreate payload;
        if (content.length != 0)
            payload = payload.withContent(content);
        payload = payload.attachBytes(filename, data, contentType);
        return send(payload, ephemeral);
    }

    /// Replies to the source message using Discord's native reply payload.
    AsyncTask!void reply(string content, bool mentionAuthor = false, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        return reply(payload, mentionAuthor, ephemeral);
    }

    /// Replies to the source message using Discord's native reply payload.
    AsyncTask!void reply(MessageCreate payload, bool mentionAuthor = false, bool ephemeral = false)
    {
        auto ephemeralError = validateEphemeralUsage(ephemeral, "reply");
        if (!ephemeralError.isNull)
            return AsyncTask!void.failure(ephemeralError.get);

        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (!message.isNull)
            return send(message.get.reply(payload, mentionAuthor), false);

        return send(payload, false);
    }

    /// Sends a deferred acknowledgement for interaction-based commands.
    AsyncTask!void defer(bool ephemeral = false)
    {
        auto ephemeralError = validateEphemeralUsage(ephemeral, "defer");
        if (!ephemeralError.isNull)
            return AsyncTask!void.failure(ephemeralError.get);

        if (hasInteractionToken)
        {
            auto deferred = rest.interactions.defer(interaction.get.id, interaction.get.token, ephemeral).awaitResult();
            if (deferred.isErr)
                return AsyncTask!void.failure(deferred.error);

            interactionAcknowledged = true;
            return AsyncTask!void.success();
        }

        return AsyncTask!void.success();
    }

    /// Triggers the typing indicator for message-based contexts.
    AsyncTask!void typing()
    {
        if (hasInteractionToken)
            return AsyncTask!void.success();

        auto channelId = currentChannelId();
        if (channelId.value == 0)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "The typing indicator requires a channel id.",
                "",
                "Populate `CommandContext.currentChannel` or `CommandContext.message` before calling `typing()`."
            ));
        }

        auto sent = rest.channels.typing(channelId).awaitResult();
        if (sent.isErr)
            return AsyncTask!void.failure(sent.error);

        return AsyncTask!void.success();
    }

    /// Shows a "thinking" state appropriate for the current command source.
    AsyncTask!void think(bool ephemeral = false)
    {
        auto ephemeralError = validateEphemeralUsage(ephemeral, "think");
        if (!ephemeralError.isNull)
            return AsyncTask!void.failure(ephemeralError.get);

        if (hasInteractionToken)
        {
            if (interactionAcknowledged || interactionResponded)
                return AsyncTask!void.success();

            return defer(ephemeral);
        }

        return typing();
    }

    /// Reacts to the source message in this context.
    AsyncTask!void react(string emoji)
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "This command context has no source message for reaction operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        auto added = reference.get.react(emoji).awaitResult();
        if (added.isErr)
            return AsyncTask!void.failure(added.error);
        return AsyncTask!void.success();
    }

    /// Removes the bot reaction from the source message.
    AsyncTask!void unreact(string emoji)
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "This command context has no source message for reaction operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        auto removed = reference.get.unreact(emoji).awaitResult();
        if (removed.isErr)
            return AsyncTask!void.failure(removed.error);
        return AsyncTask!void.success();
    }

    /// Pins the source message.
    AsyncTask!void pin(Nullable!string auditReason = Nullable!string.init)
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "This command context has no source message for pin operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        auto pinned = reference.get.pin(auditReason).awaitResult();
        if (pinned.isErr)
            return AsyncTask!void.failure(pinned.error);
        return AsyncTask!void.success();
    }

    /// Unpins the source message.
    AsyncTask!void unpin(Nullable!string auditReason = Nullable!string.init)
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "This command context has no source message for pin operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        auto unpinned = reference.get.unpin(auditReason).awaitResult();
        if (unpinned.isErr)
            return AsyncTask!void.failure(unpinned.error);
        return AsyncTask!void.success();
    }

    /// Crossposts the source message and returns Discord's created message payload.
    AsyncTask!Message crosspost()
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!Message.failure(formatError(
                "context",
                "This command context has no source message for crosspost operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        return reference.get.crosspost();
    }

    /// Edits the source message with the provided payload.
    AsyncTask!Message editMessage(MessageCreate payload)
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!Message.failure(formatError(
                "context",
                "This command context has no source message for edit operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        return reference.get.edit(payload);
    }

    /// Edits the source message with plain-text content.
    AsyncTask!Message editMessage(string content)
    {
        return editMessage(MessageCreate(content));
    }

    /// Deletes the source message.
    AsyncTask!void deleteMessage()
    {
        auto reference = messageRef;
        if (reference.isNull)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "This command context has no source message for delete operations.",
                "",
                "Use this helper from message-based contexts or with interactions that target a message."
            ));
        }

        auto deleted = reference.get.deleteMessage().awaitResult();
        if (deleted.isErr)
            return AsyncTask!void.failure(deleted.error);
        return AsyncTask!void.success();
    }

    /// Sends autocomplete choices for the current interaction.
    AsyncTask!void autocomplete(AutocompleteChoice[] choices)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "Autocomplete responses require an active interaction token.",
                "",
                "Call `autocomplete` only from an autocomplete interaction handler."
            ));
        }

        auto sent = rest.interactions.autocomplete(interaction.get.id, interaction.get.token, choices).awaitResult();
        if (sent.isErr)
            return AsyncTask!void.failure(sent.error);

        interactionResponded = true;
        return AsyncTask!void.success();
    }

    /// Opens a modal in response to the current interaction.
    AsyncTask!void showModal(Modal modal)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "Opening a modal requires an active interaction token.",
                "",
                "Call `showModal` only while handling a real interaction."
            ));
        }

        auto sent = rest.interactions.modal(interaction.get.id, interaction.get.token, modal).awaitResult();
        if (sent.isErr)
            return AsyncTask!void.failure(sent.error);

        interactionResponded = true;
        return AsyncTask!void.success();
    }

    /// Sends a follow-up message for a deferred or already-acknowledged interaction.
    AsyncTask!void followup(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return followup(payload);
    }

    /// Sends a follow-up payload for a deferred or already-acknowledged interaction.
    AsyncTask!void followup(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "Interaction follow-up messages require an active interaction token.",
                "",
                "Defer or respond to a real interaction before sending follow-up messages."
            ));
        }

        auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
        if (created.isErr)
            return AsyncTask!void.failure(created.error);

        interactionResponded = true;
        return AsyncTask!void.success();
    }

    /// Sends an interaction follow-up with one binary attachment.
    AsyncTask!void followupFile(
        string filename,
        const(ubyte)[] data,
        string content = "",
        string contentType = "application/octet-stream",
        bool ephemeral = false
    )
    {
        MessageCreate payload;
        if (content.length != 0)
            payload = payload.withContent(content);
        payload = payload.attachBytes(filename, data, contentType);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return followup(payload);
    }

    /// Edits the original interaction response.
    AsyncTask!void edit(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return edit(payload);
    }

    /// Edits the original interaction response payload.
    AsyncTask!void edit(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return AsyncTask!void.failure(formatError(
                "context",
                "Editing the original interaction response requires an active interaction token.",
                "",
                "Call `edit` only after handling a real interaction."
            ));
        }

        auto edited = rest.interactions.edit(interaction.get.token, payload).awaitResult();
        if (edited.isErr)
            return AsyncTask!void.failure(edited.error);

        interactionResponded = true;
        interactionAcknowledged = true;
        return AsyncTask!void.success();
    }

    /// Edits the original interaction response and adds one binary attachment.
    AsyncTask!void editFile(
        string filename,
        const(ubyte)[] data,
        string content = "",
        string contentType = "application/octet-stream",
        bool ephemeral = false
    )
    {
        MessageCreate payload;
        if (content.length != 0)
            payload = payload.withContent(content);
        payload = payload.attachBytes(filename, data, contentType);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return edit(payload);
    }

    /// Context-menu target message, if any.
    Nullable!Message targetMessage() @property
    {
        if (interaction.isNull)
            return Nullable!Message.init;
        return interaction.get.targetMessage;
    }

    /// Returns this context as a prefix command context.
    PrefixContext asPrefix()
    {
        PrefixContext ctx;
        ctx.command = this;
        return ctx;
    }

    /// Returns this context as a slash command context.
    SlashContext asSlash()
    {
        SlashContext ctx;
        ctx.command = this;
        return ctx;
    }

    /// Returns this context as a context-menu command context.
    ContextMenuContext asContextMenu()
    {
        ContextMenuContext ctx;
        ctx.command = this;
        return ctx;
    }

    /// Returns this context as a hybrid command context.
    HybridContext asHybrid()
    {
        HybridContext ctx;
        ctx.command = this;
        return ctx;
    }

    private Snowflake currentChannelId() const
    {
        if (!message.isNull && message.get.channelId.value != 0)
            return message.get.channelId;
        return currentChannel.id;
    }

    private bool hasInteractionToken() const @property
    {
        return !interaction.isNull && interaction.get.token.length != 0;
    }

    private Nullable!string validateEphemeralUsage(bool ephemeral, string operationName) const
    {
        if (!ephemeral || hasInteractionToken)
            return Nullable!string.init;

        return Nullable!string.of(formatError(
            "context",
            "Ephemeral responses require an active interaction token.",
            "Attempted `" ~ operationName ~ "` with `ephemeral=true` on a non-interaction route.",
            "Use slash/context-menu routes for ephemeral responses or call `" ~ operationName ~ "` without `ephemeral`."
        ));
    }

    private Nullable!MessageOperationTarget primaryMessageTarget() const
    {
        if (!message.isNull)
        {
            auto source = message.get;
            if (source.id.value != 0 && source.channelId.value != 0)
            {
                MessageOperationTarget target;
                target.channelId = source.channelId;
                target.messageId = source.id;
                return Nullable!MessageOperationTarget.of(target);
            }
        }

        if (!interaction.isNull && !interaction.get.targetMessage.isNull)
        {
            auto targetMessage = interaction.get.targetMessage.get;
            if (targetMessage.id.value != 0 && targetMessage.channelId.value != 0)
            {
                MessageOperationTarget target;
                target.channelId = targetMessage.channelId;
                target.messageId = targetMessage.id;
                return Nullable!MessageOperationTarget.of(target);
            }
        }

        return Nullable!MessageOperationTarget.init;
    }
}

/// Prefix/text command context.
struct PrefixContext
{
    CommandContext command;
    alias command this;

    Message sourceMessage() @property
    {
        return command.message.getOr(Message.init);
    }

    bool isPrefix() const @property
    {
        return command.source == CommandSource.Prefix;
    }

    /// Prefix-friendly alias for `send`.
    AsyncTask!void respond(string content)
    {
        return command.send(content);
    }

    /// Prefix-friendly alias for `send`.
    AsyncTask!void respond(MessageCreate payload)
    {
        return command.send(payload);
    }

    /// Reply directly to the source message, mentioning by default.
    AsyncTask!void replyToSource(string content, bool mentionAuthor = true)
    {
        return command.reply(content, mentionAuthor);
    }
}

/// Slash command context.
struct SlashContext
{
    CommandContext command;
    alias command this;

    Interaction sourceInteraction() @property
    {
        return command.interaction.getOr(Interaction.init);
    }

    bool isSlash() const @property
    {
        return command.source == CommandSource.Slash;
    }

    /// Slash-friendly alias for interaction responses.
    AsyncTask!void respond(string content, bool ephemeral = false)
    {
        return command.send(content, ephemeral);
    }

    /// Slash-friendly alias for interaction responses.
    AsyncTask!void respond(MessageCreate payload, bool ephemeral = false)
    {
        return command.send(payload, ephemeral);
    }

    /// Sends an ephemeral slash response.
    AsyncTask!void respondEphemeral(string content)
    {
        return command.send(content, true);
    }

    /// Defers the interaction as ephemeral.
    AsyncTask!void deferEphemeral()
    {
        return command.defer(true);
    }

    /// Marks the interaction as "thinking" in ephemeral mode.
    AsyncTask!void thinkEphemeral()
    {
        return command.think(true);
    }
}

/// Context-menu command context.
struct ContextMenuContext
{
    CommandContext command;
    alias command this;

    Interaction sourceInteraction() @property
    {
        return command.interaction.getOr(Interaction.init);
    }

    bool isContextMenu() const @property
    {
        return command.source == CommandSource.ContextMenu;
    }
}

/// Unified hybrid command context spanning prefix and slash flows.
struct HybridContext
{
    CommandContext command;
    alias command this;

    bool fromPrefix() const @property
    {
        return command.source == CommandSource.Prefix;
    }

    bool fromSlash() const @property
    {
        return command.source == CommandSource.Slash;
    }

    Nullable!PrefixContext prefix() @property
    {
        if (!fromPrefix)
            return Nullable!PrefixContext.init;
        return Nullable!PrefixContext.of(command.asPrefix());
    }

    Nullable!SlashContext slash() @property
    {
        if (!fromSlash)
            return Nullable!SlashContext.init;
        return Nullable!SlashContext.of(command.asSlash());
    }

    /// Unified response helper across prefix and slash routes.
    AsyncTask!void respond(string content, bool ephemeralOnSlash = false)
    {
        if (fromSlash)
            return command.send(content, ephemeralOnSlash);
        return command.send(content);
    }

    /// Unified payload response helper across prefix and slash routes.
    AsyncTask!void respond(MessageCreate payload, bool ephemeralOnSlash = false)
    {
        if (fromSlash)
            return command.send(payload, ephemeralOnSlash);
        return command.send(payload);
    }
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpMethod, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;

    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        if (request.url.canFind("/typing"))
            response.statusCode = 204;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.currentChannel.id = Snowflake(99);

    auto typing = ctx.typing().awaitResult();
    assert(typing.isOk);
    assert(captured.method == HttpMethod.Post);
    assert(captured.url.canFind("/channels/99/typing"));
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;
    import std.json : JSONType, JSONValue, parseJSON;

    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.currentChannel.id = Snowflake(99);

    Message source;
    source.id = Snowflake(55);
    source.channelId = Snowflake(99);
    ctx.message = Nullable!Message.of(source);

    auto sent = ctx.reply("hello", true).awaitResult();
    assert(sent.isOk);

    auto body = parseJSON(cast(string) captured.body);
    auto reference = body.object.get("message_reference", JSONValue.init);
    auto allowedMentions = body.object.get("allowed_mentions", JSONValue.init);
    assert(reference.object.get("message_id", JSONValue.init).str == "55");
    assert(allowedMentions.object.get("replied_user", JSONValue.init).boolean);
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;

    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"99","content":"with-file","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.currentChannel.id = Snowflake(99);

    auto sent = ctx.sendFile(
        "hello.txt",
        cast(const(ubyte)[]) "hello",
        "with-file",
        "text/plain"
    ).awaitResult();
    assert(sent.isOk);

    assert(captured.contentType.canFind("multipart/form-data; boundary="));
    auto body = cast(string) captured.body;
    assert(body.canFind(`name="payload_json"`));
    assert(body.canFind(`"content":"with-file"`));
    assert(body.canFind(`name="files[0]"; filename="hello.txt"`));
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpMethod, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import std.algorithm : canFind;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = request.method == HttpMethod.Post ? 200 : 204;
        response.body = cast(ubyte[]) `{"id":"55","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    Message source;
    source.id = Snowflake(55);
    source.channelId = Snowflake(99);
    ctx.message = Nullable!Message.of(source);

    auto reacted = ctx.react("✅").awaitResult();
    assert(reacted.isOk);
    assert(captured[0].url.canFind("/channels/99/messages/55/reactions/"));

    auto pinned = ctx.pin(Nullable!string.of("pin reason")).awaitResult();
    assert(pinned.isOk);
    assert(captured[1].url.canFind("/channels/99/pins/55"));
    assert(captured[1].headers.get("X-Audit-Log-Reason", "") == "pin%20reason");

    auto crossposted = ctx.crosspost().awaitResult();
    assert(crossposted.isOk);
    assert(captured[2].url.canFind("/channels/99/messages/55/crosspost"));
}

unittest
{
    import std.algorithm : canFind;

    CommandContext ctx;
    auto reacted = ctx.react("✅").awaitResult();
    assert(reacted.isErr);
    assert(reacted.error.canFind("no source message"));

    auto pinned = ctx.pin().awaitResult();
    assert(pinned.isErr);

    auto crossposted = ctx.crosspost().awaitResult();
    assert(crossposted.isErr);
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;
    import std.json : JSONType, JSONValue, parseJSON;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext prefixCtx;
    prefixCtx.rest = new RestClient(config);
    prefixCtx.currentChannel.id = Snowflake(99);
    prefixCtx.source = CommandSource.Prefix;

    auto denied = prefixCtx.send("secret", true).awaitResult();
    assert(denied.isErr);
    assert(denied.error.canFind("Ephemeral responses require an active interaction token"));
    assert(captured.length == 0);

    CommandContext slashCtx;
    slashCtx.rest = new RestClient(config);
    slashCtx.source = CommandSource.Slash;
    Interaction interaction;
    interaction.id = Snowflake(33);
    interaction.token = "abc";
    slashCtx.interaction = Nullable!Interaction.of(interaction);

    auto responded = slashCtx.asSlash().respondEphemeral("secret").awaitResult();
    assert(responded.isOk);
    assert(captured.length == 1);
    assert(captured[0].url.canFind("/interactions/33/abc/callback"));

    auto payload = parseJSON(cast(string) captured[0].body);
    auto data = payload.object.get("data", JSONValue.init);
    assert(data.object.get("flags", JSONValue.init).integer == cast(long) MessageFlags.Ephemeral);
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;
    import std.json : JSONType, JSONValue, parseJSON;

    HttpRequest captured;
    HttpTransport transport = (request) {
        captured = request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"1","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.currentChannel.id = Snowflake(99);
    ctx.source = CommandSource.Prefix;

    auto sent = ctx.asHybrid().respond("hello", true).awaitResult();
    assert(sent.isOk);
    assert(captured.url.canFind("/channels/99/messages"));

    auto payload = parseJSON(cast(string) captured.body);
    auto dataFlags = payload.object.get("flags", JSONValue.init);
    assert(dataFlags.type == JSONType.null_);
}
