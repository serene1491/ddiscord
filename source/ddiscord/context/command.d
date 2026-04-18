/**
 * ddiscord — command context.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.context.command;

import ddiscord.cache : CacheStore;
import ddiscord.models.channel : Channel;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.message : Message, MessageCreate, MessageFlags;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.tasks : Task;
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

    /// Invoker shortcut.
    User user() const @property
    {
        return invoker;
    }

    /// Channel shortcut.
    Channel channel() const @property
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
            return rest.interactions.respondMessage(interaction.get.id, interaction.get.token, payload);

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
            return rest.interactions.deferMessage(interaction.get.id, interaction.get.token, ephemeral);

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
