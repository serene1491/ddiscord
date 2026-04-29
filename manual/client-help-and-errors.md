# Built-in Help and Errors

> Navigation: [Index](index.md) | [Quickstart](quickstart.md) | [Bot Structures](bot-structures.md) | [Commands](commands.md) | [Plugins and Lua](plugins-and-lua.md) | [Troubleshooting](troubleshooting.md)

## Built-in help

The client registers a built-in `help` command by default unless you already provide your own
command with the same name on prefix or slash routes.

Its defaults are meant to be useful immediately:

- paginated output
- embeds or Components V2 rendering
- case-insensitive query matching
- visibility checks against owner-only and permission-gated commands
- support for `@CommandCategory` and `@HideFromHelp`

Customize it through `client.helpBehavior`:

```d
client.helpBehavior.pageSize = 4;
client.helpBehavior.useComponentsV2 = true;
client.helpBehavior.includeCommand = (descriptor) => descriptor.category != "Internal";
client.helpBehavior.buildEntry = (descriptor, usage) {
    CommandHelpEntry entry;
    entry.name = descriptor.displayName;
    entry.description = descriptor.description;
    entry.usage = usage;
    entry.category = descriptor.category;
    return entry;
};
```

## Command errors

Prefix and interaction failures can be surfaced back to the caller by default instead of only
showing up in logs.

The default renderer keeps user-facing output concise (summary + short actionable hint) while full
failure details remain in bot logs.

The built-in behavior can report:

- unknown commands
- missing command names
- missing or invalid arguments
- handler failures
- other library-side command execution failures

Control it through `client.errorBehavior`:

```d
client.errorBehavior.surfaceUnknownCommand = false;
client.errorBehavior.surfaceArgumentErrors = true;
client.errorBehavior.shouldSurface = (error) => error.commandName != "eval";
client.errorBehavior.render = (error) {
    return MessageCreate("command error: " ~ error.error);
};
```

You can also start from quick presets:

- `CommandErrorBehavior.nonVerbose()` for low-noise behavior
- `CommandErrorBehavior.verbose()` to surface all failure kinds
