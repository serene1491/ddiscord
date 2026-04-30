/**
 * ddiscord — command error classification and user-facing rendering.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_errors;

import ddiscord.client_support.types : CommandErrorBehavior, CommandErrorContext, CommandErrorKind;
import ddiscord.models.message : MessageCreate;
import std.algorithm : canFind;
import std.string : indexOf, strip;

/// Classifies an internal command error string into a user-facing category.
CommandErrorKind classifyCommandFailure(string error)
{
    if (error.canFind("requested prefix command is not registered") ||
        error.canFind("requested interaction command is not registered"))
    {
        return CommandErrorKind.UnknownCommand;
    }

    if (error.canFind("No command name was provided after the prefix"))
        return CommandErrorKind.MissingCommandName;
    if (error.canFind("required prefix-command argument was not provided") ||
        error.canFind("required slash-command option was not provided"))
    {
        return CommandErrorKind.MissingArgument;
    }

    if (error.canFind("could not be converted to the expected type") ||
        error.canFind("received an invalid value"))
    {
        return CommandErrorKind.InvalidArgument;
    }

    if (error.canFind("Too many prefix arguments were provided"))
        return CommandErrorKind.TooManyArguments;
    if (error.canFind("restricted to the configured bot owner") ||
        error.canFind("permission requirements") ||
        error.canFind("temporarily rate limited"))
    {
        return CommandErrorKind.PolicyDenied;
    }

    if (error.canFind("handler raised an exception"))
        return CommandErrorKind.HandlerFailure;

    return CommandErrorKind.Unknown;
}


/// Decides whether a command failure should be surfaced to end users.
bool shouldSurfaceFailure(CommandErrorBehavior behavior, CommandErrorContext context)
{
    if (!behavior.enabled)
        return false;
    if (behavior.shouldSurface !is null)
        return behavior.shouldSurface(context);

    final switch (context.kind)
    {
        case CommandErrorKind.UnknownCommand:
            return behavior.surfaceUnknownCommand;
        case CommandErrorKind.MissingCommandName:
            return behavior.surfaceMissingCommandName;
        case CommandErrorKind.MissingArgument:
        case CommandErrorKind.InvalidArgument:
        case CommandErrorKind.TooManyArguments:
            return behavior.surfaceArgumentErrors;
        case CommandErrorKind.PolicyDenied:
            return behavior.surfacePolicyErrors;
        case CommandErrorKind.HandlerFailure:
            return behavior.surfaceHandlerFailures;
        case CommandErrorKind.Unknown:
            return behavior.surfaceOtherErrors;
    }
}


/// Builds the default user-facing failure payload used by the client.
MessageCreate buildFailurePayload(
    CommandErrorBehavior behavior,
    string prefix,
    CommandErrorContext context
)
{
    if (behavior.render !is null)
        return behavior.render(context);

    string[] lines;
    lines ~= userFacingFailureSummary(context);

    auto detail = userFacingFailureDetail(context);
    if (detail.length != 0)
        lines ~= detail;

    auto hint = userFacingFailureHint(prefix, context);
    if (hint.length != 0)
        lines ~= hint;

    return MessageCreate(joinLines(lines));
}


private string userFacingFailureSummary(CommandErrorContext context)
{
    final switch (context.kind)
    {
        case CommandErrorKind.UnknownCommand:
            return "Command `" ~ context.commandName ~ "` was not found.";
        case CommandErrorKind.MissingCommandName:
            return "A command name is required after the prefix.";
        case CommandErrorKind.MissingArgument:
            return "Some required arguments are missing.";
        case CommandErrorKind.InvalidArgument:
            return "One or more arguments are invalid.";
        case CommandErrorKind.TooManyArguments:
            return "Too many arguments were provided.";
        case CommandErrorKind.PolicyDenied:
            return "This command cannot run with the current policy restrictions.";
        case CommandErrorKind.HandlerFailure:
            return "The command failed while it was running.";
        case CommandErrorKind.Unknown:
            return "The command could not be completed.";
    }
}


private string userFacingFailureDetail(CommandErrorContext context)
{
    static string detailPrefix = "Detail: ";
    static string hintPrefix = "Hint: ";

    auto detailStart = context.error.indexOf(detailPrefix);
    if (detailStart == -1)
        return "";

    detailStart += cast(ptrdiff_t) detailPrefix.length;
    auto detail = context.error[detailStart .. $];
    auto hintStart = detail.indexOf(hintPrefix);
    if (hintStart != -1)
        detail = detail[0 .. hintStart];

    // Keep user-facing failures concise instead of dumping the full internal error.
    detail = detail.strip;
    if (detail.length == 0)
        return "";
    if (detail.length > 220)
        detail = detail[0 .. 220] ~ "...";
    return detail;
}


private string userFacingFailureHint(string prefix, CommandErrorContext context)
{
    auto commandText = context.commandName.length == 0 ? "<command>" : context.commandName;

    final switch (context.kind)
    {
        case CommandErrorKind.UnknownCommand:
            return "Use `" ~ prefix ~ "help` to list available commands.";
        case CommandErrorKind.MissingCommandName:
            return "Try `" ~ prefix ~ "help` to see what is available.";
        case CommandErrorKind.MissingArgument:
        case CommandErrorKind.InvalidArgument:
        case CommandErrorKind.TooManyArguments:
            if (context.route == "prefix")
                return "Use `" ~ prefix ~ "help " ~ commandText ~ "` for usage examples.";
            return "Use `/help " ~ commandText ~ "` for usage examples.";
        case CommandErrorKind.PolicyDenied:
            if (context.error.canFind("owner"))
                return "This command is restricted to the configured bot owner.";
            if (context.error.canFind("permission"))
                return "You do not have the required permissions to run this command.";
            if (context.error.canFind("rate limit"))
                return "This command is on cooldown. Try again in a moment.";
            return "";
        case CommandErrorKind.HandlerFailure:
            return "The failure was logged on the bot side for debugging.";
        case CommandErrorKind.Unknown:
            return "Try again in a moment. If it keeps failing, inspect the bot logs.";
    }
}


private string joinLines(string[] lines)
{
    string joined;

    foreach (index, line; lines)
    {
        if (line.length == 0)
            continue;
        if (joined.length != 0)
            joined ~= "\n";
        joined ~= line;
    }

    return joined;
}
