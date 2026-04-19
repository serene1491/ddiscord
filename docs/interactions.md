# Interactions Guide

The library currently supports the main interaction reply flow:

- initial slash responses
- deferred responses
- follow-up messages
- editing the original interaction response
- autocomplete callback transport

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
payload = payload.setFlag(MessageFlags.IsComponentsV2);

ctx.reply(payload).await();
```

When sending components, set `MessageFlags.IsComponentsV2`.

## Autocomplete

The transport pieces are present in the library:

- `AutocompleteContext`
- `AutocompleteChoice`
- interaction autocomplete response support in the REST surface

For now, autocomplete is best treated as a lower-level interaction capability rather than a polished high-level command binder.
