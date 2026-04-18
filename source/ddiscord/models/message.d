/**
 * ddiscord — message models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.message;

import ddiscord.models.attachment : Attachment;
import ddiscord.models.channel : Channel;
import ddiscord.models.embed : Embed;
import ddiscord.models.user : User;
import ddiscord.util.limits : DiscordMaxEmbedsPerMessage, DiscordMaxMessageLength;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue;

/// Discord message flags.
enum MessageFlags : uint
{
    None = 0,
    Crossposted = 1u << 0,
    SuppressEmbeds = 1u << 2,
    Ephemeral = 1u << 6,
    Loading = 1u << 7,
    IsComponentsV2 = 1u << 15,
}

/// Minimal message payload.
struct MessageCreate
{
    string content;
    Embed[] embeds;
    Object[] components;
    MessageFlags flags = MessageFlags.None;

    this(string content)
    {
        this.content = content;
    }

    MessageCreate withContent(string value)
    {
        content = value;
        return this;
    }

    MessageCreate withEmbed(Embed embed)
    {
        embeds ~= embed;
        return this;
    }

    MessageCreate addComponent(T)(T component)
    {
        components ~= cast(Object) new ComponentBox!T(component);
        return this;
    }

    MessageCreate setFlag(MessageFlags flag)
    {
        flags |= flag;
        return this;
    }

    /// Validates the message payload before a REST call.
    Result!(bool, string) validate() const
    {
        if (content.length > DiscordMaxMessageLength)
        {
            return Result!(bool, string).err(
                "Message content exceeds Discord's 2000 character limit. " ~
                "Current length: " ~ content.length.to!string ~ "."
            );
        }

        if (embeds.length > DiscordMaxEmbedsPerMessage)
        {
            return Result!(bool, string).err(
                "A single Discord message can contain at most 10 embeds. " ~
                "Current embed count: " ~ embeds.length.to!string ~ "."
            );
        }

        return Result!(bool, string).ok(true);
    }

    /// Serializes the payload into Discord REST JSON.
    JSONValue toJSON() const
    {
        JSONValue json;

        if (content.length != 0)
            json["content"] = content;
        if (flags != MessageFlags.None)
            json["flags"] = cast(uint) flags;

        if (embeds.length != 0)
        {
            JSONValue[] embedValues;
            foreach (embed; embeds)
                embedValues ~= embed.toJSON();
            json["embeds"] = embedValues;
        }

        return json;
    }
}

private final class ComponentBox(T) : Object
{
    T value;

    this(T value)
    {
        this.value = value;
    }
}

/// Discord message model.
struct Message
{
    Snowflake id;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    User author;
    string content;
    Embed[] embeds;
    Object[] components;
    MessageFlags flags = MessageFlags.None;
    Attachment[] attachments;

    /// Convenience reply payload.
    MessageCreate reply(string text) const
    {
        return MessageCreate(text);
    }

    /// Parses a Discord message payload.
    static Message fromJSON(JSONValue json)
    {
        Message message;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            message.id = Snowflake(idValue.str.to!ulong);

        auto channelIdValue = json.object.get("channel_id", JSONValue.init);
        if (channelIdValue.type != JSONType.null_)
            message.channelId = Snowflake(channelIdValue.str.to!ulong);

        auto guildIdValue = json.object.get("guild_id", JSONValue.init);
        if (guildIdValue.type != JSONType.null_)
            message.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));

        auto contentValue = json.object.get("content", JSONValue.init);
        if (contentValue.type != JSONType.null_)
            message.content = contentValue.str;

        auto authorValue = json.object.get("author", JSONValue.init);
        if (authorValue.type != JSONType.null_)
            message.author = User.fromJSON(authorValue);

        return message;
    }
}
