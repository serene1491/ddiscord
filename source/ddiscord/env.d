/**
 * ddiscord — environment loader.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.env;

import ddiscord.util.errors : DdiscordException, formatError;
import std.conv : to;
import std.file : exists, isDir, readText;
import std.path : buildPath;
import std.process : environment;
import std.string : splitLines, strip;

/// Typed environment accessor.
struct EnvLoader
{
    private string[string] _values;

    /// Reads an environment variable or throws if missing.
    T require(T)(string key) const
    {
        auto value = valueFor(key);
        if (value is null)
        {
            throw new DdiscordException(formatError(
                "env",
                "A required environment variable is not set.",
                "Missing key: `" ~ key ~ "`.",
                "Create a `.env` file or export `" ~ key ~ "` in your shell before starting the bot."
            ));
        }

        return convert!T(key, value);
    }

    /// Reads an environment variable or returns a fallback.
    T get(T)(string key, lazy T fallback) const
    {
        auto value = valueFor(key);
        if (value is null)
            return fallback;
        return convert!T(key, value);
    }

    /// Reads a raw environment value if available.
    string get(string key) const
    {
        auto value = valueFor(key);
        return value is null ? "" : value;
    }

    private string valueFor(string key) const
    {
        auto value = key in _values;
        return value is null ? null : *value;
    }

    private T convert(T)(string key, string value) const
    {
        try
        {
            return value.to!T;
        }
        catch (Exception e)
        {
            throw new DdiscordException(formatError(
                "env",
                "An environment variable could not be converted to the requested type.",
                "Key `" ~ key ~ "` with value `" ~ value ~ "` failed conversion to `" ~ T.stringof ~ "`: " ~ e.msg,
                "Check the value format in `.env`, `.env.local`, or your shell environment."
            ));
        }
    }
}

/// Loads the host environment following the documented priority order.
///
/// `pathOrDirectory` may point to either:
/// - a directory containing `.env` and `.env.local`
/// - a specific `.env`-style file
EnvLoader loadEnv(string pathOrDirectory = ".")
{
    string[string] values;
    auto envSources = resolveEnvSources(pathOrDirectory);
    foreach (source; envSources)
        mergeFile(values, source);

    foreach (key, value; environment.toAA())
        values[key] = value;

    EnvLoader loader;
    loader._values = values;
    return loader;
}

private string[] resolveEnvSources(string pathOrDirectory)
{
    if (pathOrDirectory.length == 0)
        return [".env", ".env.local"];

    if (exists(pathOrDirectory) && isDir(pathOrDirectory))
    {
        return [
            buildPath(pathOrDirectory, ".env"),
            buildPath(pathOrDirectory, ".env.local")
        ];
    }

    return [pathOrDirectory];
}

private void mergeFile(ref string[string] values, string path)
{
    if (!exists(path))
        return;

    foreach (line; readText(path).splitLines())
    {
        auto trimmed = line.strip;
        if (trimmed.length == 0 || trimmed[0] == '#')
            continue;

        auto separator = indexOfEquals(trimmed);
        if (separator == -1)
            continue;

        auto key = trimmed[0 .. separator].strip;
        auto value = trimmed[separator + 1 .. $].strip;

        if (value.length >= 2)
        {
            auto first = value[0];
            auto last = value[$ - 1];
            if ((first == '"' && last == '"') || (first == '\'' && last == '\''))
                value = value[1 .. $ - 1];
        }

        values[key] = value;
    }
}

private int indexOfEquals(string value)
{
    foreach (index, ch; value)
    {
        if (ch == '=')
            return cast(int) index;
    }
    return -1;
}

unittest
{
    auto env = loadEnv();
    auto fallback = env.get!string("DDISCORD_UNITTEST_MISSING", "fallback");
    assert(fallback == "fallback");
}
