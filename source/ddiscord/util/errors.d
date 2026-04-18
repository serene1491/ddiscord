/**
 * ddiscord — shared exception and error formatting helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.errors;

import std.array : appender;

/// Exception thrown by fallible convenience APIs when a `Result` is not returned.
final class DdiscordException : Exception
{
    this(string message, Throwable next = null, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(message, file, line, next);
    }
}

/// Builds a consistently formatted developer-facing error message.
string formatError(
    string scopeName,
    string summary,
    string detail = "",
    string hint = ""
) @safe
{
    auto builder = appender!string;
    builder.put("[ddiscord/");
    builder.put(scopeName);
    builder.put("] ");
    builder.put(summary);

    if (detail.length != 0)
    {
        builder.put(" Detail: ");
        builder.put(detail);
    }

    if (hint.length != 0)
    {
        builder.put(" Hint: ");
        builder.put(hint);
    }

    return builder.data;
}
