/**
 * ddiscord — guild models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.guild;

import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue;

/// Placeholder guild descriptor included in READY before full guild state arrives.
struct UnavailableGuild
{
    Snowflake id;
    bool unavailable;

    /// Parses a Discord unavailable-guild payload.
    static UnavailableGuild fromJSON(JSONValue json)
    {
        UnavailableGuild guild;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            guild.id = Snowflake(idValue.str.to!ulong);

        auto unavailableValue = json.object.get("unavailable", JSONValue.init);
        if (unavailableValue.type == JSONType.true_ || unavailableValue.type == JSONType.false_)
            guild.unavailable = unavailableValue.boolean;

        return guild;
    }

    /// Serializes the unavailable guild into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["unavailable"] = unavailable;
        return json;
    }
}

/// Minimal Discord guild model used by the runtime.
struct Guild
{
    Snowflake id;
    string name;
    Nullable!Snowflake ownerId;

    /// Parses a Discord guild payload.
    static Guild fromJSON(JSONValue json)
    {
        Guild guild;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            guild.id = Snowflake(idValue.str.to!ulong);

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            guild.name = nameValue.str;

        auto ownerIdValue = json.object.get("owner_id", JSONValue.init);
        if (ownerIdValue.type != JSONType.null_)
            guild.ownerId = Nullable!Snowflake.of(Snowflake(ownerIdValue.str.to!ulong));

        return guild;
    }

    /// Serializes the guild into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["name"] = name;

        if (!ownerId.isNull)
            json["owner_id"] = ownerId.get.toString;

        return json;
    }
}

unittest
{
    auto json = JSONValue(["id": JSONValue("42"), "unavailable": JSONValue(true)]);
    auto guild = UnavailableGuild.fromJSON(json);
    assert(guild.id == Snowflake(42));
    assert(guild.unavailable);
}
