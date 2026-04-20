# Interactions Guide

The library currently supports the main interaction reply flow:

- initial slash responses
- deferred responses
- follow-up messages
- editing the original interaction response
- opening modals from interaction handlers
- autocomplete callback transport
- typed low-level events for autocomplete, message components, and modal submissions

## Immediate reply

```d
@Command("hello", routes: CommandRoute.Slash)
void hello(CommandContext ctx)
{
    ctx.reply("Hello from a slash command!", ephemeral: true).await();
}
```

## Deferred reply

Use this when the command needs longer work:

```d
@Command("report", routes: CommandRoute.Slash)
void report(CommandContext ctx)
{
    ctx.defer(ephemeral: true).await();
    ctx.editOriginal("Building your report...").await();
    ctx.followup("Done.").await();
}
```

## Components V2 payloads

```d
auto container = Container()
    .accentColor(0x57F287)
    .addComponent(
        Section()
            .addText(TextDisplay("**Dashboard**"))
            .addText(TextDisplay("Your bot is online."))
    )
    .addComponent(Separator(SeparatorSpacing.Medium));

MessageCreate payload;
payload = payload.withContent("dashboard");
payload = payload.addComponent(container);

ctx.reply(payload).await();
```

When using the current V2 component builders (`Container`, `Section`, `Separator`, `TextDisplay`, `Thumbnail`), the library now sets `MessageFlags.IsComponentsV2` automatically.

## Modal response

```d
@Command("report", routes: CommandRoute.Slash)
void report(CommandContext ctx)
{
    auto modal = Modal("bug_report", "Bug Report")
        .addTextInput(TextInput("summary", "Summary"))
        .addTextInput(TextInput("details", "Details", TextInputStyle.Paragraph));

    ctx.showModal(modal).await();
}
```

## Low-level interaction events

Non-command interactions are now surfaced as dedicated typed events instead of being mixed into slash execution:

- `AutocompleteInteractionEvent`
- `MessageComponentEvent`
- `ModalSubmitEvent`

Example:

```d
client.on!ModalSubmitEvent((event) {
    foreach (component; event.interaction.submittedComponents)
    {
        import std.stdio : writeln;
        writeln(component.customId, " = ", component.value);
    }
});
```

## Autocomplete

The transport pieces are present in the library:

- `AutocompleteContext`
- `AutocompleteChoice`
- interaction autocomplete response support in the REST surface

Autocomplete is still a lower-level interaction capability rather than a polished high-level command binder, but it no longer falls through into normal slash-command execution.
