/**
 * ddiscord — client text parsing helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_text;

import std.ascii : toLower;
import std.string : indexOf, startsWith, strip;

/// Returns the attempted prefix command name from a raw message content.
string attemptedPrefixCommandName(string prefix, string content)
{
    if (!content.startsWith(prefix))
        return "[prefix]";

    auto tokens = tokenizePrefixContent(content[prefix.length .. $]);
    if (tokens.length == 0)
        return prefix;
    return tokens[0];
}

/// Parsed prefix invocation with command name and raw argument segment.
struct PrefixInvocation
{
    string name;
    string args;
}

/// Parses prefixed command invocation into lowercase name and raw args.
PrefixInvocation parsePrefixInvocation(string prefix, string content)
{
    PrefixInvocation invocation;
    if (!content.startsWith(prefix))
        return invocation;

    auto body = content[prefix.length .. $].strip;
    auto splitAt = body.indexOf(' ');
    if (splitAt == -1)
    {
        invocation.name = asciiLower(body);
        return invocation;
    }

    invocation.name = asciiLower(body[0 .. splitAt]);
    invocation.args = body[splitAt + 1 .. $].strip;
    return invocation;
}

/// Tokenizes prefix content while preserving quoted segments.
string[] tokenizePrefixContent(string input)
{
    string[] tokens;
    string current;
    bool inQuote;
    char quote;
    bool preserveQuoteChars;

    foreach (ch; input)
    {
        if (inQuote)
        {
            if (ch == quote)
            {
                if (preserveQuoteChars)
                    current ~= ch;
                inQuote = false;
            }
            else
            {
                current ~= ch;
            }

            continue;
        }

        if (ch == '"' || ch == '\'')
        {
            inQuote = true;
            quote = ch;
            preserveQuoteChars = current.length != 0;
            if (preserveQuoteChars)
                current ~= ch;
            continue;
        }

        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        {
            if (current.length != 0)
            {
                tokens ~= current;
                current = null;
            }
            continue;
        }

        current ~= ch;
    }

    if (current.length != 0)
        tokens ~= current;

    return tokens;
}

unittest
{
    auto tokens = tokenizePrefixContent(`run "hello world" test`);
    assert(tokens.length == 3);
    assert(tokens[0] == "run");
    assert(tokens[1] == "hello world");
    assert(tokens[2] == "test");
}

unittest
{
    auto tokens = tokenizePrefixContent(`save-script say2 server log.info("hello world")`);
    assert(tokens.length == 4);
    assert(tokens[3] == `log.info("hello world")`);
}

unittest
{
    assert(attemptedPrefixCommandName("!", "!ping 123") == "ping");
    assert(attemptedPrefixCommandName("!", "!") == "!");
    assert(attemptedPrefixCommandName("!", "hello") == "[prefix]");
}

unittest
{
    auto parsed = parsePrefixInvocation("&", "&run test hello world");
    assert(parsed.name == "run");
    assert(parsed.args == "test hello world");
}

private string asciiLower(string input)
{
    auto lowered = input.dup;
    foreach (index, ch; lowered)
        lowered[index] = toLower(ch);
    return lowered.idup;
}
