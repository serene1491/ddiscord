/**
 * ddiscord — message models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.message;

import ddiscord.interactions.components : IsComponentsV2Component, componentToJSON;
import ddiscord.models.attachment : Attachment;
import ddiscord.models.channel : Channel;
import ddiscord.models.embed : Embed;
import ddiscord.models.member : GuildMember;
import ddiscord.models.user : User;
import ddiscord.util.limits : DiscordMaxEmbedsPerMessage, DiscordMaxMessageLength;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;

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

/// Allowed mention parsing kinds.
enum AllowedMentionType
{
    Roles,
    Users,
    Everyone,
}

/// Message reference kinds.
enum MessageReferenceType : int
{
    Default = 0,
    Forward = 1,
}

/// Message reference payload.
struct MessageReference
{
    MessageReferenceType type = MessageReferenceType.Default;
    Nullable!Snowflake messageId;
    Nullable!Snowflake channelId;
    Nullable!Snowflake guildId;
    Nullable!bool failIfNotExists;

    /// Creates a standard reply reference.
    static MessageReference replyTo(
        Snowflake messageId,
        Nullable!Snowflake channelId = Nullable!Snowflake.init,
        Nullable!Snowflake guildId = Nullable!Snowflake.init
    )
    {
        MessageReference reference;
        reference.messageId = Nullable!Snowflake.of(messageId);
        reference.channelId = channelId;
        reference.guildId = guildId;
        return reference;
    }

    /// Parses a Discord message reference object.
    static MessageReference fromJSON(JSONValue json)
    {
        MessageReference reference;
        if (json.type != JSONType.object)
            return reference;

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            reference.type = cast(MessageReferenceType) cast(int) typeValue.integer;

        auto messageIdValue = json.object.get("message_id", JSONValue.init);
        if (messageIdValue.type != JSONType.null_)
            reference.messageId = Nullable!Snowflake.of(Snowflake(messageIdValue.str.to!ulong));

        auto channelIdValue = json.object.get("channel_id", JSONValue.init);
        if (channelIdValue.type != JSONType.null_)
            reference.channelId = Nullable!Snowflake.of(Snowflake(channelIdValue.str.to!ulong));

        auto guildIdValue = json.object.get("guild_id", JSONValue.init);
        if (guildIdValue.type != JSONType.null_)
            reference.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));

        auto failIfNotExistsValue = json.object.get("fail_if_not_exists", JSONValue.init);
        if (failIfNotExistsValue.type != JSONType.null_)
            reference.failIfNotExists = Nullable!bool.of(failIfNotExistsValue.boolean);

        return reference;
    }

    /// Serializes the reference into Discord REST JSON.
    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) type;

        if (!messageId.isNull)
            json["message_id"] = messageId.get.toString;
        if (!channelId.isNull)
            json["channel_id"] = channelId.get.toString;
        if (!guildId.isNull)
            json["guild_id"] = guildId.get.toString;
        if (!failIfNotExists.isNull)
            json["fail_if_not_exists"] = failIfNotExists.get;

        return json;
    }
}

/// Allowed mentions payload.
struct AllowedMentions
{
    AllowedMentionType[] parse;
    Snowflake[] roles;
    Snowflake[] users;
    Nullable!bool repliedUser;

    /// Parses Discord allowed-mentions JSON.
    static AllowedMentions fromJSON(JSONValue json)
    {
        AllowedMentions mentions;
        if (json.type != JSONType.object)
            return mentions;

        auto parseValue = json.object.get("parse", JSONValue.init);
        if (parseValue.type == JSONType.array)
        {
            foreach (item; parseValue.array)
            {
                if (item.type != JSONType.string)
                    continue;

                if (item.str == "roles")
                {
                    mentions.parse ~= AllowedMentionType.Roles;
                }
                else if (item.str == "users")
                {
                    mentions.parse ~= AllowedMentionType.Users;
                }
                else if (item.str == "everyone")
                {
                    mentions.parse ~= AllowedMentionType.Everyone;
                }
            }
        }

        auto rolesValue = json.object.get("roles", JSONValue.init);
        if (rolesValue.type == JSONType.array)
        {
            foreach (item; rolesValue.array)
            {
                if (item.type == JSONType.string)
                    mentions.roles ~= Snowflake(item.str.to!ulong);
            }
        }

        auto usersValue = json.object.get("users", JSONValue.init);
        if (usersValue.type == JSONType.array)
        {
            foreach (item; usersValue.array)
            {
                if (item.type == JSONType.string)
                    mentions.users ~= Snowflake(item.str.to!ulong);
            }
        }

        auto repliedUserValue = json.object.get("replied_user", JSONValue.init);
        if (repliedUserValue.type != JSONType.null_)
            mentions.repliedUser = Nullable!bool.of(repliedUserValue.boolean);

        return mentions;
    }

    /// Serializes Discord allowed-mentions JSON.
    JSONValue toJSON() const
    {
        JSONValue json;

        if (parse.length != 0)
        {
            JSONValue[] parseValues;
            foreach (item; parse)
            {
                final switch (item)
                {
                    case AllowedMentionType.Roles:
                        parseValues ~= JSONValue("roles");
                        break;
                    case AllowedMentionType.Users:
                        parseValues ~= JSONValue("users");
                        break;
                    case AllowedMentionType.Everyone:
                        parseValues ~= JSONValue("everyone");
                        break;
                }
            }
            json["parse"] = parseValues;
        }

        if (roles.length != 0)
        {
            JSONValue[] roleValues;
            foreach (roleId; roles)
                roleValues ~= JSONValue(roleId.toString);
            json["roles"] = roleValues;
        }

        if (users.length != 0)
        {
            JSONValue[] userValues;
            foreach (userId; users)
                userValues ~= JSONValue(userId.toString);
            json["users"] = userValues;
        }

        if (!repliedUser.isNull)
            json["replied_user"] = repliedUser.get;

        return json;
    }
}

/// Minimal referenced-message payload used for native reply metadata.
struct ReferencedMessage
{
    Snowflake id;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    User author;
    string content;

    /// Parses a referenced Discord message payload.
    static ReferencedMessage fromJSON(JSONValue json)
    {
        ReferencedMessage message;
        if (json.type != JSONType.object)
            return message;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            message.id = Snowflake(idValue.str.to!ulong);

        auto channelIdValue = json.object.get("channel_id", JSONValue.init);
        if (channelIdValue.type != JSONType.null_)
            message.channelId = Snowflake(channelIdValue.str.to!ulong);

        auto guildIdValue = json.object.get("guild_id", JSONValue.init);
        if (guildIdValue.type != JSONType.null_)
            message.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));

        auto authorValue = json.object.get("author", JSONValue.init);
        if (authorValue.type != JSONType.null_)
            message.author = User.fromJSON(authorValue);

        auto contentValue = json.object.get("content", JSONValue.init);
        if (contentValue.type != JSONType.null_)
            message.content = contentValue.str;

        return message;
    }
}

/// Minimal message payload.
struct MessageCreate
{
    string content;
    Embed[] embeds;
    Object[] components;
    MessageFlags flags = MessageFlags.None;
    Nullable!MessageReference messageReference;
    Nullable!AllowedMentions allowedMentions;

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
        static if (IsComponentsV2Component!T)
            flags |= MessageFlags.IsComponentsV2;
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
        if (content.length == 0 && embeds.length == 0 && components.length == 0)
        {
            return Result!(bool, string).err(
                "Discord message payloads must contain content, embeds, or components."
            );
        }

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

        if (
            !allowedMentions.isNull &&
            allowedMentions.get.parse.length != 0 &&
            (allowedMentions.get.roles.length != 0 || allowedMentions.get.users.length != 0)
        )
        {
            return Result!(bool, string).err(
                "Discord `allowed_mentions.parse` cannot be combined with explicit `roles` or `users` lists."
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

        if (components.length != 0)
        {
            JSONValue[] componentValues;
            foreach (component; components)
                componentValues ~= componentToJSON(component);
            json["components"] = componentValues;
        }

        if (!messageReference.isNull)
            json["message_reference"] = messageReference.get.toJSON();
        if (!allowedMentions.isNull)
            json["allowed_mentions"] = allowedMentions.get.toJSON();

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
    Nullable!GuildMember member;
    string content;
    Embed[] embeds;
    Object[] components;
    MessageFlags flags = MessageFlags.None;
    Attachment[] attachments;
    bool mentionEveryone;
    User[] mentions;
    Snowflake[] mentionRoleIds;
    Nullable!MessageReference messageReference;
    Nullable!ReferencedMessage referencedMessage;

    /// Convenience reply payload.
    MessageCreate reply(string text, bool mentionAuthor = false) const
    {
        return reply(MessageCreate(text), mentionAuthor);
    }

    /// Builds a reply payload against this message.
    MessageCreate reply(MessageCreate payload, bool mentionAuthor = false) const
    {
        auto reference = MessageReference.replyTo(id, Nullable!Snowflake.of(channelId), guildId);
        payload.messageReference = Nullable!MessageReference.of(reference);

        AllowedMentions mentions = payload.allowedMentions.getOr(AllowedMentions.init);
        mentions.repliedUser = Nullable!bool.of(mentionAuthor);
        payload.allowedMentions = Nullable!AllowedMentions.of(mentions);
        return payload;
    }

    /// Returns whether this message mentions a specific user.
    bool mentionsUser(Snowflake userId) const
    {
        foreach (user; mentions)
        {
            if (user.id == userId)
                return true;
        }
        return false;
    }

    /// Returns whether this message references a specific message id.
    bool referencesMessage(Snowflake messageId) const
    {
        return !messageReference.isNull &&
            !messageReference.get.messageId.isNull &&
            messageReference.get.messageId.get == messageId;
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

        auto mentionEveryoneValue = json.object.get("mention_everyone", JSONValue.init);
        if (mentionEveryoneValue.type != JSONType.null_)
            message.mentionEveryone = mentionEveryoneValue.boolean;

        auto authorValue = json.object.get("author", JSONValue.init);
        if (authorValue.type != JSONType.null_)
            message.author = User.fromJSON(authorValue);

        auto memberValue = json.object.get("member", JSONValue.init);
        if (memberValue.type != JSONType.null_)
        {
            auto member = GuildMember.fromJSON(memberValue);
            if (member.user.isNull && message.author.id.value != 0)
                member.user = Nullable!User.of(message.author);
            message.member = Nullable!GuildMember.of(member);
        }

        auto mentionsValue = json.object.get("mentions", JSONValue.init);
        if (mentionsValue.type == JSONType.array)
        {
            foreach (item; mentionsValue.array)
                message.mentions ~= User.fromJSON(item);
        }

        auto mentionRolesValue = json.object.get("mention_roles", JSONValue.init);
        if (mentionRolesValue.type == JSONType.array)
        {
            foreach (item; mentionRolesValue.array)
            {
                if (item.type == JSONType.string)
                    message.mentionRoleIds ~= Snowflake(item.str.to!ulong);
            }
        }

        auto messageReferenceValue = json.object.get("message_reference", JSONValue.init);
        if (messageReferenceValue.type != JSONType.null_)
            message.messageReference = Nullable!MessageReference.of(MessageReference.fromJSON(messageReferenceValue));

        auto referencedMessageValue = json.object.get("referenced_message", JSONValue.init);
        if (referencedMessageValue.type == JSONType.object)
            message.referencedMessage = Nullable!ReferencedMessage.of(ReferencedMessage.fromJSON(referencedMessageValue));

        return message;
    }
}

unittest
{
    import ddiscord.interactions.components : Container, Section, Separator, SeparatorSpacing, TextDisplay;

    auto payload = MessageCreate("dashboard")
        .addComponent(
            Container()
                .accentColor(0x57F287)
                .addComponent(Section().addText(TextDisplay("hello")))
                .addComponent(Separator(SeparatorSpacing.Medium))
        );

    auto validation = payload.validate();
    assert(validation.isOk);
    assert((payload.flags & MessageFlags.IsComponentsV2) == MessageFlags.IsComponentsV2);

    auto json = payload.toJSON();
    assert(json.object.get("components", JSONValue.init).type == JSONType.array);
}

unittest
{
    auto source = parseJSON(`{
        "id":"10",
        "channel_id":"20",
        "guild_id":"30",
        "content":"hello <@7>",
        "mention_everyone": false,
        "author":{"id":"2","username":"bot","bot":true},
        "mentions":[{"id":"7","username":"alice","bot":false}],
        "mention_roles":["99"],
        "message_reference":{
            "type":0,
            "message_id":"8",
            "channel_id":"20",
            "guild_id":"30"
        },
        "referenced_message":{
            "id":"8",
            "channel_id":"20",
            "author":{"id":"7","username":"alice","bot":false},
            "content":"original"
        }
    }`);

    auto message = Message.fromJSON(source);
    assert(message.mentions.length == 1);
    assert(message.mentionsUser(Snowflake(7)));
    assert(message.mentionRoleIds.length == 1);
    assert(message.referencesMessage(Snowflake(8)));
    assert(!message.referencedMessage.isNull);
    assert(message.referencedMessage.get.content == "original");
}

unittest
{
    Message message;
    message.id = Snowflake(55);
    message.channelId = Snowflake(66);
    message.guildId = Nullable!Snowflake.of(Snowflake(77));

    auto payload = message.reply("pong", true);
    auto json = payload.toJSON();

    auto reference = json.object.get("message_reference", JSONValue.init);
    assert(reference.object.get("message_id", JSONValue.init).str == "55");
    assert(reference.object.get("channel_id", JSONValue.init).str == "66");
    assert(reference.object.get("guild_id", JSONValue.init).str == "77");

    auto allowedMentions = json.object.get("allowed_mentions", JSONValue.init);
    assert(allowedMentions.object.get("replied_user", JSONValue.init).boolean);
}
