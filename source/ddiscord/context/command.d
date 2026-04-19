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
import ddiscord.models.interaction : Interaction;
import ddiscord.models.message : Message, MessageCreate, MessageFlags;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.tasks : Task;
import ddiscord.util.errors : formatError;
import ddiscord.util.optional : Nullable;

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

    /// Reply overload for string content.
    Task!void reply(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return reply(payload, ephemeral);
    }

    /// Reply overload for payloads.
    Task!void reply(MessageCreate payload, bool ephemeral = false)
    {
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);

        if (!interaction.isNull && interaction.get.token.length != 0)
        {
            if (interactionAcknowledged || interactionResponded)
            {
                auto created = rest.interactions.followupMessage(interaction.get.token, payload).awaitResult();
                if (created.isErr)
                    return Task!void.failure(created.error);

                return Task!void.success();
            }

            auto sent = rest.interactions.respondMessage(interaction.get.id, interaction.get.token, payload).awaitResult();
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

    /// Sends a deferred acknowledgement for interaction-based commands.
    Task!void defer(bool ephemeral = false)
    {
        if (!interaction.isNull && interaction.get.token.length != 0)
        {
            auto deferred = rest.interactions.deferMessage(interaction.get.id, interaction.get.token, ephemeral).awaitResult();
            if (deferred.isErr)
                return Task!void.failure(deferred.error);

            interactionAcknowledged = true;
            return Task!void.success();
        }

        return Task!void.success();
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

        auto sent = rest.interactions.respondAutocomplete(interaction.get.id, interaction.get.token, choices).awaitResult();
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

        auto sent = rest.interactions.respondModal(interaction.get.id, interaction.get.token, modal).awaitResult();
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

        auto created = rest.interactions.followupMessage(interaction.get.token, payload).awaitResult();
        if (created.isErr)
            return Task!void.failure(created.error);

        interactionResponded = true;
        return Task!void.success();
    }

    /// Edits the original interaction response.
    Task!void editOriginal(string content, bool ephemeral = false)
    {
        auto payload = MessageCreate(content);
        if (ephemeral)
            payload.setFlag(MessageFlags.Ephemeral);
        return editOriginal(payload);
    }

    /// Edits the original interaction response payload.
    Task!void editOriginal(MessageCreate payload)
    {
        if (interaction.isNull || interaction.get.token.length == 0)
        {
            return Task!void.failure(formatError(
                "context",
                "Editing the original interaction response requires an active interaction token.",
                "",
                "Call `editOriginal` only after handling a real interaction."
            ));
        }

        auto edited = rest.interactions.editOriginalMessage(interaction.get.token, payload).awaitResult();
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
}
