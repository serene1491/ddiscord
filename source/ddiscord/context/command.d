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
import std.algorithm.searching : canFind;

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
        auto sent = sendMessage(content, ephemeral).awaitResult();
        if (sent.isErr)
            return AsyncTask!void.failure(sent.error);

        return AsyncTask!void.success();
    }

    /// Sends a payload in the current command context.
    AsyncTask!void send(MessageCreate payload, bool ephemeral = false)
    {
        auto sent = sendMessage(payload, ephemeral).awaitResult();
        if (sent.isErr)
            return AsyncTask!void.failure(sent.error);

        return AsyncTask!void.success();
    }

    /// Sends a message and returns the created payload when Discord returns one.
    ///
    /// For initial interaction callback responses, Discord does not return the
    /// created message body; in that case this returns `Nullable!Message.init`.
    AsyncTask!(Nullable!Message) sendMessage(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        return sendMessage(payload, ephemeral);
    }

    /// Sends a payload and returns the created payload when Discord returns one.
    ///
    /// For initial interaction callback responses, Discord does not return the
    /// created message body; in that case this returns `Nullable!Message.init`.
    AsyncTask!(Nullable!Message) sendMessage(MessageCreate payload, bool ephemeral = false)
    {
        auto ephemeralError = validateEphemeralUsage(ephemeral, "send");
        if (!ephemeralError.isNull)
            return AsyncTask!(Nullable!Message).failure(ephemeralError.get);

        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (hasInteractionToken)
        {
            if (interactionAcknowledged || interactionResponded)
            {
                auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
                if (created.isErr)
                    return AsyncTask!(Nullable!Message).failure(created.error);

                interactionResponded = true;
                return AsyncTask!(Nullable!Message).success(Nullable!Message.of(created.value));
            }

            auto sent = rest.interactions.send(interaction.get.id, interaction.get.token, payload).awaitResult();
            if (sent.isErr)
            {
                if (isInteractionAlreadyAcknowledgedError(sent.error))
                {
                    interactionAcknowledged = true;
                    auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
                    if (created.isErr)
                        return AsyncTask!(Nullable!Message).failure(created.error);

                    interactionResponded = true;
                    return AsyncTask!(Nullable!Message).success(Nullable!Message.of(created.value));
                }

                return AsyncTask!(Nullable!Message).failure(sent.error);
            }

            interactionResponded = true;
            return AsyncTask!(Nullable!Message).success(Nullable!Message.init);
        }

        auto channelId = currentChannel.id;
        if (!message.isNull)
            channelId = message.get.channelId;

        auto created = rest.messages.create(channelId, payload).awaitResult();
        if (created.isErr)
            return AsyncTask!(Nullable!Message).failure(created.error);

        return AsyncTask!(Nullable!Message).success(Nullable!Message.of(created.value));
    }

    /// Sends a payload and always resolves a concrete response message.
    ///
    /// For initial interaction callback responses, this automatically fetches
    /// the `@original` interaction response so handlers can keep working with a
    /// concrete message value.
    AsyncTask!Message sendMessageResolved(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        return sendMessageResolved(payload, ephemeral);
    }

    /// Sends a payload and always resolves a concrete response message.
    ///
    /// For initial interaction callback responses, this automatically fetches
    /// the `@original` interaction response so handlers can keep working with a
    /// concrete message value.
    AsyncTask!Message sendMessageResolved(MessageCreate payload, bool ephemeral = false)
    {
        auto sent = sendMessage(payload, ephemeral).awaitResult();
        if (sent.isErr)
            return AsyncTask!Message.failure(sent.error);

        if (!sent.value.isNull)
            return AsyncTask!Message.success(sent.value.get);

        if (!hasInteractionToken)
        {
            return AsyncTask!Message.failure(formatError(
                "context",
                "Could not resolve a response message for this command context.",
                "",
                "Use `sendMessage` when a concrete response payload is not required."
            ));
        }

        auto fetched = rest.interactions.fetchOriginal(interaction.get.token).awaitResult();
        if (fetched.isErr)
            return AsyncTask!Message.failure(fetched.error);

        return AsyncTask!Message.success(fetched.value);
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
        auto replied = replyMessage(content, mentionAuthor, ephemeral).awaitResult();
        if (replied.isErr)
            return AsyncTask!void.failure(replied.error);

        return AsyncTask!void.success();
    }

    /// Replies to the source message using Discord's native reply payload.
    AsyncTask!void reply(MessageCreate payload, bool mentionAuthor = false, bool ephemeral = false)
    {
        auto replied = replyMessage(payload, mentionAuthor, ephemeral).awaitResult();
        if (replied.isErr)
            return AsyncTask!void.failure(replied.error);

        return AsyncTask!void.success();
    }

    /// Replies to the source and returns the created payload when Discord returns one.
    AsyncTask!(Nullable!Message) replyMessage(
        string content,
        bool mentionAuthor = false,
        bool ephemeral = false
    )
    {
        auto payload = MessageCreate(content);
        return replyMessage(payload, mentionAuthor, ephemeral);
    }

    /// Replies to the source and returns the created payload when Discord returns one.
    AsyncTask!(Nullable!Message) replyMessage(
        MessageCreate payload,
        bool mentionAuthor = false,
        bool ephemeral = false
    )
    {
        auto ephemeralError = validateEphemeralUsage(ephemeral, "reply");
        if (!ephemeralError.isNull)
            return AsyncTask!(Nullable!Message).failure(ephemeralError.get);

        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (!message.isNull)
            return sendMessage(message.get.reply(payload, mentionAuthor), false);

        return sendMessage(payload, false);
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
        auto created = followupMessage(content, ephemeral).awaitResult();
        if (created.isErr)
            return AsyncTask!void.failure(created.error);

        return AsyncTask!void.success();
    }

    /// Sends a follow-up payload for a deferred or already-acknowledged interaction.
    AsyncTask!void followup(MessageCreate payload)
    {
        auto created = followupMessage(payload).awaitResult();
        if (created.isErr)
            return AsyncTask!void.failure(created.error);

        return AsyncTask!void.success();
    }

    /// Sends a follow-up message and returns the created payload.
    AsyncTask!Message followupMessage(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return followupMessage(payload);
    }

    /// Sends a follow-up payload and returns the created payload.
    AsyncTask!Message followupMessage(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return AsyncTask!Message.failure(formatError(
                "context",
                "Interaction follow-up messages require an active interaction token.",
                "",
                "Defer or respond to a real interaction before sending follow-up messages."
            ));
        }

        auto created = rest.interactions.followup(interaction.get.token, payload).awaitResult();
        if (created.isErr)
            return AsyncTask!Message.failure(created.error);

        interactionResponded = true;
        return AsyncTask!Message.success(created.value);
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
        auto edited = editResponse(content, ephemeral).awaitResult();
        if (edited.isErr)
            return AsyncTask!void.failure(edited.error);

        return AsyncTask!void.success();
    }

    /// Edits the original interaction response payload.
    AsyncTask!void edit(MessageCreate payload)
    {
        auto edited = editResponse(payload).awaitResult();
        if (edited.isErr)
            return AsyncTask!void.failure(edited.error);

        return AsyncTask!void.success();
    }

    /// Edits the original interaction response and returns the updated payload.
    AsyncTask!Message editResponse(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return editResponse(payload);
    }

    /// Edits the original interaction response payload and returns the update.
    AsyncTask!Message editResponse(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return AsyncTask!Message.failure(formatError(
                "context",
                "Editing the original interaction response requires an active interaction token.",
                "",
                "Call `edit` only after handling a real interaction."
            ));
        }

        auto edited = rest.interactions.edit(interaction.get.token, payload).awaitResult();
        if (edited.isErr)
            return AsyncTask!Message.failure(edited.error);

        interactionResponded = true;
        interactionAcknowledged = true;
        return AsyncTask!Message.success(edited.value);
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

    private bool isInteractionAlreadyAcknowledgedError(string error) const
    {
        return error.canFind(`"code":40060`) ||
            error.canFind(`"code": 40060`) ||
            error.canFind("Interaction has already been acknowledged.");
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

    /// Prefix-friendly alias for `sendMessage`.
    AsyncTask!(Nullable!Message) respondMessage(string content)
    {
        return command.sendMessage(content);
    }

    /// Prefix-friendly alias for `sendMessage`.
    AsyncTask!(Nullable!Message) respondMessage(MessageCreate payload)
    {
        return command.sendMessage(payload);
    }

    /// Prefix-friendly alias for `sendMessageResolved`.
    AsyncTask!Message respondMessageResolved(string content)
    {
        return command.sendMessageResolved(content);
    }

    /// Prefix-friendly alias for `sendMessageResolved`.
    AsyncTask!Message respondMessageResolved(MessageCreate payload)
    {
        return command.sendMessageResolved(payload);
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

    /// Slash-friendly alias for `sendMessage`.
    AsyncTask!(Nullable!Message) respondMessage(string content, bool ephemeral = false)
    {
        return command.sendMessage(content, ephemeral);
    }

    /// Slash-friendly alias for `sendMessage`.
    AsyncTask!(Nullable!Message) respondMessage(MessageCreate payload, bool ephemeral = false)
    {
        return command.sendMessage(payload, ephemeral);
    }

    /// Slash-friendly alias for `sendMessageResolved`.
    AsyncTask!Message respondMessageResolved(string content, bool ephemeral = false)
    {
        return command.sendMessageResolved(content, ephemeral);
    }

    /// Slash-friendly alias for `sendMessageResolved`.
    AsyncTask!Message respondMessageResolved(MessageCreate payload, bool ephemeral = false)
    {
        return command.sendMessageResolved(payload, ephemeral);
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

    /// Unified response helper that returns created payloads when available.
    AsyncTask!(Nullable!Message) respondMessage(string content, bool ephemeralOnSlash = false)
    {
        if (fromSlash)
            return command.sendMessage(content, ephemeralOnSlash);
        return command.sendMessage(content);
    }

    /// Unified payload response helper that returns created payloads when available.
    AsyncTask!(Nullable!Message) respondMessage(MessageCreate payload, bool ephemeralOnSlash = false)
    {
        if (fromSlash)
            return command.sendMessage(payload, ephemeralOnSlash);
        return command.sendMessage(payload);
    }

    /// Unified response helper that always resolves a concrete message.
    AsyncTask!Message respondMessageResolved(string content, bool ephemeralOnSlash = false)
    {
        if (fromSlash)
            return command.sendMessageResolved(content, ephemeralOnSlash);
        return command.sendMessageResolved(content);
    }

    /// Unified payload response helper that always resolves a concrete message.
    AsyncTask!Message respondMessageResolved(MessageCreate payload, bool ephemeralOnSlash = false)
    {
        if (fromSlash)
            return command.sendMessageResolved(payload, ephemeralOnSlash);
        return command.sendMessageResolved(payload);
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

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;
    import std.json : JSONValue, parseJSON;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"id":"90","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.currentChannel.id = Snowflake(99);

    auto sent = ctx.sendMessage("hello").awaitResult();
    assert(sent.isOk);
    assert(!sent.value.isNull);
    assert(sent.value.get.id == Snowflake(90));

    Message source;
    source.id = Snowflake(55);
    source.channelId = Snowflake(99);
    ctx.message = Nullable!Message.of(source);

    auto replied = ctx.replyMessage("reply", true).awaitResult();
    assert(replied.isOk);
    assert(!replied.value.isNull);
    assert(captured.length == 2);

    auto body = parseJSON(cast(string) captured[1].body);
    auto reference = body.object.get("message_reference", JSONValue.init);
    assert(reference.object.get("message_id", JSONValue.init).str == "55");
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 200;
        if (request.url.canFind("/callback"))
            response.body = cast(ubyte[]) `{}`.dup;
        else
            response.body = cast(ubyte[]) `{"id":"42","channel_id":"99","content":"interaction-ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.source = CommandSource.Slash;
    Interaction interaction;
    interaction.id = Snowflake(33);
    interaction.token = "abc";
    ctx.interaction = Nullable!Interaction.of(interaction);

    auto initial = ctx.sendMessage("first", true).awaitResult();
    assert(initial.isOk);
    assert(initial.value.isNull);
    assert(captured.length == 1);

    auto followup = ctx.followupMessage("second", true).awaitResult();
    assert(followup.isOk);
    assert(followup.value.id == Snowflake(42));
    assert(captured.length >= 2);
    assert(captured[$ - 1].url.canFind("/webhooks/"));

    auto edited = ctx.editResponse("third", true).awaitResult();
    assert(edited.isOk);
    assert(edited.value.id == Snowflake(42));
    assert(captured.length >= 3);
    assert(captured[$ - 1].url.canFind("/messages/@original"));
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpErrorKind, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;

    HttpRequest[] captured;
    bool callbackFailedOnce;
    HttpTransport transport = (request) {
        captured ~= request;

        if (request.url.canFind("/callback") && !callbackFailedOnce)
        {
            callbackFailedOnce = true;
            HttpError error;
            error.kind = HttpErrorKind.UnexpectedStatus;
            error.method = "POST";
            error.url = request.url;
            error.statusCode = 400;
            error.responseBody = `{"message":"Interaction has already been acknowledged.","code":40060}`;
            error.message = "[ddiscord/http] Discord returned an unexpected HTTP status code. Detail: " ~
                error.responseBody ~ " Hint: Inspect the response body and headers for Discord's error details.";
            return Result!(HttpResponse, HttpError).err(error);
        }

        HttpResponse response;
        response.statusCode = 200;
        if (request.url.canFind("/webhooks/"))
            response.body = cast(ubyte[]) `{"id":"51","channel_id":"99","content":"fallback-followup","author":{"id":"2","username":"bot","bot":true}}`.dup;
        else
            response.body = cast(ubyte[]) `{}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.applicationId = Nullable!Snowflake.of(Snowflake(42));
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext ctx;
    ctx.rest = new RestClient(config);
    ctx.source = CommandSource.Slash;
    Interaction interaction;
    interaction.id = Snowflake(33);
    interaction.token = "abc";
    ctx.interaction = Nullable!Interaction.of(interaction);

    auto sent = ctx.sendMessage("first").awaitResult();
    assert(sent.isOk);
    assert(!sent.value.isNull);
    assert(sent.value.get.id == Snowflake(51));
    assert(captured.length == 2);
    assert(captured[0].url.canFind("/interactions/33/abc/callback"));
    assert(captured[1].url.canFind("/webhooks/42/abc"));
}

unittest
{
    import ddiscord.core.http.client : HttpError, HttpRequest, HttpResponse, HttpTransport;
    import ddiscord.rest : RestClientConfig;
    import ddiscord.util.result : Result;
    import ddiscord.util.snowflake : Snowflake;
    import std.algorithm : canFind;

    HttpRequest[] captured;
    HttpTransport transport = (request) {
        captured ~= request;

        HttpResponse response;
        response.statusCode = 200;
        if (request.url.canFind("/callback"))
            response.body = cast(ubyte[]) `{}`.dup;
        else if (request.url.canFind("/messages/@original"))
            response.body = cast(ubyte[]) `{"id":"88","channel_id":"99","content":"resolved","author":{"id":"2","username":"bot","bot":true}}`.dup;
        else
            response.body = cast(ubyte[]) `{"id":"77","channel_id":"99","content":"ok","author":{"id":"2","username":"bot","bot":true}}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    RestClientConfig config;
    config.token = "token";
    config.applicationId = Nullable!Snowflake.of(Snowflake(42));
    config.transport = Nullable!HttpTransport.of(transport);

    CommandContext interactionCtx;
    interactionCtx.rest = new RestClient(config);
    interactionCtx.source = CommandSource.Slash;
    Interaction interaction;
    interaction.id = Snowflake(33);
    interaction.token = "abc";
    interactionCtx.interaction = Nullable!Interaction.of(interaction);

    auto interactionMessage = interactionCtx.sendMessageResolved("first", true).awaitResult();
    assert(interactionMessage.isOk);
    assert(interactionMessage.value.id == Snowflake(88));
    assert(captured.length == 2);
    assert(captured[0].url.canFind("/interactions/33/abc/callback"));
    assert(captured[1].url.canFind("/webhooks/42/abc/messages/@original"));

    CommandContext prefixCtx;
    prefixCtx.rest = new RestClient(config);
    prefixCtx.currentChannel.id = Snowflake(99);

    auto prefixMessage = prefixCtx.sendMessageResolved("prefix").awaitResult();
    assert(prefixMessage.isOk);
    assert(prefixMessage.value.id == Snowflake(77));
    assert(captured.length == 3);
    assert(captured[2].url.canFind("/channels/99/messages"));
}
