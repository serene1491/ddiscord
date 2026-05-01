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
import std.json : JSONType, JSONValue, parseJSON;
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
        error.canFind("received an invalid value") ||
        error.canFind("Invalid Form Body") ||
        error.canFind("payload as semantically invalid") ||
        error.canFind("status code 422"))
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
            return inferUnknownSummary(context.error);
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

    detail = normalizeUserFacingDetail(detail);
    if (detail.length == 0)
        return "";
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
            return contextualHandlerHint(context.error);
        case CommandErrorKind.Unknown:
            auto specialized = specializedInteractionHint(context.error);
            if (specialized.length != 0)
                return specialized;
            if (context.error.canFind("status code 0"))
                return "The request failed before receiving an HTTP response. Check DNS/connectivity, proxy, and TLS logs.";
            return "Try again in a moment. If it keeps failing, inspect the bot logs.";
    }
}

private string inferUnknownSummary(string error)
{
    if (error.canFind("[ddiscord/http]"))
        return "A Discord API request failed before the command could finish.";
    if (error.canFind("[ddiscord/rest]"))
        return "A Discord REST operation failed while handling this command.";
    if (error.canFind("[ddiscord/context]"))
        return "The command could not send its response.";
    return "The command could not be completed.";
}

private string normalizeUserFacingDetail(string rawDetail)
{
    auto detail = rawDetail.strip;
    if (detail.length == 0)
        return "";

    static string commandFailurePrefix = "Command `";
    auto failedWithIndex = detail.indexOf("failed with:");
    if (
        detail.length >= commandFailurePrefix.length &&
        detail[0 .. commandFailurePrefix.length] == commandFailurePrefix &&
        failedWithIndex != -1
    )
    {
        auto start = failedWithIndex + cast(ptrdiff_t) "failed with:".length;
        detail = detail[start .. $].strip;
    }

    auto jsonSummary = summarizeDiscordJsonError(detail);
    if (jsonSummary.length != 0)
        detail = jsonSummary;

    if (detail.length > 220)
        detail = detail[0 .. 220] ~ "...";
    return detail;
}

private string summarizeDiscordJsonError(string detail)
{
    auto jsonSlice = extractJsonSnippet(detail);
    if (jsonSlice.length == 0)
        return "";

    try
    {
        auto parsed = parseJSON(jsonSlice);
        auto message = parsed.object.get("message", JSONValue.init);
        if (message.type != JSONType.string)
            return "";

        auto root = "Discord API: " ~ message.str;
        auto code = parsed.object.get("code", JSONValue.init);
        if (code.type == JSONType.integer || code.type == JSONType.uinteger)
            root ~= " (code " ~ code.toString() ~ ")";

        auto nested = firstNestedApiError(parsed.object.get("errors", JSONValue.init));
        if (nested.length != 0)
            root ~= " — " ~ nested;
        return root;
    }
    catch (Exception)
    {
        return "";
    }
}

private string extractJsonSnippet(string source)
{
    ptrdiff_t open = -1;
    ptrdiff_t close = -1;

    foreach (index, ch; source)
    {
        if (ch == '{' && open == -1)
            open = cast(ptrdiff_t) index;
        if (ch == '}')
            close = cast(ptrdiff_t) index;
    }

    if (open == -1 || close == -1 || close <= open)
        return "";
    return source[open .. close + 1].strip;
}

private string firstNestedApiError(JSONValue errors)
{
    if (errors.type != JSONType.object)
        return "";

    auto rootErrors = errors.object.get("_errors", JSONValue.init);
    if (rootErrors.type == JSONType.array && rootErrors.array.length != 0)
    {
        auto message = rootErrors.array[0].object.get("message", JSONValue.init);
        if (message.type == JSONType.string)
            return message.str;
    }

    foreach (key, value; errors.object)
    {
        if (key == "_errors")
            continue;
        auto nested = firstNestedApiError(value);
        if (nested.length != 0)
            return key ~ ": " ~ nested;
    }

    return "";
}

private string contextualHandlerHint(string error)
{
    auto specialized = specializedInteractionHint(error);
    if (specialized.length != 0)
        return specialized;
    if (error.canFind("status code 0"))
    {
        return "The handler hit a network-level failure before Discord replied. Check connectivity/proxy/TLS and retry.";
    }
    return "The failure was logged on the bot side for debugging.";
}

private string specializedInteractionHint(string error)
{
    if (
        error.canFind("UNION_TYPE_CHOICES") ||
        (error.canFind("components") && error.canFind("text input"))
    )
    {
        return "Dropdown/file-style inputs are not available in this direct response payload. Use a component selection flow first, then modal text inputs.";
    }

    if (
        error.canFind("attachments") &&
        (error.canFind("This field is required") || error.canFind("missing"))
    )
    {
        return "Build attachments with `attach(...)`/`attachBytes(...)` or use `sendFile(...)`/`followupFile(...)` so Discord receives attachment ids correctly.";
    }

    return "";
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

unittest
{
    auto kind = classifyCommandFailure(
        "[ddiscord/http] Discord rejected the request payload as semantically invalid. Detail: " ~
        `{"message":"Invalid Form Body","code":50035}` ~
        " Hint: adjust fields."
    );
    assert(kind == CommandErrorKind.InvalidArgument);
}

unittest
{
    auto behavior = CommandErrorBehavior.verbose();
    CommandErrorContext context;
    context.kind = CommandErrorKind.Unknown;
    context.route = "interaction";
    context.commandName = "ship";
    context.error = "[ddiscord/http] The HTTP client failed while talking to Discord. " ~
        "Detail: Command `ship` failed with: " ~
        `{"message":"Invalid Form Body","code":50035,"errors":{"data":{"_errors":[{"message":"Component validation failed"}]}}}` ~
        " Hint: inspect payload.";

    auto payload = buildFailurePayload(behavior, "!", context);
    assert(payload.content.canFind("Discord API request failed"));
    assert(payload.content.canFind("Discord API: Invalid Form Body"));
    assert(payload.content.canFind("Component validation failed"));
}

unittest
{
    auto behavior = CommandErrorBehavior.verbose();
    CommandErrorContext context;
    context.kind = CommandErrorKind.HandlerFailure;
    context.route = "interaction";
    context.commandName = "report";
    context.error = "[ddiscord/http] status code 422 " ~
        `{"message":"Invalid Form Body","errors":{"data":{"components":{"_errors":[{"code":"UNION_TYPE_CHOICES","message":"Only one of text input or select is allowed."}]}}}}`;

    auto payload = buildFailurePayload(behavior, "!", context);
    assert(payload.content.canFind("Dropdown/file-style inputs are not available"));
}
