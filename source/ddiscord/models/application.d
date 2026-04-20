/**
 * ddiscord — application models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.application;

import ddiscord.models.user : User;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;

/// Discord team model subset used by application payloads.
struct Team
{
    Snowflake id;
    Nullable!Snowflake ownerUserId;

    /// Parses a Discord team payload.
    static Team fromJSON(JSONValue json)
    {
        Team team;
        if (json.type != JSONType.object)
            return team;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            team.id = Snowflake(idValue.str.to!ulong);

        auto ownerUserIdValue = json.object.get("owner_user_id", JSONValue.init);
        if (ownerUserIdValue.type != JSONType.null_)
            team.ownerUserId = Nullable!Snowflake.of(Snowflake(ownerUserIdValue.str.to!ulong));

        return team;
    }

    /// Serializes the team into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        if (!ownerUserId.isNull)
            json["owner_user_id"] = ownerUserId.get.toString;
        return json;
    }
}

/// Discord application model subset used by current-application REST calls.
struct Application
{
    Snowflake id;
    string description;
    Nullable!User owner;
    Nullable!Team team;

    /// Parses a Discord application payload.
    static Application fromJSON(JSONValue json)
    {
        Application application;
        if (json.type != JSONType.object)
            return application;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            application.id = Snowflake(idValue.str.to!ulong);

        auto descriptionValue = json.object.get("description", JSONValue.init);
        if (descriptionValue.type != JSONType.null_)
            application.description = descriptionValue.str;

        auto ownerValue = json.object.get("owner", JSONValue.init);
        if (ownerValue.type != JSONType.null_)
            application.owner = Nullable!User.of(User.fromJSON(ownerValue));

        auto teamValue = json.object.get("team", JSONValue.init);
        if (teamValue.type != JSONType.null_)
            application.team = Nullable!Team.of(Team.fromJSON(teamValue));

        return application;
    }

    /// Serializes the application into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["id"] = id.toString;
        json["description"] = description;

        if (!owner.isNull)
            json["owner"] = owner.get.toJSON();
        if (!team.isNull)
            json["team"] = team.get.toJSON();

        return json;
    }
}

unittest
{
    auto json = parseJSON(`{
        "id": "42",
        "description": "A helpful bot",
        "owner": {
            "id": "7",
            "username": "alice",
            "bot": false
        },
        "team": {
            "id": "99",
            "owner_user_id": "11"
        }
    }`);

    auto application = Application.fromJSON(json);
    assert(application.id == Snowflake(42));
    assert(application.description == "A helpful bot");
    assert(!application.owner.isNull);
    assert(application.owner.get.username == "alice");
    assert(!application.team.isNull);
    assert(application.team.get.ownerUserId.get == Snowflake(11));
}
