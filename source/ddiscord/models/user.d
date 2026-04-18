/**
 * ddiscord — user models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.user;

import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue;

/// Discord user model.
struct User
{
    Snowflake id;
    string username;
    Nullable!string globalName;
    bool bot;
    Nullable!string avatar;

    /// User mention helper.
    string mention() const @property
    {
        return "<@" ~ id.toString ~ ">";
    }

    /// Returns an avatar URL if one is known.
    string avatarURL(string format = "webp", ushort size = 128) const
    {
        if (avatar.isNull)
            return "";

        return "https://cdn.discordapp.com/avatars/" ~ id.toString ~ "/" ~ avatar.get
            ~ "." ~ format ~ "?size=" ~ size.to!string;
    }

    /// Parses a Discord user payload.
    static User fromJSON(JSONValue json)
    {
        User user;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            user.id = Snowflake(idValue.str.to!ulong);

        auto usernameValue = json.object.get("username", JSONValue.init);
        if (usernameValue.type != JSONType.null_)
            user.username = usernameValue.str;

        auto globalNameValue = json.object.get("global_name", JSONValue.init);
        if (globalNameValue.type != JSONType.null_)
            user.globalName = Nullable!string.of(globalNameValue.str);

        auto avatarValue = json.object.get("avatar", JSONValue.init);
        if (avatarValue.type != JSONType.null_)
            user.avatar = Nullable!string.of(avatarValue.str);

        auto botValue = json.object.get("bot", JSONValue.init);
        if (botValue.type != JSONType.null_)
            user.bot = botValue.boolean;

        return user;
    }

    /// Serializes the user to JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["username"] = username;
        json["bot"] = bot;

        if (!globalName.isNull)
            json["global_name"] = globalName.get;
        if (!avatar.isNull)
            json["avatar"] = avatar.get;

        return json;
    }
}
