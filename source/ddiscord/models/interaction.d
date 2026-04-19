/**
 * ddiscord — interaction models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.interaction;

import ddiscord.models.application_command : AutocompleteChoice, InteractionType;
import ddiscord.models.channel : Channel;
import ddiscord.models.member : GuildMember;
import ddiscord.models.message : Message;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;

/// Interaction option payload used by slash commands.
struct InteractionOption
{
    string name;
    string value;
    bool focused;
}

/// Discord interaction model.
struct Interaction
{
    Snowflake id;
    InteractionType type = InteractionType.ApplicationCommand;
    string token;
    Snowflake channelId;
    Nullable!Snowflake guildId;
    User user;
    Nullable!GuildMember member;
    ulong permissions;
    ulong appPermissions;
    string commandName;
    InteractionOption[] options;
    AutocompleteChoice[] autocompleteChoices;
    Nullable!Message targetMessage;
    User[] resolvedUsers;
    Channel[] resolvedChannels;
    Role[] resolvedRoles;

    /// Parses a Discord interaction payload.
    static Interaction fromJSON(JSONValue json)
    {
        Interaction interaction;

        auto idValue = json.object.get("id", JSONValue.init);
        if (idValue.type != JSONType.null_)
            interaction.id = Snowflake(idValue.str.to!ulong);

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            interaction.type = cast(InteractionType) typeValue.integer;

        auto tokenValue = json.object.get("token", JSONValue.init);
        if (tokenValue.type != JSONType.null_)
            interaction.token = tokenValue.str;

        auto channelIdValue = json.object.get("channel_id", JSONValue.init);
        if (channelIdValue.type != JSONType.null_)
            interaction.channelId = Snowflake(channelIdValue.str.to!ulong);

        auto guildIdValue = json.object.get("guild_id", JSONValue.init);
        if (guildIdValue.type != JSONType.null_)
            interaction.guildId = Nullable!Snowflake.of(Snowflake(guildIdValue.str.to!ulong));

        auto userValue = json.object.get("user", JSONValue.init);
        if (userValue.type != JSONType.null_)
            interaction.user = User.fromJSON(userValue);

        auto memberValue = json.object.get("member", JSONValue.init);
        if (memberValue.type != JSONType.null_)
        {
            auto member = GuildMember.fromJSON(memberValue);
            interaction.member = Nullable!GuildMember.of(member);
            if (interaction.user.id.value == 0 && !member.user.isNull)
                interaction.user = member.user.get;
            if (interaction.permissions == 0)
                interaction.permissions = member.permissions;
        }

        auto appPermissions = json.object.get("app_permissions", JSONValue.init);
        if (appPermissions.type != JSONType.null_)
            interaction.appPermissions = appPermissions.str.to!ulong;

        auto dataValue = json.object.get("data", JSONValue.init);
        if (dataValue.type != JSONType.null_)
            parseInteractionData(interaction, dataValue);

        auto messageValue = json.object.get("message", JSONValue.init);
        if (messageValue.type != JSONType.null_)
            interaction.targetMessage = Nullable!Message.of(Message.fromJSON(messageValue));

        return interaction;
    }
}

private void parseInteractionData(ref Interaction interaction, JSONValue dataValue)
{
    auto nameValue = dataValue.object.get("name", JSONValue.init);
    if (nameValue.type != JSONType.null_)
        interaction.commandName = nameValue.str;

    auto optionsValue = dataValue.object.get("options", JSONValue.init);
    if (optionsValue.type == JSONType.array)
    {
        foreach (item; optionsValue.array)
            parseOption(interaction.options, item);
    }

    auto resolvedValue = dataValue.object.get("resolved", JSONValue.init);
    if (resolvedValue.type != JSONType.null_)
        parseResolved(interaction, resolvedValue);

    auto targetMessageValue = dataValue.object.get("target_id", JSONValue.init);
    if (targetMessageValue.type != JSONType.null_ && interaction.targetMessage.isNull)
    {
        auto messageId = targetMessageValue.str.to!ulong;
        foreach (message; interaction.targetMessage.isNull ? [] : [interaction.targetMessage.get])
        {
            if (message.id.value == messageId)
                return;
        }
    }
}

private void parseOption(ref InteractionOption[] destination, JSONValue optionValue)
{
    InteractionOption option;

    auto nameValue = optionValue.object.get("name", JSONValue.init);
    if (nameValue.type != JSONType.null_)
        option.name = nameValue.str;

    auto valueValue = optionValue.object.get("value", JSONValue.init);
    if (valueValue.type != JSONType.null_)
        option.value = jsonScalarToString(valueValue);

    auto focusedValue = optionValue.object.get("focused", JSONValue.init);
    if (focusedValue.type != JSONType.null_)
        option.focused = focusedValue.boolean;

    auto nestedOptions = optionValue.object.get("options", JSONValue.init);
    if (nestedOptions.type == JSONType.array)
    {
        foreach (item; nestedOptions.array)
            parseOption(destination, item);
    }
    else
    {
        destination ~= option;
    }
}

private void parseResolved(ref Interaction interaction, JSONValue resolvedValue)
{
    auto usersValue = resolvedValue.object.get("users", JSONValue.init);
    if (usersValue.type == JSONType.object)
    {
        foreach (_, item; usersValue.object)
            interaction.resolvedUsers ~= User.fromJSON(item);
    }

    auto channelsValue = resolvedValue.object.get("channels", JSONValue.init);
    if (channelsValue.type == JSONType.object)
    {
        foreach (_, item; channelsValue.object)
            interaction.resolvedChannels ~= Channel.fromJSON(item);
    }

    auto rolesValue = resolvedValue.object.get("roles", JSONValue.init);
    if (rolesValue.type == JSONType.object)
    {
        foreach (_, item; rolesValue.object)
            interaction.resolvedRoles ~= Role.fromJSON(item);
    }
}

private string jsonScalarToString(JSONValue value)
{
    final switch (value.type)
    {
        case JSONType.string:
            return value.str;
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
            return value.toString();
        case JSONType.true_:
            return "true";
        case JSONType.false_:
            return "false";
        case JSONType.object:
        case JSONType.array:
        case JSONType.null_:
            return value.toString();
    }
}

unittest
{
    auto payload = parseJSON(`{
        "id": "1",
        "type": 2,
        "token": "abc",
        "app_permissions": "2048",
        "member": {
            "user": {"id": "2", "username": "alice"},
            "roles": [],
            "permissions": "1024"
        },
        "data": {"name": "ping"}
    }`);

    auto interaction = Interaction.fromJSON(payload);
    assert(interaction.permissions == 1024);
    assert(interaction.appPermissions == 2048);
}
