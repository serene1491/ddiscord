/**
 * ddiscord — event types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.events.types;

import ddiscord.context.event : AutocompleteInteractionEventContext, ChannelCreateEventContext,
    ChannelDeleteEventContext, ChannelPinsUpdateEventContext, ChannelUpdateEventContext,
    CommandExecutedEventContext, CommandFailedEventContext, GuildCreateEventContext,
    GuildDeleteEventContext, GuildMemberAddEventContext, GuildMemberRemoveEventContext,
    GuildRoleCreateEventContext, GuildRoleDeleteEventContext, GuildRoleUpdateEventContext,
    InteractionCreateEventContext, InviteCreateEventContext, InviteDeleteEventContext,
    MessageComponentEventContext, MessageCreateEventContext, MessageDeleteEventContext,
    MessageReactionAddEventContext, MessageReactionRemoveAllEventContext,
    MessageReactionRemoveEmojiEventContext, MessageReactionRemoveEventContext,
    MessageUpdateEventContext, ModalSubmitEventContext, PresenceUpdateEventContext,
    ReadyEventContext, ResumedEventContext, ThreadCreateEventContext, ThreadDeleteEventContext,
    ThreadUpdateEventContext, TypingStartEventContext, WebhooksUpdateEventContext;
import ddiscord.models.guild : Guild, UnavailableGuild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.models.channel : Channel;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;

/// Ready gateway event.
struct ReadyEvent
{
    uint gatewayVersion;
    User selfUser;
    UnavailableGuild[] guilds;
    string sessionId;
    string resumeGatewayUrl;
    ReadyEventContext context;
}

/// Gateway resumed event.
struct ResumedEvent
{
    ResumedEventContext context;
}

/// Guild create event.
struct GuildCreateEvent
{
    Guild guild;
    GuildCreateEventContext context;
}

/// Guild delete/unavailable event.
struct GuildDeleteEvent
{
    UnavailableGuild guild;
    GuildDeleteEventContext context;
}

/// Guild member remove event.
struct GuildMemberRemoveEvent
{
    User user;
    Nullable!Snowflake guildId;
    GuildMemberRemoveEventContext context;
}

/// Guild member add event.
struct GuildMemberAddEvent
{
    GuildMember member;

    struct GuildSnapshot
    {
        size_t memberCount;
    }

    GuildSnapshot guild;
    GuildMemberAddEventContext context;
}

/// Message create event.
struct MessageCreateEvent
{
    Message message;
    MessageCreateEventContext context;
}

/// Message update event.
struct MessageUpdateEvent
{
    Message message;
    MessageUpdateEventContext context;
}

/// Message delete event.
struct MessageDeleteEvent
{
    Snowflake messageId;
    Nullable!Snowflake channelId;
    Nullable!Snowflake guildId;
    MessageDeleteEventContext context;
}

/// Message reaction add event.
struct MessageReactionAddEvent
{
    Snowflake userId;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
    MessageReactionAddEventContext context;
}

/// Message reaction remove event.
struct MessageReactionRemoveEvent
{
    Snowflake userId;
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
    MessageReactionRemoveEventContext context;
}

/// Message reaction remove-all event.
struct MessageReactionRemoveAllEvent
{
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    MessageReactionRemoveAllEventContext context;
}

/// Message reaction remove-emoji event.
struct MessageReactionRemoveEmojiEvent
{
    Snowflake channelId;
    Snowflake messageId;
    Nullable!Snowflake guildId;
    string emojiName;
    MessageReactionRemoveEmojiEventContext context;
}

/// Channel create event.
struct ChannelCreateEvent
{
    Channel channel;
    ChannelCreateEventContext context;
}

/// Channel update event.
struct ChannelUpdateEvent
{
    Channel channel;
    ChannelUpdateEventContext context;
}

/// Channel delete event.
struct ChannelDeleteEvent
{
    Channel channel;
    ChannelDeleteEventContext context;
}

/// Channel pins update event.
struct ChannelPinsUpdateEvent
{
    Snowflake channelId;
    Nullable!Snowflake guildId;
    string lastPinTimestamp;
    ChannelPinsUpdateEventContext context;
}

/// Interaction create event.
struct InteractionCreateEvent
{
    Interaction interaction;
    InteractionCreateEventContext context;
}

/// Low-level autocomplete interaction event.
struct AutocompleteInteractionEvent
{
    Interaction interaction;
    AutocompleteInteractionEventContext context;
}

/// Message component interaction event.
struct MessageComponentEvent
{
    Interaction interaction;
    MessageComponentEventContext context;
}

/// Modal submit interaction event.
struct ModalSubmitEvent
{
    Interaction interaction;
    ModalSubmitEventContext context;
}

/// Presence update event.
struct PresenceUpdateEvent
{
    StatusType status;
    Activity activity;
    PresenceUpdateEventContext context;
}

/// Typing start event.
struct TypingStartEvent
{
    Snowflake channelId;
    Nullable!Snowflake guildId;
    Snowflake userId;
    long timestampUnix;
    TypingStartEventContext context;
}

/// Guild role create event.
struct GuildRoleCreateEvent
{
    Snowflake guildId;
    Role role;
    GuildRoleCreateEventContext context;
}

/// Guild role update event.
struct GuildRoleUpdateEvent
{
    Snowflake guildId;
    Role role;
    GuildRoleUpdateEventContext context;
}

/// Guild role delete event.
struct GuildRoleDeleteEvent
{
    Snowflake guildId;
    Snowflake roleId;
    GuildRoleDeleteEventContext context;
}

/// Invite create event.
struct InviteCreateEvent
{
    string code;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    InviteCreateEventContext context;
}

/// Invite delete event.
struct InviteDeleteEvent
{
    string code;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    InviteDeleteEventContext context;
}

/// Webhooks update event.
struct WebhooksUpdateEvent
{
    Snowflake channelId;
    Nullable!Snowflake guildId;
    WebhooksUpdateEventContext context;
}

/// Thread create event.
struct ThreadCreateEvent
{
    Channel thread;
    ThreadCreateEventContext context;
}

/// Thread update event.
struct ThreadUpdateEvent
{
    Channel thread;
    ThreadUpdateEventContext context;
}

/// Thread delete event.
struct ThreadDeleteEvent
{
    Snowflake threadId;
    Nullable!Snowflake guildId;
    Nullable!Snowflake parentId;
    ThreadDeleteEventContext context;
}

/// Command execution success event.
struct CommandExecutedEvent
{
    string commandName;
    Message sourceMessage;
    User user;
    size_t replyCount;
    CommandExecutedEventContext context;
}

/// Command execution failure event.
struct CommandFailedEvent
{
    string attemptedName;
    Message sourceMessage;
    User user;
    string error;
    CommandFailedEventContext context;
}
