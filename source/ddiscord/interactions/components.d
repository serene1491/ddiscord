/**
 * ddiscord — components V2 builders.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.interactions.components;

import ddiscord.util.optional : Nullable;
import std.json : JSONType, JSONValue;

/// Interactive component types returned by Discord interaction payloads.
enum ComponentType : int
{
    Unknown = 0,
    ActionRow = 1,
    Button = 2,
    StringSelect = 3,
    TextInput = 4,
    UserSelect = 5,
    RoleSelect = 6,
    MentionableSelect = 7,
    ChannelSelect = 8,
    Section = 9,
    TextDisplay = 10,
    Thumbnail = 11,
    MediaGallery = 12,
    File = 13,
    Separator = 14,
    Container = 17,
}

/// Modal text input styles.
enum TextInputStyle : int
{
    Short = 1,
    Paragraph = 2,
}

/// Button styles supported by Discord.
enum ButtonStyle : int
{
    Primary = 1,
    Secondary = 2,
    Success = 3,
    Danger = 4,
    Link = 5,
}

/// Separator spacing variants.
enum SeparatorSpacing
{
    Small,
    Medium,
    Large,
}

/// Rich text display component.
struct TextDisplay
{
    string text;

    this(string text)
    {
        this.text = text;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.TextDisplay;
        json["content"] = text;
        return json;
    }
}

/// Thumbnail accessory.
struct Thumbnail
{
    string url;

    this(string url)
    {
        this.url = url;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.Thumbnail;
        json["media"] = JSONValue(["url": JSONValue(url)]);
        return json;
    }
}

/// Section layout component.
struct Section
{
    TextDisplay[] text;
    Thumbnail accessoryItem;

    Section addText(TextDisplay item)
    {
        text ~= item;
        return this;
    }

    Section accessory(Thumbnail item)
    {
        accessoryItem = item;
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.Section;

        if (text.length != 0)
        {
            JSONValue[] values;
            foreach (item; text)
                values ~= item.toJSON();
            json["components"] = values;
        }

        if (accessoryItem.url.length != 0)
            json["accessory"] = accessoryItem.toJSON();

        return json;
    }
}

/// Visual separator component.
struct Separator
{
    SeparatorSpacing spacing;

    this(SeparatorSpacing spacing)
    {
        this.spacing = spacing;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.Separator;
        json["divider"] = true;
        json["spacing"] = separatorSpacingValue(spacing);
        return json;
    }
}

/// Top-level container component.
struct Container
{
    uint accent;
    Object[] children;

    Container accentColor(uint value)
    {
        accent = value;
        return this;
    }

    Container addComponent(T)(T component)
    {
        children ~= cast(Object) new ComponentHolder!T(component);
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.Container;
        json["accent_color"] = cast(int) accent;

        if (children.length != 0)
        {
            JSONValue[] values;
            foreach (child; children)
                values ~= componentToJSON(child);
            json["components"] = values;
        }

        return json;
    }
}

/// Action-row container used by classic message components and modals.
struct ActionRow
{
    Object[] children;

    ActionRow addComponent(T)(T component)
    {
        children ~= cast(Object) new ComponentHolder!T(component);
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.ActionRow;

        if (children.length != 0)
        {
            JSONValue[] values;
            foreach (child; children)
                values ~= componentToJSON(child);
            json["components"] = values;
        }

        return json;
    }
}

/// String select option entry.
struct StringSelectOption
{
    string label;
    string value;
    Nullable!string description;
    bool defaultSelected;

    this(string label, string value)
    {
        this.label = label;
        this.value = value;
    }

    StringSelectOption withDescription(string text)
    {
        description = Nullable!string.of(text);
        return this;
    }

    StringSelectOption selected()
    {
        defaultSelected = true;
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["label"] = label;
        json["value"] = value;
        if (!description.isNull)
            json["description"] = description.get;
        if (defaultSelected)
            json["default"] = true;
        return json;
    }
}

/// String select menu component.
struct StringSelect
{
    string customId;
    Nullable!string placeholder;
    Nullable!uint minValues;
    Nullable!uint maxValues;
    bool disabled;
    StringSelectOption[] options;

    this(string customId)
    {
        this.customId = customId;
    }

    StringSelect withPlaceholder(string text)
    {
        placeholder = Nullable!string.of(text);
        return this;
    }

    StringSelect withMinValues(uint value)
    {
        minValues = Nullable!uint.of(value);
        return this;
    }

    StringSelect withMaxValues(uint value)
    {
        maxValues = Nullable!uint.of(value);
        return this;
    }

    StringSelect addOption(StringSelectOption option)
    {
        options ~= option;
        return this;
    }

    StringSelect disable()
    {
        disabled = true;
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.StringSelect;
        json["custom_id"] = customId;
        json["disabled"] = disabled;

        if (!placeholder.isNull)
            json["placeholder"] = placeholder.get;
        if (!minValues.isNull)
            json["min_values"] = minValues.get;
        if (!maxValues.isNull)
            json["max_values"] = maxValues.get;

        JSONValue[] values;
        foreach (option; options)
            values ~= option.toJSON();
        json["options"] = values;
        return json;
    }
}

/// Interactive button component.
struct Button
{
    string customId;
    string label;
    ButtonStyle style = ButtonStyle.Secondary;
    Nullable!string url;
    bool disabled;

    this(string customId, string label, ButtonStyle style = ButtonStyle.Secondary)
    {
        this.customId = customId;
        this.label = label;
        this.style = style;
    }

    static Button link(string url, string label)
    {
        Button button;
        button.url = Nullable!string.of(url);
        button.label = label;
        button.style = ButtonStyle.Link;
        return button;
    }

    Button withLabel(string value)
    {
        label = value;
        return this;
    }

    Button withStyle(ButtonStyle value)
    {
        style = value;
        return this;
    }

    Button withUrl(string value)
    {
        url = Nullable!string.of(value);
        style = ButtonStyle.Link;
        return this;
    }

    Button disable()
    {
        disabled = true;
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.Button;
        json["style"] = cast(int) style;
        json["label"] = label;
        json["disabled"] = disabled;

        if (!url.isNull)
        {
            json["url"] = url.get;
        }
        else
        {
            json["custom_id"] = customId;
        }

        return json;
    }
}

/// Text input component for modal responses.
struct TextInput
{
    string customId;
    string label;
    TextInputStyle style = TextInputStyle.Short;
    Nullable!uint minLength;
    Nullable!uint maxLength;
    bool required = true;
    Nullable!string value;
    Nullable!string placeholder;

    this(string customId, string label, TextInputStyle style = TextInputStyle.Short)
    {
        this.customId = customId;
        this.label = label;
        this.style = style;
    }

    TextInput min(uint value)
    {
        minLength = Nullable!uint.of(value);
        return this;
    }

    TextInput max(uint value)
    {
        maxLength = Nullable!uint.of(value);
        return this;
    }

    TextInput defaultValue(string text)
    {
        value = Nullable!string.of(text);
        return this;
    }

    TextInput placeholderText(string text)
    {
        placeholder = Nullable!string.of(text);
        return this;
    }

    TextInput optional()
    {
        required = false;
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["type"] = cast(int) ComponentType.TextInput;
        json["custom_id"] = customId;
        json["label"] = label;
        json["style"] = cast(int) style;
        json["required"] = required;

        if (!minLength.isNull)
            json["min_length"] = minLength.get;
        if (!maxLength.isNull)
            json["max_length"] = maxLength.get;
        if (!value.isNull)
            json["value"] = value.get;
        if (!placeholder.isNull)
            json["placeholder"] = placeholder.get;

        return json;
    }
}

/// Modal response payload.
struct Modal
{
    string customId;
    string title;
    ActionRow[] rows;

    this(string customId, string title)
    {
        this.customId = customId;
        this.title = title;
    }

    Modal addRow(ActionRow row)
    {
        rows ~= row;
        return this;
    }

    Modal addTextInput(TextInput input)
    {
        rows ~= ActionRow().addComponent(input);
        return this;
    }

    JSONValue toJSON() const
    {
        JSONValue json;
        json["custom_id"] = customId;
        json["title"] = title;

        JSONValue[] values;
        foreach (row; rows)
            values ~= row.toJSON();
        json["components"] = values;
        return json;
    }
}

private final class ComponentHolder(T) : Object
{
    T component;

    this(T component)
    {
        this.component = component;
    }
}

JSONValue componentToJSON(const(Object) component)
{
    if (auto holder = cast(const(ComponentHolder!Section)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!Separator)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!TextDisplay)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!Thumbnail)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!Container)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!ActionRow)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!StringSelect)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!Button)) component)
        return holder.component.toJSON();
    if (auto holder = cast(const(ComponentHolder!TextInput)) component)
        return holder.component.toJSON();

    JSONValue json;
    json["type"] = cast(int) ComponentType.Unknown;
    return json;
}

template isComponentsV2Component(T)
{
    enum bool isComponentsV2Component =
        is(T == Section) ||
        is(T == Separator) ||
        is(T == TextDisplay) ||
        is(T == Thumbnail) ||
        is(T == Container);
}

private int separatorSpacingValue(SeparatorSpacing spacing)
{
    final switch (spacing)
    {
        case SeparatorSpacing.Small:
            return 1;
        case SeparatorSpacing.Medium:
            return 1;
        case SeparatorSpacing.Large:
            return 2;
    }
}

unittest
{
    auto payload = Container()
        .accentColor(0x57F287)
        .addComponent(
            Section()
                .addText(TextDisplay("title"))
                .addText(TextDisplay("body"))
                .accessory(Thumbnail("https://example.com/image.png"))
        )
        .addComponent(Separator(SeparatorSpacing.Large))
        .toJSON();

    assert(payload["type"].integer == cast(long) ComponentType.Container);
    assert(payload["accent_color"].integer == cast(long) 0x57F287);

    auto section = payload["components"][0];
    assert(section["type"].integer == cast(long) ComponentType.Section);
    assert(section["components"][0]["type"].integer == cast(long) ComponentType.TextDisplay);
    assert(section["components"][0]["content"].str == "title");
    assert(section["accessory"]["type"].integer == cast(long) ComponentType.Thumbnail);
    assert(section["accessory"]["media"]["url"].str == "https://example.com/image.png");

    auto separator = payload["components"][1];
    assert(separator["type"].integer == cast(long) ComponentType.Separator);
    assert(separator["divider"].type == JSONType.true_);
    assert(separator["spacing"].integer == 2);
}
