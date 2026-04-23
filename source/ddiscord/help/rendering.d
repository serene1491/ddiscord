/**
 * ddiscord — built-in help renderers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.help.rendering;

import ddiscord.client_types : CommandHelpEntry, CommandHelpPage;
import ddiscord.help.navigation : BuiltInHelpAccentColor, BuiltInHelpNextLabel,
    BuiltInHelpNoopCustomId, BuiltInHelpPreviousLabel;
import ddiscord.interactions.components : ActionRow, Button, ButtonStyle, Container,
    Separator, SeparatorSpacing, TextDisplay;
import ddiscord.models.embed : EmbedBuilder;
import ddiscord.models.message : MessageCreate;
import std.conv : to;

MessageCreate defaultComponentsHelpPage(CommandHelpPage page)
{
    MessageCreate payload;
    auto container = Container().accentColor(BuiltInHelpAccentColor);

    auto title = "## `" ~ page.commandName ~ "`\nPage " ~ page.page.to!string ~
        "/" ~ page.totalPages.to!string ~ " • " ~ page.totalEntries.to!string ~ " command(s)";
    if (page.query.length != 0)
        title ~= "\nFilter: `" ~ page.query ~ "`";

    container = container.addComponent(TextDisplay(title));

    if (page.entries.length == 0)
    {
        container = container.addComponent(Separator(SeparatorSpacing.Medium));
        container = container.addComponent(TextDisplay("No registered commands matched this help query."));
    }
    else
    {
        foreach (entry; page.entries)
        {
            container = container.addComponent(Separator(SeparatorSpacing.Medium));
            container = container.addComponent(TextDisplay(defaultHelpEntryText(entry)));
        }
    }

    payload = payload.addComponent(container);

    if (page.totalPages > 1)
        payload = payload.addComponent(buildNavigationRow(page));

    return payload;
}

MessageCreate defaultEmbeddedHelpPage(CommandHelpPage page)
{
    auto embed = EmbedBuilder()
        .title(page.commandName)
        .description(defaultHelpPageDescription(page))
        .color(BuiltInHelpAccentColor)
        .footer("Page " ~ page.page.to!string ~ "/" ~ page.totalPages.to!string)
        .build();

    MessageCreate payload;
    payload = payload.withEmbed(embed);

    if (page.totalPages > 1)
        payload = payload.addComponent(buildNavigationRow(page));

    return payload;
}

string defaultHelpPageDescription(CommandHelpPage page)
{
    if (page.entries.length == 0)
    {
        return page.query.length == 0
            ? "No commands are currently available."
            : "No commands matched `" ~ page.query ~ "`.";
    }

    string description;
    foreach (index, entry; page.entries)
    {
        if (index != 0)
            description ~= "\n\n";
        description ~= defaultHelpEntryText(entry);
    }

    return description;
}

string defaultHelpEntryText(CommandHelpEntry entry)
{
    return "**" ~ entry.name ~ "**\n" ~
        entry.description ~ "\n" ~
        "Usage: `" ~ entry.usage ~ "`\n" ~
        "Routes: " ~ entry.routes ~ "\n" ~
        "Category: " ~ entry.category ~ "\n" ~
        "Source: `" ~ entry.sourceModule ~ "`\n" ~
        "Policies: " ~ entry.policies;
}

private ActionRow buildNavigationRow(CommandHelpPage page)
{
    auto row = ActionRow();
    auto previous = Button(
        page.previousCustomId.length == 0 ? BuiltInHelpNoopCustomId : page.previousCustomId,
        BuiltInHelpPreviousLabel,
        ButtonStyle.Secondary
    );
    auto next = Button(
        page.nextCustomId.length == 0 ? BuiltInHelpNoopCustomId : page.nextCustomId,
        BuiltInHelpNextLabel,
        ButtonStyle.Primary
    );

    if (!page.hasPrevious)
        previous = previous.disable();
    if (!page.hasNext)
        next = next.disable();

    return row.addComponent(previous).addComponent(next);
}

unittest
{
    CommandHelpPage page;
    page.commandName = "help";
    page.page = 1;
    page.totalPages = 2;
    page.totalEntries = 1;
    page.hasNext = true;
    page.nextCustomId = "ddiscord:help:v1:1:2:q:cGluZw";

    CommandHelpEntry entry;
    entry.name = "ping";
    entry.description = "pong";
    entry.usage = "!ping";
    entry.routes = "prefix";
    entry.category = "General";
    entry.sourceModule = "example";
    entry.policies = "none";
    page.entries ~= entry;

    auto payload = defaultComponentsHelpPage(page);
    auto json = payload.toJSON();
    assert(json["components"].array.length == 2);
}
