/**
 * ddiscord — event contexts.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.context.event;

import ddiscord.cache : CacheStore;
import ddiscord.context.command : CommandContext, CommandSource, ContextMenuCommandContext,
    HybridCommandContext, PrefixCommandContext, SlashCommandContext;
import ddiscord.logging : Logger;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild;
import ddiscord.models.interaction : Interaction, InteractionSubmittedComponent;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.util.optional : Nullable;

/// Shared event context surface with cached/current entities.
struct EventContext
{
    RestClient rest;
    ServiceContainer services;
    CacheStore cache;
    StateStore state;
    Logger logger;
    Nullable!User currentUser;
    Nullable!Guild currentGuild;
    Nullable!GuildMember currentMember;
    Nullable!Channel currentChannel;
    Nullable!Message currentMessage;
    Nullable!Interaction currentInteraction;

    Nullable!User user() @property
    {
        return currentUser;
    }

    Nullable!Guild guild() @property
    {
        return currentGuild;
    }

    Nullable!GuildMember member() @property
    {
        return currentMember;
    }

    Nullable!Channel channel() @property
    {
        return currentChannel;
    }

    Nullable!Message message() @property
    {
        return currentMessage;
    }

    Nullable!Interaction interaction() @property
    {
        return currentInteraction;
    }
}

/// Ready event context.
struct ReadyEventContext
{
    EventContext event;
    alias event this;
    User selfUser;
}

/// Resumed event context.
struct ResumedEventContext
{
    EventContext event;
    alias event this;
    User selfUser;
}

/// Guild-member event context.
struct GuildMemberAddEventContext
{
    EventContext event;
    alias event this;
    GuildMember memberData;
}

/// Message-create event context.
struct MessageCreateEventContext
{
    EventContext event;
    alias event this;
    Message message;
}

/// Base interaction event context.
struct InteractionCreateEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
}

/// Autocomplete interaction event context.
struct AutocompleteInteractionEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string focusedName;
    string focusedValue;
}

/// Message-component interaction event context.
struct MessageComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
}

/// Modal-submit interaction event context.
struct ModalSubmitEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    InteractionSubmittedComponent[] submittedComponents;
}

/// Presence update event context.
struct PresenceUpdateEventContext
{
    EventContext event;
    alias event this;
    StatusType status;
    Activity activity;
}

/// Command success event context.
struct CommandExecutedEventContext
{
    EventContext event;
    alias event this;
    string commandName;
    CommandContext command;

    Nullable!PrefixCommandContext prefix() @property
    {
        if (command.source != CommandSource.Prefix)
            return Nullable!PrefixCommandContext.init;
        return Nullable!PrefixCommandContext.of(command.asPrefix());
    }

    Nullable!SlashCommandContext slash() @property
    {
        if (command.source != CommandSource.Slash)
            return Nullable!SlashCommandContext.init;
        return Nullable!SlashCommandContext.of(command.asSlash());
    }

    Nullable!ContextMenuCommandContext contextMenu() @property
    {
        if (command.source != CommandSource.ContextMenu)
            return Nullable!ContextMenuCommandContext.init;
        return Nullable!ContextMenuCommandContext.of(command.asContextMenu());
    }

    Nullable!HybridCommandContext hybrid() @property
    {
        if (command.source == CommandSource.ContextMenu)
            return Nullable!HybridCommandContext.init;
        return Nullable!HybridCommandContext.of(command.asHybrid());
    }
}

/// Command failure event context.
struct CommandFailedEventContext
{
    EventContext event;
    alias event this;
    string commandName;
    CommandContext command;

    Nullable!PrefixCommandContext prefix() @property
    {
        if (command.source != CommandSource.Prefix)
            return Nullable!PrefixCommandContext.init;
        return Nullable!PrefixCommandContext.of(command.asPrefix());
    }

    Nullable!SlashCommandContext slash() @property
    {
        if (command.source != CommandSource.Slash)
            return Nullable!SlashCommandContext.init;
        return Nullable!SlashCommandContext.of(command.asSlash());
    }

    Nullable!ContextMenuCommandContext contextMenu() @property
    {
        if (command.source != CommandSource.ContextMenu)
            return Nullable!ContextMenuCommandContext.init;
        return Nullable!ContextMenuCommandContext.of(command.asContextMenu());
    }

    Nullable!HybridCommandContext hybrid() @property
    {
        if (command.source == CommandSource.ContextMenu)
            return Nullable!HybridCommandContext.init;
        return Nullable!HybridCommandContext.of(command.asHybrid());
    }
}

unittest
{
    CommandExecutedEventContext ctx;
    ctx.command.source = CommandSource.Prefix;

    assert(!ctx.prefix.isNull);
    assert(ctx.slash.isNull);
    assert(ctx.contextMenu.isNull);
    assert(!ctx.hybrid.isNull);
}

unittest
{
    EventContext ctx;

    Message message;
    message.content = "hello";
    ctx.currentMessage = Nullable!Message.of(message);

    Interaction interaction;
    interaction.customId = "button:test";
    ctx.currentInteraction = Nullable!Interaction.of(interaction);

    assert(!ctx.message.isNull);
    assert(ctx.message.get.content == "hello");
    assert(!ctx.interaction.isNull);
    assert(ctx.interaction.get.customId == "button:test");
}
