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
import ddiscord.tasks : Task;
import ddiscord.util.errors : formatError;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;

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

    /// Sends a message in the current command context.
    Task!void send(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return send(payload, ephemeral);
    }

    /// Sends a payload in the current command context.
    Task!void send(MessageCreate payload, bool ephemeral = false)
    {
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (!interaction.isNull && interaction.get.token.length != 0)
        {
            if (interactionAcknowledged || interactionResponded)
            {
                auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
                if (created.isErr)
                    return Task!void.failure(created.error);

                return Task!void.success();
            }

            auto sent = rest.interactions.send(interaction.get.id, interaction.get.token, payload).awaitResult();
            if (sent.isErr)
                return Task!void.failure(sent.error);

            interactionResponded = true;
            return Task!void.success();
        }

        auto channelId = currentChannel.id;
        if (!message.isNull)
            channelId = message.get.channelId;

        auto created = rest.messages.create(channelId, payload).awaitResult();
        if (created.isErr)
            return Task!void.failure(created.error);

        return Task!void.success();
    }

    /// Replies to the source message using Discord's native reply payload.
    Task!void reply(string content, bool mentionAuthor = false, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        return reply(payload, mentionAuthor, ephemeral);
    }

    /// Replies to the source message using Discord's native reply payload.
    Task!void reply(MessageCreate payload, bool mentionAuthor = false, bool ephemeral = false)
    {
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (!message.isNull)
            return send(message.get.reply(payload, mentionAuthor), false);

        return send(payload, false);
    }

    /// Sends a deferred acknowledgement for interaction-based commands.
    Task!void defer(bool ephemeral = false)
    {
        if (!interaction.isNull && interaction.get.token.length != 0)
        {
            auto deferred = rest.interactions.defer(interaction.get.id, interaction.get.token, ephemeral).awaitResult();
            if (deferred.isErr)
                return Task!void.failure(deferred.error);

            interactionAcknowledged = true;
            return Task!void.success();
        }

        return Task!void.success();
    }

    /// Triggers the typing indicator for message-based contexts.
    Task!void typing()
    {
        if (!interaction.isNull && interaction.get.token.length != 0)
            return Task!void.success();

        auto channelId = currentChannelId();
        if (channelId.value == 0)
        {
            return Task!void.failure(formatError(
                "context",
                "The typing indicator requires a channel id.",
                "",
                "Populate `CommandContext.currentChannel` or `CommandContext.message` before calling `typing()`."
            ));
        }

        auto sent = rest.channels.typing(channelId).awaitResult();
        if (sent.isErr)
            return Task!void.failure(sent.error);

        return Task!void.success();
    }

    /// Shows a "thinking" state appropriate for the current command source.
    Task!void think(bool ephemeral = false)
    {
        if (!interaction.isNull && interaction.get.token.length != 0)
        {
            if (interactionAcknowledged || interactionResponded)
                return Task!void.success();

            return defer(ephemeral);
        }

        return typing();
    }

    /// Sends autocomplete choices for the current interaction.
    Task!void autocomplete(AutocompleteChoice[] choices)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return Task!void.failure(formatError(
                "context",
                "Autocomplete responses require an active interaction token.",
                "",
                "Call `autocomplete` only from an autocomplete interaction handler."
            ));
        }

        auto sent = rest.interactions.autocomplete(interaction.get.id, interaction.get.token, choices).awaitResult();
        if (sent.isErr)
            return Task!void.failure(sent.error);

        interactionResponded = true;
        return Task!void.success();
    }

    /// Opens a modal in response to the current interaction.
    Task!void showModal(Modal modal)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return Task!void.failure(formatError(
                "context",
                "Opening a modal requires an active interaction token.",
                "",
                "Call `showModal` only while handling a real interaction."
            ));
        }

        auto sent = rest.interactions.modal(interaction.get.id, interaction.get.token, modal).awaitResult();
        if (sent.isErr)
            return Task!void.failure(sent.error);

        interactionResponded = true;
        return Task!void.success();
    }

    /// Sends a follow-up message for a deferred or already-acknowledged interaction.
    Task!void followup(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return followup(payload);
    }

    /// Sends a follow-up payload for a deferred or already-acknowledged interaction.
    Task!void followup(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return Task!void.failure(formatError(
                "context",
                "Interaction follow-up messages require an active interaction token.",
                "",
                "Defer or respond to a real interaction before sending follow-up messages."
            ));
        }

        auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
        if (created.isErr)
            return Task!void.failure(created.error);

        interactionResponded = true;
        return Task!void.success();
    }

    /// Edits the original interaction response.
    Task!void edit(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return edit(payload);
    }

    /// Edits the original interaction response payload.
    Task!void edit(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return Task!void.failure(formatError(
                "context",
                "Editing the original interaction response requires an active interaction token.",
                "",
                "Call `edit` only after handling a real interaction."
            ));
        }

        auto edited = rest.interactions.edit(interaction.get.token, payload).awaitResult();
        if (edited.isErr)
            return Task!void.failure(edited.error);

        interactionResponded = true;
        interactionAcknowledged = true;
        return Task!void.success();
    }

    /// Context-menu target message, if any.
    Nullable!Message targetMessage() @property
    {
        if (interaction.isNull)
            return Nullable!Message.init;
        return interaction.get.targetMessage;
    }

    /// Returns this context as a prefix command context.
    PrefixCommandContext asPrefix()
    {
        PrefixCommandContext ctx;
        ctx.command = this;
        return ctx;
    }

    /// Returns this context as a slash command context.
    SlashCommandContext asSlash()
    {
        SlashCommandContext ctx;
        ctx.command = this;
        return ctx;
    }

    /// Returns this context as a context-menu command context.
    ContextMenuCommandContext asContextMenu()
    {
        ContextMenuCommandContext ctx;
        ctx.command = this;
        return ctx;
    }

    /// Returns this context as a hybrid command context.
    HybridCommandContext asHybrid()
    {
        HybridCommandContext ctx;
        ctx.command = this;
        return ctx;
    }

    private Snowflake currentChannelId() const
    {
        if (!message.isNull && message.get.channelId.value != 0)
            return message.get.channelId;
        return currentChannel.id;
    }
}

/// Prefix/text command context.
struct PrefixCommandContext
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
}

/// Slash command context.
struct SlashCommandContext
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
}

/// Context-menu command context.
struct ContextMenuCommandContext
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
struct HybridCommandContext
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

    Nullable!PrefixCommandContext prefix() @property
    {
        if (!fromPrefix)
            return Nullable!PrefixCommandContext.init;
        return Nullable!PrefixCommandContext.of(command.asPrefix());
    }

    Nullable!SlashCommandContext slash() @property
    {
        if (!fromSlash)
            return Nullable!SlashCommandContext.init;
        return Nullable!SlashCommandContext.of(command.asSlash());
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
    import std.json : JSONValue, parseJSON;

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
