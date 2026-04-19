/**
 * ddiscord — application command models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.application_command;

import ddiscord.models.channel : ChannelType;
import std.json : JSONType, JSONValue;

/// Command transport routes.
enum CommandRoute : uint
{
    Prefix = 1u << 0,
    Slash = 1u << 1,
    ContextMenu = 1u << 2,
    Hybrid = Prefix | Slash,
}

/// Discord interaction types.
enum InteractionType : int
{
    Ping = 1,
    ApplicationCommand = 2,
    MessageComponent = 3,
    ApplicationCommandAutocomplete = 4,
    ModalSubmit = 5,
}

/// Discord application command types.
enum ApplicationCommandType : int
{
    ChatInput = 1,
    User = 2,
    Message = 3,
}

/// Discord application command option types.
enum ApplicationCommandOptionType : int
{
    SubCommand = 1,
    SubCommandGroup = 2,
    String = 3,
    Integer = 4,
    Boolean = 5,
    User = 6,
    Channel = 7,
    Role = 8,
    Mentionable = 9,
    Number = 10,
    Attachment = 11,
}

/// Autocomplete choice payload.
struct AutocompleteChoice
{
    string name;
    string value;
}

/// Static choice definition for a slash command option.
struct ApplicationCommandOptionChoice
{
    string name;
    string value;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["name"] = name;
        json["value"] = value;
        return json;
    }
}

/// Slash/context option definition derived from command metadata.
struct ApplicationCommandOption
{
    string name;
    string description;
    ApplicationCommandOptionType type = ApplicationCommandOptionType.String;
    bool required = true;
    bool autocomplete;
    ChannelType[] channelTypes;
    ApplicationCommandOptionChoice[] choices;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["name"] = name;
        json["description"] = description;
        json["type"] = cast(int) type;
        json["required"] = required;

        if (autocomplete)
            json["autocomplete"] = true;

        if (channelTypes.length != 0)
        {
            JSONValue[] values;
            foreach (channelType; channelTypes)
                values ~= JSONValue(cast(int) channelType);
            json["channel_types"] = values;
        }

        if (choices.length != 0)
        {
            JSONValue[] values;
            foreach (choice; choices)
                values ~= choice.toJSON();
            json["choices"] = values;
        }

        return json;
    }

    static ApplicationCommandOption fromJSON(JSONValue json)
    {
        ApplicationCommandOption option;
        option.required = false;

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            option.name = nameValue.str;

        auto descriptionValue = json.object.get("description", JSONValue.init);
        if (descriptionValue.type != JSONType.null_)
            option.description = descriptionValue.str;

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            option.type = cast(ApplicationCommandOptionType) cast(int) typeValue.integer;

        auto requiredValue = json.object.get("required", JSONValue.init);
        if (requiredValue.type == JSONType.true_ || requiredValue.type == JSONType.false_)
            option.required = requiredValue.boolean;

        auto autocompleteValue = json.object.get("autocomplete", JSONValue.init);
        if (autocompleteValue.type == JSONType.true_ || autocompleteValue.type == JSONType.false_)
            option.autocomplete = autocompleteValue.boolean;

        auto channelTypesValue = json.object.get("channel_types", JSONValue.init);
        if (channelTypesValue.type == JSONType.array)
        {
            foreach (item; channelTypesValue.array)
                option.channelTypes ~= cast(ChannelType) cast(int) item.integer;
        }

        auto choicesValue = json.object.get("choices", JSONValue.init);
        if (choicesValue.type == JSONType.array)
        {
            foreach (item; choicesValue.array)
            {
                ApplicationCommandOptionChoice choice;

                auto choiceName = item.object.get("name", JSONValue.init);
                if (choiceName.type != JSONType.null_)
                    choice.name = choiceName.str;

                auto choiceValue = item.object.get("value", JSONValue.init);
                if (choiceValue.type != JSONType.null_)
                    choice.value = choiceValue.toString();
                if (choiceValue.type == JSONType.string)
                    choice.value = choiceValue.str;

                option.choices ~= choice;
            }
        }

        return option;
    }
}

/// Slash/context command definition ready to be synced.
struct ApplicationCommandDefinition
{
    string name;
    string description;
    ApplicationCommandType type = ApplicationCommandType.ChatInput;
    ApplicationCommandOption[] options;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["name"] = name;
        json["description"] = description;
        json["type"] = cast(int) type;

        if (options.length != 0)
        {
            JSONValue[] optionValues;
            foreach (option; options)
                optionValues ~= option.toJSON();
            json["options"] = optionValues;
        }

        return json;
    }

    static ApplicationCommandDefinition fromJSON(JSONValue json)
    {
        ApplicationCommandDefinition definition;

        auto nameValue = json.object.get("name", JSONValue.init);
        if (nameValue.type != JSONType.null_)
            definition.name = nameValue.str;

        auto descriptionValue = json.object.get("description", JSONValue.init);
        if (descriptionValue.type != JSONType.null_)
            definition.description = descriptionValue.str;

        auto typeValue = json.object.get("type", JSONValue.init);
        if (typeValue.type != JSONType.null_)
            definition.type = cast(ApplicationCommandType) cast(int) typeValue.integer;

        auto optionsValue = json.object.get("options", JSONValue.init);
        if (optionsValue.type == JSONType.array)
        {
            foreach (item; optionsValue.array)
                definition.options ~= ApplicationCommandOption.fromJSON(item);
        }

        return definition;
    }
}
