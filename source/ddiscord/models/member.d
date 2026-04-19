/**
 * ddiscord — member models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.member;

import ddiscord.models.user : User;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue;

/// Guild member model.
struct GuildMember
{
    Nullable!User user;
    Nullable!string nick;
    Snowflake[] roleIds;
    ulong permissions;

    /// Mention helper.
    string mention() const @property
    {
        if (user.isNull)
            return "";
        return user.get.mention;
    }

    /// Parses a Discord guild-member payload.
    static GuildMember fromJSON(JSONValue json)
    {
        GuildMember member;

        auto userValue = json.object.get("user", JSONValue.init);
        if (userValue.type != JSONType.null_)
            member.user = Nullable!User.of(User.fromJSON(userValue));

        auto nickValue = json.object.get("nick", JSONValue.init);
        if (nickValue.type != JSONType.null_)
            member.nick = Nullable!string.of(nickValue.str);

        auto rolesValue = json.object.get("roles", JSONValue.init);
        if (rolesValue.type == JSONType.array)
        {
            foreach (item; rolesValue.array)
            {
                if (item.type != JSONType.null_)
                    member.roleIds ~= Snowflake(item.str.to!ulong);
            }
        }

        auto permissionsValue = json.object.get("permissions", JSONValue.init);
        if (permissionsValue.type != JSONType.null_)
            member.permissions = permissionsValue.str.to!ulong;

        return member;
    }

    /// Serializes the guild member into Discord JSON.
    JSONValue toJSON() const
    {
        JSONValue json;

        if (!user.isNull)
            json["user"] = user.get.toJSON();
        if (!nick.isNull)
            json["nick"] = nick.get;
        if (roleIds.length != 0)
        {
            JSONValue[] roles;
            foreach (roleId; roleIds)
                roles ~= JSONValue(roleId.toString);
            json["roles"] = roles;
        }
        if (permissions != 0)
            json["permissions"] = permissions.to!string;

        return json;
    }
}
