/**
 * ddiscord — Discord API error parsing helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.discord_api_error;

import ddiscord.util.optional : Nullable;
import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

/// Returns the Discord API numeric error code when one can be recovered from the payload text.
Nullable!ulong extractDiscordApiErrorCode(string text)
{
    auto snippet = extractJsonObjectSnippet(text);
    if (snippet.length == 0)
        return Nullable!ulong.init;

    try
    {
        auto parsed = parseJSON(snippet);
        if (parsed.type != JSONType.object)
            return Nullable!ulong.init;

        auto code = parsed.object.get("code", JSONValue.init);
        final switch (code.type)
        {
            case JSONType.integer:
                if (code.integer < 0)
                    return Nullable!ulong.init;
                return Nullable!ulong.of(cast(ulong) code.integer);
            case JSONType.uinteger:
                return Nullable!ulong.of(code.uinteger);
            case JSONType.string:
                try
                {
                    auto parsedCode = code.str.to!ulong;
                    return Nullable!ulong.of(parsedCode);
                }
                catch (Exception)
                {
                    return Nullable!ulong.init;
                }
            case JSONType.float_:
            case JSONType.object:
            case JSONType.array:
            case JSONType.true_:
            case JSONType.false_:
            case JSONType.null_:
                return Nullable!ulong.init;
        }
    }
    catch (Exception)
    {
        return Nullable!ulong.init;
    }
}

/// Returns whether the payload text contains the given Discord API numeric error code.
bool hasDiscordApiErrorCode(string text, ulong code)
{
    auto parsed = extractDiscordApiErrorCode(text);
    return !parsed.isNull && parsed.get == code;
}

/// Returns whether the payload text includes a Discord API `message` field containing `needle`.
bool discordApiMessageContains(string text, string needle)
{
    if (needle.length == 0)
        return false;

    auto snippet = extractJsonObjectSnippet(text);
    if (snippet.length == 0)
        return text.canFind(needle);

    try
    {
        auto parsed = parseJSON(snippet);
        if (parsed.type != JSONType.object)
            return text.canFind(needle);

        auto message = parsed.object.get("message", JSONValue.init);
        if (message.type != JSONType.string)
            return text.canFind(needle);

        return message.str.canFind(needle);
    }
    catch (Exception)
    {
        return text.canFind(needle);
    }
}

private string extractJsonObjectSnippet(string rawText)
{
    auto text = rawText.strip;
    if (text.length == 0)
        return "";

    if (text[0] == '{' && text[$ - 1] == '}')
        return text;

    ptrdiff_t open = -1;
    ptrdiff_t close = -1;

    foreach (index, ch; text)
    {
        if (ch == '{' && open == -1)
            open = cast(ptrdiff_t) index;
        if (ch == '}')
            close = cast(ptrdiff_t) index;
    }

    if (open == -1 || close == -1 || close <= open)
        return "";
    return text[open .. close + 1].strip;
}

unittest
{
    auto code = extractDiscordApiErrorCode(`{"message":"Missing Permissions","code":50013}`);
    assert(!code.isNull);
    assert(code.get == 50_013);
}

unittest
{
    assert(hasDiscordApiErrorCode(`Detail: {"message":"Unknown interaction","code":10062}`, 10_062));
    assert(!hasDiscordApiErrorCode(`{"message":"Invalid Form Body","code":50035}`, 50_013));
}

unittest
{
    assert(discordApiMessageContains(
        `{"message":"Interaction has already been acknowledged.","code":40060}`, "acknowledged")
    );
    assert(discordApiMessageContains("raw non-json error", "non-json"));
}
