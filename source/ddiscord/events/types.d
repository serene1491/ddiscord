/**
 * ddiscord — event types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.events.types;

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
}

/// Gateway resumed event.
struct ResumedEvent
{
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
}

/// Message create event.
struct MessageCreateEvent
{
    Message message;
}

/// Interaction create event.
struct InteractionCreateEvent
{
    Interaction interaction;
}

/// Low-level autocomplete interaction event.
struct AutocompleteInteractionEvent
{
    Interaction interaction;
}

/// Message component interaction event.
struct MessageComponentEvent
{
    Interaction interaction;
}

/// Modal submit interaction event.
struct ModalSubmitEvent
{
    Interaction interaction;
}

/// Presence update event.
struct PresenceUpdateEvent
{
    StatusType status;
    Activity activity;
}

/// Command execution success event.
struct CommandExecutedEvent
{
    string commandName;
    Message sourceMessage;
    User user;
    size_t replyCount;
}

/// Command execution failure event.
struct CommandFailedEvent
{
    string attemptedName;
    Message sourceMessage;
    User user;
    string error;
}
