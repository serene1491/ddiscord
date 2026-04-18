/**
 * ddiscord — components V2 builders.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.interactions.components;

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
}

/// Thumbnail accessory.
struct Thumbnail
{
    string url;

    this(string url)
    {
        this.url = url;
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
}

/// Visual separator component.
struct Separator
{
    SeparatorSpacing spacing;

    this(SeparatorSpacing spacing)
    {
        this.spacing = spacing;
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
}

private final class ComponentHolder(T) : Object
{
    T component;

    this(T component)
    {
        this.component = component;
    }
}
