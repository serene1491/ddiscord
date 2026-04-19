/**
 * ddiscord — interaction models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.interaction;

import ddiscord.interactions.components : ComponentType;
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

/// Component values submitted through message components or modals.
struct InteractionSubmittedComponent
{
    ComponentType type = ComponentType.Unknown;
    string customId;
    string value;
    string[] values;
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
    string customId;
    ComponentType componentType = ComponentType.Unknown;
    InteractionOption[] options;
    AutocompleteChoice[] autocompleteChoices;
    string[] values;
    InteractionSubmittedComponent[] submittedComponents;
    Nullable!Message targetMessage;
    User[] resolvedUsers;
    GuildMember[] resolvedMembers;
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

    auto customIdValue = dataValue.object.get("custom_id", JSONValue.init);
    if (customIdValue.type != JSONType.null_)
        interaction.customId = customIdValue.str;

    auto componentTypeValue = dataValue.object.get("component_type", JSONValue.init);
    if (componentTypeValue.type != JSONType.null_)
        interaction.componentType = cast(ComponentType) cast(int) componentTypeValue.integer;

    auto valuesValue = dataValue.object.get("values", JSONValue.init);
    if (valuesValue.type == JSONType.array)
        interaction.values = jsonArrayToStrings(valuesValue);

    auto componentsValue = dataValue.object.get("components", JSONValue.init);
    if (componentsValue.type == JSONType.array)
    {
        foreach (item; componentsValue.array)
            parseSubmittedComponent(interaction.submittedComponents, item);
    }

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
    User[string] resolvedUserMap;

    auto usersValue = resolvedValue.object.get("users", JSONValue.init);
    if (usersValue.type == JSONType.object)
    {
        foreach (userId, item; usersValue.object)
        {
            auto user = User.fromJSON(item);
            interaction.resolvedUsers ~= user;
            resolvedUserMap[userId] = user;
        }
    }

    auto membersValue = resolvedValue.object.get("members", JSONValue.init);
    if (membersValue.type == JSONType.object)
    {
        foreach (userId, item; membersValue.object)
        {
            auto member = GuildMember.fromJSON(item);
            if (member.user.isNull)
            {
                if (auto user = userId in resolvedUserMap)
                    member.user = Nullable!User.of(*user);
            }
            interaction.resolvedMembers ~= member;
        }
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

private void parseSubmittedComponent(ref InteractionSubmittedComponent[] destination, JSONValue componentValue)
{
    auto nestedComponent = componentValue.object.get("component", JSONValue.init);
    if (nestedComponent.type == JSONType.object)
        parseSubmittedComponent(destination, nestedComponent);

    auto childrenValue = componentValue.object.get("components", JSONValue.init);
    if (childrenValue.type == JSONType.array)
    {
        foreach (item; childrenValue.array)
            parseSubmittedComponent(destination, item);
    }

    InteractionSubmittedComponent component;

    auto typeValue = componentValue.object.get("component_type", JSONValue.init);
    if (typeValue.type == JSONType.null_)
        typeValue = componentValue.object.get("type", JSONValue.init);
    if (typeValue.type != JSONType.null_)
        component.type = cast(ComponentType) cast(int) typeValue.integer;

    auto customIdValue = componentValue.object.get("custom_id", JSONValue.init);
    if (customIdValue.type != JSONType.null_)
        component.customId = customIdValue.str;

    auto valueValue = componentValue.object.get("value", JSONValue.init);
    if (valueValue.type != JSONType.null_)
        component.value = jsonScalarToString(valueValue);

    auto valuesValue = componentValue.object.get("values", JSONValue.init);
    if (valuesValue.type == JSONType.array)
        component.values = jsonArrayToStrings(valuesValue);

    if (component.customId.length != 0)
        destination ~= component;
}

private string[] jsonArrayToStrings(JSONValue value)
{
    string[] values;
    if (value.type != JSONType.array)
        return values;

    foreach (item; value.array)
        values ~= jsonScalarToString(item);
    return values;
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

unittest
{
    auto payload = parseJSON(`{
        "id": "3",
        "type": 3,
        "token": "abc",
        "channel_id": "12",
        "data": {
            "custom_id": "favorite_bug",
            "component_type": 3,
            "values": ["ant", "moth"],
            "resolved": {
                "users": {
                    "9": {"id": "9", "username": "alice"}
                },
                "members": {
                    "9": {"roles": []}
                }
            }
        }
    }`);

    auto interaction = Interaction.fromJSON(payload);
    assert(interaction.customId == "favorite_bug");
    assert(interaction.componentType == ComponentType.StringSelect);
    assert(interaction.values == ["ant", "moth"]);
    assert(interaction.resolvedMembers.length == 1);
    assert(!interaction.resolvedMembers[0].user.isNull);
    assert(interaction.resolvedMembers[0].user.get.username == "alice");
}

unittest
{
    auto payload = parseJSON(`{
        "id": "4",
        "type": 5,
        "token": "abc",
        "channel_id": "12",
        "data": {
            "custom_id": "bug_modal",
            "components": [
                {
                    "type": 1,
                    "components": [
                        {
                            "type": 4,
                            "custom_id": "summary",
                            "value": "oops"
                        }
                    ]
                }
            ]
        }
    }`);

    auto interaction = Interaction.fromJSON(payload);
    assert(interaction.customId == "bug_modal");
    assert(interaction.submittedComponents.length == 1);
    assert(interaction.submittedComponents[0].customId == "summary");
    assert(interaction.submittedComponents[0].value == "oops");
}
