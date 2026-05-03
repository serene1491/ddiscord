/**
 * ddiscord — event contexts.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.context.event;

import ddiscord.cache : CacheStore;
import ddiscord.context.command : CommandContext, CommandSource, ContextMenuContext,
    HybridContext, PrefixContext, SlashContext;
import ddiscord.interactions.components : ComponentType;
import ddiscord.logging : Logger;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild, UnavailableGuild;
import ddiscord.models.interaction : Interaction, InteractionSubmittedComponent;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.rest : RestClient;
import ddiscord.services : ServiceContainer;
import ddiscord.state : StateStore;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.json : JSONValue;

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

/// Guild-create event context.
struct GuildCreateEventContext
{
    EventContext event;
    alias event this;
    Guild guildData;
}

/// Guild-delete event context.
struct GuildDeleteEventContext
{
    EventContext event;
    alias event this;
    UnavailableGuild guildData;
}

/// Guild-update event context.
struct GuildUpdateEventContext
{
    EventContext event;
    alias event this;
    Guild guildData;
}

/// Guild member remove event context.
struct GuildMemberRemoveEventContext
{
    EventContext event;
    alias event this;
    User userData;
}

/// Guild-member event context.
struct GuildMemberAddEventContext
{
    EventContext event;
    alias event this;
    GuildMember memberData;
}

/// Guild-ban add event context.
struct GuildBanAddEventContext
{
    EventContext event;
    alias event this;
    Snowflake guildId;
    User userData;
}

/// Guild-ban remove event context.
struct GuildBanRemoveEventContext
{
    EventContext event;
    alias event this;
    Snowflake guildId;
    User userData;
}

/// Channel-create event context.
struct ChannelCreateEventContext
{
    EventContext event;
    alias event this;
    Channel channelData;
}

/// Channel-update event context.
struct ChannelUpdateEventContext
{
    EventContext event;
    alias event this;
    Channel channelData;
}

/// Channel-delete event context.
struct ChannelDeleteEventContext
{
    EventContext event;
    alias event this;
    Channel channelData;
}

/// Channel pins update event context.
struct ChannelPinsUpdateEventContext
{
    EventContext event;
    alias event this;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    string lastPinTimestamp;
}

/// Message-create event context.
struct MessageCreateEventContext
{
    EventContext event;
    alias event this;
    Message message;
}

/// Message-update event context.
struct MessageUpdateEventContext
{
    EventContext event;
    alias event this;
    Message message;
}

/// Message-delete event context.
struct MessageDeleteEventContext
{
    EventContext event;
    alias event this;
    Snowflake messageId;
    Nullable!Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Message bulk-delete event context.
struct MessageDeleteBulkEventContext
{
    EventContext event;
    alias event this;
    Snowflake[] messageIds;
    Nullable!Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Message reaction add event context.
struct MessageReactionAddEventContext
{
    EventContext event;
    alias event this;
    Snowflake userId;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
}

/// Message reaction remove event context.
struct MessageReactionRemoveEventContext
{
    EventContext event;
    alias event this;
    Snowflake userId;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
}

/// Message reaction remove-all event context.
struct MessageReactionRemoveAllEventContext
{
    EventContext event;
    alias event this;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
}

/// Message reaction remove-emoji event context.
struct MessageReactionRemoveEmojiEventContext
{
    EventContext event;
    alias event this;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
}

/// Base interaction event context.
struct InteractionCreateEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
}

/// Raw gateway-dispatch event context.
struct GatewayDispatchEventContext
{
    EventContext event;
    alias event this;
    string eventName;
    JSONValue payload;
    Nullable!long sequence;
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
    ComponentType componentType;
    string customId;
    string[] values;
    InteractionSubmittedComponent[] submittedComponents;
}

/// Button component interaction event context.
struct ButtonComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
}

/// String select component interaction event context.
struct StringSelectComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
    string[] values;
}

/// User select component interaction event context.
struct UserSelectComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
    string[] values;
}

/// Role select component interaction event context.
struct RoleSelectComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
    string[] values;
}

/// Mentionable select component interaction event context.
struct MentionableSelectComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
    string[] values;
}

/// Channel select component interaction event context.
struct ChannelSelectComponentEventContext
{
    EventContext event;
    alias event this;
    Interaction interaction;
    string customId;
    string[] values;
}

/// Event context for messages that mention the current client user.
struct BotMentionEventContext
{
    EventContext event;
    alias event this;
    Message message;
}

/// Event context for messages that begin with the configured prefix.
struct PrefixMessageEventContext
{
    EventContext event;
    alias event this;
    Message message;
    string commandName;
    string rawArguments;
    bool knownCommand;
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

/// User-update event context.
struct UserUpdateEventContext
{
    EventContext event;
    alias event this;
    User userData;
}

/// Typing-start event context.
struct TypingStartEventContext
{
    EventContext event;
    alias event this;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    Snowflake userId;
    long timestampUnix;
}

/// Voice-state update event context.
struct VoiceStateUpdateEventContext
{
    EventContext event;
    alias event this;
    Nullable!Snowflake guildId;
    Nullable!Snowflake channelId;
    Snowflake userId;
    string sessionId;
    bool deaf;
    bool mute;
    bool selfDeaf;
    bool selfMute;
    bool selfStream;
    bool selfVideo;
    bool suppress;
}

/// Voice-server update event context.
struct VoiceServerUpdateEventContext
{
    EventContext event;
    alias event this;
    Nullable!Snowflake guildId;
    string token;
    string endpoint;
}

/// Guild role create event context.
struct GuildRoleCreateEventContext
{
    EventContext event;
    alias event this;
    Snowflake guildId;
    Role roleData;
}

/// Guild role update event context.
struct GuildRoleUpdateEventContext
{
    EventContext event;
    alias event this;
    Snowflake guildId;
    Role roleData;
}

/// Guild role delete event context.
struct GuildRoleDeleteEventContext
{
    EventContext event;
    alias event this;
    Snowflake guildId;
    Snowflake roleId;
}

/// Invite create event context.
struct InviteCreateEventContext
{
    EventContext event;
    alias event this;
    string code;
    Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Invite delete event context.
struct InviteDeleteEventContext
{
    EventContext event;
    alias event this;
    string code;
    Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Webhooks update event context.
struct WebhooksUpdateEventContext
{
    EventContext event;
    alias event this;
    Snowflake channelId;
    Nullable!Snowflake guildId;
}

/// Thread create event context.
struct ThreadCreateEventContext
{
    EventContext event;
    alias event this;
    Channel threadData;
}

/// Thread update event context.
struct ThreadUpdateEventContext
{
    EventContext event;
    alias event this;
    Channel threadData;
}

/// Thread delete event context.
struct ThreadDeleteEventContext
{
    EventContext event;
    alias event this;
    Snowflake threadId;
    Nullable!Snowflake guildId;
    Nullable!Snowflake parentId;
}

/// Command success event context.
struct CommandExecutedEventContext
{
    EventContext event;
    alias event this;
    string commandName;
    CommandContext command;

    Nullable!PrefixContext prefix() @property
    {
        if (command.source != CommandSource.Prefix)
            return Nullable!PrefixContext.init;
        return Nullable!PrefixContext.of(command.asPrefix());
    }

    Nullable!SlashContext slash() @property
    {
        if (command.source != CommandSource.Slash)
            return Nullable!SlashContext.init;
        return Nullable!SlashContext.of(command.asSlash());
    }

    Nullable!ContextMenuContext contextMenu() @property
    {
        if (command.source != CommandSource.ContextMenu)
            return Nullable!ContextMenuContext.init;
        return Nullable!ContextMenuContext.of(command.asContextMenu());
    }

    Nullable!HybridContext hybrid() @property
    {
        if (command.source == CommandSource.ContextMenu)
            return Nullable!HybridContext.init;
        return Nullable!HybridContext.of(command.asHybrid());
    }
}

/// Command failure event context.
struct CommandFailedEventContext
{
    EventContext event;
    alias event this;
    string commandName;
    CommandContext command;

    Nullable!PrefixContext prefix() @property
    {
        if (command.source != CommandSource.Prefix)
            return Nullable!PrefixContext.init;
        return Nullable!PrefixContext.of(command.asPrefix());
    }

    Nullable!SlashContext slash() @property
    {
        if (command.source != CommandSource.Slash)
            return Nullable!SlashContext.init;
        return Nullable!SlashContext.of(command.asSlash());
    }

    Nullable!ContextMenuContext contextMenu() @property
    {
        if (command.source != CommandSource.ContextMenu)
            return Nullable!ContextMenuContext.init;
        return Nullable!ContextMenuContext.of(command.asContextMenu());
    }

    Nullable!HybridContext hybrid() @property
    {
        if (command.source == CommandSource.ContextMenu)
            return Nullable!HybridContext.init;
        return Nullable!HybridContext.of(command.asHybrid());
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
