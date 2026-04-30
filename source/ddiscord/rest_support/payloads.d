/**
 * ddiscord — REST payload support types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.rest_support.payloads;

import ddiscord.util.optional : Nullable;
import std.json : JSONValue;

/// Interaction callback type.
enum InteractionCallbackType : int
{
    ChannelMessageWithSource = 4,
    DeferredChannelMessageWithSource = 5,
    DeferredUpdateMessage = 6,
    UpdateMessage = 7,
    ApplicationCommandAutocompleteResult = 8,
    Modal = 9,
}

/// Current-user update payload.
struct ModifyCurrentUser
{
    Nullable!string username;
    Nullable!string avatar;
    Nullable!string banner;

    JSONValue toJSON() const
    {
        JSONValue json;
        if (!username.isNull)
            json["username"] = username.get;
        if (!avatar.isNull)
            json["avatar"] = avatar.get;
        if (!banner.isNull)
            json["banner"] = banner.get;
        return json;
    }
}

/// Current-application update payload.
struct ModifyCurrentApplication
{
    Nullable!string description;

    JSONValue toJSON() const
    {
        JSONValue json;
        if (!description.isNull)
            json["description"] = description.get;
        return json;
    }
}
