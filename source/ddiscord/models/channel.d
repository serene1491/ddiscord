/**
 * ddiscord — channel models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.channel;

import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue;

/// Discord channel kinds.
enum ChannelType : int
{
    GuildText = 0,
    DirectMessage = 1,
    GuildVoice = 2,
    GroupDirectMessage = 3,
    GuildCategory = 4,
    GuildAnnouncement = 5,
    AnnouncementThread = 10,
    PublicThread = 11,
    PrivateThread = 12,
    GuildStageVoice = 13,
    GuildDirectory = 14,
    GuildForum = 15,
    GuildMedia = 16,
}

/// Channel permission overwrite target type.
enum PermissionOverwriteType : int
{
    Role = 0,
    Member = 1,
}

/// Channel permission overwrite entry.
struct PermissionOverwrite
{
    Snowflake id;
    PermissionOverwriteType kind = PermissionOverwriteType.Role;
    ulong allow;
    ulong deny;

    static PermissionOverwrite fromJSON(JSONValue json)
    {
        PermissionOverwrite overwrite;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            overwrite.id = Snowflake(idValue.str.to!ulong);

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            overwrite.kind = cast(PermissionOverwriteType) cast(int) typeValue.integer;

        auto allowValue = json.object.get("allow", JSONValue.init);
        if (allowValue.type != JSONType.null_)
            overwrite.allow = allowValue.str.to!ulong;

        auto denyValue = json.object.get("deny", JSONValue.init);
        if (denyValue.type != JSONType.null_)
            overwrite.deny = denyValue.str.to!ulong;

        return overwrite;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["type"] = cast(int) kind;
        json["allow"] = allow.to!string;
        json["deny"] = deny.to!string;
        return json;
    }
}

/// Discord channel model.
struct Channel
{
    Snowflake id;
    string name;
    ChannelType type = ChannelType.GuildText;
    Nullable!Snowflake guildId;
    PermissionOverwrite[] permissionOverwrites;

    /// Channel mention helper.
    string mention() const @property
    {
        return "<#" ~ id.toString ~ ">";
    }

    /// Parses a Discord channel payload.
    static Channel fromJSON(JSONValue json)
    {
        Channel channel;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            channel.id = Snowflake(idValue.str.to!ulong);

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            channel.name = nameValue.str;

        auto guildIdValue = json.object.get("guild_id", JSONValue.init);
        if (guildIdValue.type != JSONType.null_)
            channel.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            channel.type = cast(ChannelType) typeValue.integer;

        auto overwritesValue = json.object.get("permission_overwrites", JSONValue.init);
        if (overwritesValue.type == JSONType.array)
        {
            foreach (item; overwritesValue.array)
                channel.permissionOverwrites ~= PermissionOverwrite.fromJSON(item);
        }

        return channel;
    }

    /// Serializes the channel into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["name"] = name;
        json["type"] = cast(int) type;
        if (!guildId.isNull)
            json["guild_id"] = guildId.get.toString;
        if (permissionOverwrites.length != 0)
        {
            JSONValue[] values;
            foreach (overwrite; permissionOverwrites)
                values ~= overwrite.toJSON();
            json["permission_overwrites"] = values;
        }
        return json;
    }
}
