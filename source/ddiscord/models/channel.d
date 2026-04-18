/**
 * ddiscord — channel models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.channel;

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

/// Discord channel model.
struct Channel
{
    Snowflake id;
    string name;
    ChannelType type = ChannelType.GuildText;

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

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            channel.type = cast(ChannelType) typeValue.integer;

        return channel;
    }

    /// Serializes the channel into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["name"] = name;
        json["type"] = cast(int) type;
        return json;
    }
}
