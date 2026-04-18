/**
 * ddiscord — application command models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.application_command;

import ddiscord.models.channel : ChannelType;
import std.json : JSONValue;

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
}
