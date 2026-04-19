/**
 * ddiscord — components V2 builders.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.interactions.components;

import ddiscord.util.optional : Nullable;
import std.json : JSONValue;

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
}

/// Modal text input styles.
enum TextInputStyle : int
{
    Short = 1,
    Paragraph = 2,
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
        json["type"] = "text_display";
        json["text"] = text;
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
        json["type"] = "thumbnail";
        json["media"] = url;
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
        json["type"] = "section";

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
        json["type"] = "separator";
        json["spacing"] = cast(int) spacing;
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
        json["type"] = "container";
        json["accent_color"] = accent;

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
    if (auto holder = cast(const(ComponentHolder!TextInput)) component)
        return holder.component.toJSON();

    JSONValue json;
    json["type"] = "unknown";
    return json;
}

template IsComponentsV2Component(T)
{
    enum bool IsComponentsV2Component =
        is(T == Section) ||
        is(T == Separator) ||
        is(T == TextDisplay) ||
        is(T == Thumbnail) ||
        is(T == Container);
}
