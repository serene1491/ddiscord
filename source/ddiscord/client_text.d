/**
 * ddiscord — client text parsing helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_text;

import std.string : startsWith;

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

/// Tokenizes prefix content while preserving quoted segments.
string[] tokenizePrefixContent(string input)
{
    string[] tokens;
    string current;
    bool inQuote;
    char quote;

    foreach (ch; input)
    {
        if (inQuote)
        {
            if (ch == quote)
            {
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
    assert(attemptedPrefixCommandName("!", "!ping 123") == "ping");
    assert(attemptedPrefixCommandName("!", "!") == "!");
    assert(attemptedPrefixCommandName("!", "hello") == "[prefix]");
}

