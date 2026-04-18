/**
 * ddiscord — role models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.role;

import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue;

/// Discord permissions bitmask.
enum Permissions : ulong
{
    CreateInstantInvite = 1UL << 0,
    KickMembers = 1UL << 1,
    BanMembers = 1UL << 2,
    Administrator = 1UL << 3,
    ManageChannels = 1UL << 4,
    ManageGuild = 1UL << 5,
    AddReactions = 1UL << 6,
    ViewAuditLog = 1UL << 7,
    PrioritySpeaker = 1UL << 8,
    Stream = 1UL << 9,
    ViewChannel = 1UL << 10,
    SendMessages = 1UL << 11,
    ManageMessages = 1UL << 13,
    EmbedLinks = 1UL << 14,
    AttachFiles = 1UL << 15,
    ReadMessageHistory = 1UL << 16,
    MentionEveryone = 1UL << 17,
    UseExternalEmojis = 1UL << 18,
    ManageRoles = 1UL << 28,
    ManageWebhooks = 1UL << 29,
    UseApplicationCommands = 1UL << 31,
    ManageEvents = 1UL << 33,
    ManageThreads = 1UL << 34,
    UseExternalStickers = 1UL << 37,
    SendMessagesInThreads = 1UL << 38,
    ModerateMembers = 1UL << 40,
}

/// Discord role model.
struct Role
{
    Snowflake id;
    string name;
    ulong permissions;

    /// Role mention helper.
    string mention() const @property
    {
        return "<@&" ~ id.toString ~ ">";
    }

    /// Parses a Discord role payload.
    static Role fromJSON(JSONValue json)
    {
        Role role;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            role.id = Snowflake(idValue.str.to!ulong);

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            role.name = nameValue.str;

        auto permissionsValue = json.object.get("permissions", JSONValue.init);
        if (permissionsValue.type != JSONType.null_)
            role.permissions = permissionsValue.str.to!ulong;

        return role;
    }

    /// Serializes the role into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["name"] = name;
        json["permissions"] = permissions.to!string;
        return json;
    }
}
