/**
 * ddiscord — embed builder.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.embed;

import std.json : JSONValue;

/// Embed field model.
struct EmbedField
{
    string name;
    string value;
    bool inline;
}

/// Embed author model.
struct EmbedAuthor
{
    string name;
    string iconUrl;
    string url;
}

/// Discord embed model.
struct Embed
{
    string title;
    string description;
    string thumbnailUrl;
    EmbedField[] fields;
    uint color;
    string footerText;
    EmbedAuthor author;

    /// Serializes the embed into a Discord REST payload.
    JSONValue toJSON() const
    {
        JSONValue json;

        if (title.length != 0)
            json["title"] = title;
        if (description.length != 0)
            json["description"] = description;
        if (thumbnailUrl.length != 0)
            json["thumbnail"] = JSONValue(["url": JSONValue(thumbnailUrl)]);
        if (color != 0)
            json["color"] = color;
        if (footerText.length != 0)
            json["footer"] = JSONValue(["text": JSONValue(footerText)]);
        if (author.name.length != 0)
        {
            JSONValue authorJson;
            authorJson["name"] = author.name;
            if (author.iconUrl.length != 0)
                authorJson["icon_url"] = author.iconUrl;
            if (author.url.length != 0)
                authorJson["url"] = author.url;
            json["author"] = authorJson;
        }

        if (fields.length != 0)
        {
            JSONValue[] fieldValues;
            foreach (field; fields)
            {
                JSONValue fieldJson;
                fieldJson["name"] = field.name;
                fieldJson["value"] = field.value;
                fieldJson["inline"] = field.inline;
                fieldValues ~= fieldJson;
            }
            json["fields"] = fieldValues;
        }

        return json;
    }
}

/// Fluent embed builder used by the public examples.
struct EmbedBuilder
{
    private Embed _embed;

    EmbedBuilder title(string value)
    {
        _embed.title = value;
        return this;
    }

    EmbedBuilder description(string value)
    {
        _embed.description = value;
        return this;
    }

    EmbedBuilder thumbnail(string value)
    {
        _embed.thumbnailUrl = value;
        return this;
    }

    EmbedBuilder addField(string name, string value, bool inline = false)
    {
        _embed.fields ~= EmbedField(name, value, inline);
        return this;
    }

    EmbedBuilder color(uint value)
    {
        _embed.color = value;
        return this;
    }

    EmbedBuilder footer(string value)
    {
        _embed.footerText = value;
        return this;
    }

    EmbedBuilder author(string name, string iconUrl = "", string url = "")
    {
        _embed.author = EmbedAuthor(name, iconUrl, url);
        return this;
    }

    Embed build()
    {
        return _embed;
    }
}
