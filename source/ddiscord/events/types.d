/**
 * ddiscord — event types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.events.types;

import ddiscord.context.event : AutocompleteInteractionEventContext, CommandExecutedEventContext,
    CommandFailedEventContext, GuildMemberAddEventContext, InteractionCreateEventContext,
    MessageComponentEventContext, MessageCreateEventContext, ModalSubmitEventContext,
    PresenceUpdateEventContext, ReadyEventContext, ResumedEventContext;
import ddiscord.models.guild : UnavailableGuild;
import ddiscord.models.interaction : Interaction;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.presence : Activity, StatusType;
import ddiscord.models.user : User;

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
