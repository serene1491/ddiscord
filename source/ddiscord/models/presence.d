/**
 * ddiscord — presence models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.presence;

import std.json : JSONType, JSONValue;

/// Activity kind.
enum ActivityType : int
{
    Playing = 0,
    Streaming = 1,
    Listening = 2,
    Watching = 3,
    Custom = 4,
    Competing = 5,
}

/// Presence status.
enum StatusType : string
{
    Online = "online",
    Idle = "idle",
    DoNotDisturb = "dnd",
    Invisible = "invisible",
    Offline = "offline",
}

/// Presence activity model.
struct Activity
{
    ActivityType type;
    string name;

    /// Parses a Discord activity payload.
    static Activity fromJSON(JSONValue json)
    {
        Activity activity;
        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            activity.type = activityTypeFromDiscord(cast(int) typeValue.integer);

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            activity.name = nameValue.str;

        return activity;
    }

    /// Serializes the activity into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) type;
        json["name"] = name;
        return json;
    }
}

/// Parses Discord presence status text into a typed enum.
StatusType statusFromDiscord(string status)
{
    switch (status)
    {
        case "online":
            return StatusType.Online;
        case "idle":
            return StatusType.Idle;
        case "dnd":
            return StatusType.DoNotDisturb;
        case "invisible":
            return StatusType.Invisible;
        case "offline":
            return StatusType.Offline;
        default:
            return StatusType.Offline;
    }
}

/// Parses Discord activity type integer into a typed enum.
ActivityType activityTypeFromDiscord(int value)
{
    switch (value)
    {
        case 0:
            return ActivityType.Playing;
        case 1:
            return ActivityType.Streaming;
        case 2:
            return ActivityType.Listening;
        case 3:
            return ActivityType.Watching;
        case 4:
            return ActivityType.Custom;
        case 5:
            return ActivityType.Competing;
        default:
            return ActivityType.Playing;
    }
}

unittest
{
    assert(statusFromDiscord("online") == StatusType.Online);
    assert(statusFromDiscord("dnd") == StatusType.DoNotDisturb);
    assert(statusFromDiscord("unknown") == StatusType.Offline);
}

unittest
{
    assert(activityTypeFromDiscord(0) == ActivityType.Playing);
    assert(activityTypeFromDiscord(5) == ActivityType.Competing);
    assert(activityTypeFromDiscord(77) == ActivityType.Playing);
}

unittest
{
    JSONValue payload;
    payload["type"] = 2;
    payload["name"] = "music";

    auto activity = Activity.fromJSON(payload);
    assert(activity.type == ActivityType.Listening);
    assert(activity.name == "music");
    assert(activity.toJSON().object.get("type", JSONValue.init).integer == 2);
}
