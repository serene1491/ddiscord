/**
 * ddiscord — components V2 builders.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.interactions.components;

import std.json : JSONValue;

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

    JSONValue json;
    json["type"] = "unknown";
    return json;
}
