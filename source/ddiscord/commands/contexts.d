/**
 * ddiscord — command context typing helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.commands.contexts;

import ddiscord.command_types : HybridCommand, PrefixCommand, SlashCommand;
import ddiscord.context.command : CommandContext, CommandSource, ContextMenuContext, HybridContext,
    PrefixContext, SlashContext;
import ddiscord.util.errors : formatError;
import ddiscord.util.result : Result;

template hasExplicitHybridAttr(alias fn)
{
    enum bool hasExplicitHybridAttr = hasExplicitHybridAttrImpl!(__traits(getAttributes, fn));
}

template hasExplicitHybridAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasExplicitHybridAttrImpl = false;
    }
    else static if (is(typeof(attrs[0]) == HybridCommand))
    {
        enum bool hasExplicitHybridAttrImpl = true;
    }
    else
    {
        enum bool hasExplicitHybridAttrImpl = hasExplicitHybridAttrImpl!(attrs[1 .. $]);
    }
}

template hasExplicitPrefixAttr(alias fn)
{
    enum bool hasExplicitPrefixAttr = hasExplicitPrefixAttrImpl!(__traits(getAttributes, fn));
}

template hasExplicitPrefixAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasExplicitPrefixAttrImpl = false;
    }
    else static if (is(typeof(attrs[0]) == PrefixCommand))
    {
        enum bool hasExplicitPrefixAttrImpl = true;
    }
    else
    {
        enum bool hasExplicitPrefixAttrImpl = hasExplicitPrefixAttrImpl!(attrs[1 .. $]);
    }
}

template hasExplicitSlashAttr(alias fn)
{
    enum bool hasExplicitSlashAttr = hasExplicitSlashAttrImpl!(__traits(getAttributes, fn));
}

template hasExplicitSlashAttrImpl(attrs...)
{
    static if (attrs.length == 0)
    {
        enum bool hasExplicitSlashAttrImpl = false;
    }
    else static if (is(typeof(attrs[0]) == SlashCommand))
    {
        enum bool hasExplicitSlashAttrImpl = true;
    }
    else
    {
        enum bool hasExplicitSlashAttrImpl = hasExplicitSlashAttrImpl!(attrs[1 .. $]);
    }
}

template isCommandContextParameter(T)
{
    enum bool isCommandContextParameter =
        is(T == CommandContext) ||
        is(T == PrefixContext) ||
        is(T == SlashContext) ||
        is(T == ContextMenuContext) ||
        is(T == HybridContext);
}

template CommandContextParameterCount(Params...)
{
    static if (Params.length == 0)
        enum CommandContextParameterCount = 0;
    else
        enum CommandContextParameterCount =
            (isCommandContextParameter!(Params[0]) ? 1 : 0) + CommandContextParameterCount!(Params[1 .. $]);
}

template FirstCommandContextParameterType(Params...)
{
    static if (Params.length == 0)
        alias FirstCommandContextParameterType = void;
    else static if (isCommandContextParameter!(Params[0]))
        alias FirstCommandContextParameterType = Params[0];
    else
        alias FirstCommandContextParameterType = FirstCommandContextParameterType!(Params[1 .. $]);
}

Result!(T, string) resolveCommandContextParameter(T)(CommandContext ctx)
{
    static if (is(T == CommandContext))
    {
        return Result!(T, string).ok(ctx);
    }
    else static if (is(T == PrefixContext))
    {
        if (ctx.source != CommandSource.Prefix)
        {
            return Result!(T, string).err(formatError(
                "commands",
                "A prefix command context was requested outside a prefix execution.",
                "",
                "Use `PrefixContext` only for prefix handlers or `HybridContext` when the handler supports both prefix and slash."
            ));
        }

        return Result!(T, string).ok(ctx.asPrefix());
    }
    else static if (is(T == SlashContext))
    {
        if (ctx.source != CommandSource.Slash)
        {
            return Result!(T, string).err(formatError(
                "commands",
                "A slash command context was requested outside a slash execution.",
                "",
                "Use `SlashContext` only for slash handlers or `HybridContext` when the handler supports both prefix and slash."
            ));
        }

        return Result!(T, string).ok(ctx.asSlash());
    }
    else static if (is(T == ContextMenuContext))
    {
        if (ctx.source != CommandSource.ContextMenu)
        {
            return Result!(T, string).err(formatError(
                "commands",
                "A context-menu command context was requested outside a context-menu execution.",
                "",
                "Use `ContextMenuContext` only for context-menu handlers."
            ));
        }

        return Result!(T, string).ok(ctx.asContextMenu());
    }
    else static if (is(T == HybridContext))
    {
        if (ctx.source == CommandSource.ContextMenu)
        {
            return Result!(T, string).err(formatError(
                "commands",
                "A hybrid command context was requested for a context-menu execution.",
                "",
                "Use `HybridContext` only for prefix/slash flows."
            ));
        }

        return Result!(T, string).ok(ctx.asHybrid());
    }
    else
    {
        static assert(false, "Unsupported command context parameter.");
    }
}
