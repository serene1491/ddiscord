/**
 * ddiscord — built-in help navigation IDs.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.help.navigation;

import core.time : dur;
import ddiscord.state : StateStore;
import ddiscord.util.errors : formatError;
import ddiscord.util.result : Result;
import ddiscord.util.snowflake : Snowflake;
import std.base64 : Base64URLNoPadding;
import std.conv : to;
import std.datetime : Clock;
import std.string : startsWith;

enum BuiltInHelpCustomIdPrefix = "ddiscord:help:v1";
enum BuiltInHelpNoopCustomId = BuiltInHelpCustomIdPrefix ~ ":noop";
enum BuiltInHelpPreviousLabel = "Previous";
enum BuiltInHelpNextLabel = "Next";
enum BuiltInHelpAccentColor = 0x5865F2;
enum BuiltInHelpDefaultPageSize = 6;

private enum MaxDiscordCustomIdLength = 100;
private enum QueryStorageScopePrefix = "help:query:";
private enum QueryStorageTtlDays = 14;

struct HelpNavigationTarget
{
    Snowflake ownerId;
    size_t page;
    string query;
}

string buildPersistentHelpCustomId(
    StateStore state,
    ref ulong sequence,
    Snowflake ownerId,
    string query,
    size_t page
)
{
    auto normalizedPage = page == 0 ? 1 : page;
    auto encodedQuery = Base64URLNoPadding.encode(cast(const(ubyte)[]) query);
    auto inlineCustomId = BuiltInHelpCustomIdPrefix ~ ":" ~
        ownerId.toString ~ ":" ~ normalizedPage.to!string ~ ":q:" ~ encodedQuery;

    // Prefer stateless IDs so navigation keeps working even after process restarts.
    if (inlineCustomId.length <= MaxDiscordCustomIdLength)
        return inlineCustomId.idup;

    sequence++;
    auto key = sequence.to!string;
    auto expiresAt = Clock.currTime + dur!"days"(QueryStorageTtlDays);
    state.global.set(storageKey(key), query, expiresAt);
    return BuiltInHelpCustomIdPrefix ~ ":" ~
        ownerId.toString ~ ":" ~ normalizedPage.to!string ~ ":k:" ~ key;
}

Result!(HelpNavigationTarget, string) parsePersistentHelpCustomId(StateStore state, string customId)
{
    if (customId == BuiltInHelpNoopCustomId)
        return Result!(HelpNavigationTarget, string).err("noop");

    if (!customId.startsWith(BuiltInHelpCustomIdPrefix ~ ":"))
    {
        return Result!(HelpNavigationTarget, string).err(formatError(
            "help",
            "The help interaction ID is not recognized.",
            "Received custom ID `" ~ customId ~ "`.",
            "Run the help command again to refresh the message."
        ));
    }

    auto parts = splitByColon(customId);
    if (parts.length != 7 || parts[0] != "ddiscord" || parts[1] != "help" || parts[2] != "v1")
    {
        return Result!(HelpNavigationTarget, string).err(formatError(
            "help",
            "The help interaction ID has an invalid format.",
            "Received custom ID `" ~ customId ~ "`.",
            "Run the help command again to refresh the message."
        ));
    }

    Snowflake ownerId;
    try
    {
        ownerId = Snowflake(parts[3].to!ulong);
    }
    catch (Exception)
    {
        return Result!(HelpNavigationTarget, string).err(formatError(
            "help",
            "The help interaction owner ID is invalid.",
            "Received owner fragment `" ~ parts[3] ~ "`.",
            "Run the help command again to refresh the message."
        ));
    }

    size_t page;
    try
    {
        page = parts[4].to!size_t;
    }
    catch (Exception)
    {
        return Result!(HelpNavigationTarget, string).err(formatError(
            "help",
            "The help interaction page is invalid.",
            "Received page fragment `" ~ parts[4] ~ "`.",
            "Run the help command again to refresh the message."
        ));
    }

    if (page == 0)
    {
        return Result!(HelpNavigationTarget, string).err(formatError(
            "help",
            "The help interaction page must be greater than zero.",
            "Received `0`.",
            "Run the help command again to refresh the message."
        ));
    }

    string query;
    if (parts[5] == "q")
    {
        try
        {
            auto decoded = Base64URLNoPadding.decode(parts[6]);
            query = cast(string) decoded.idup;
        }
        catch (Exception)
        {
            return Result!(HelpNavigationTarget, string).err(formatError(
                "help",
                "The help interaction query payload is invalid.",
                "Could not decode the query section in `" ~ customId ~ "`.",
                "Run the help command again to refresh the message."
            ));
        }
    }
    else if (parts[5] == "k")
    {
        query = state.global.getOr!string(storageKey(parts[6]), "");
        if (query.length == 0)
        {
            return Result!(HelpNavigationTarget, string).err(formatError(
                "help",
                "This help interaction has expired.",
                "The stored help query token `" ~ parts[6] ~ "` no longer exists.",
                "Run the help command again to create a fresh paginated view."
            ));
        }
    }
    else
    {
        return Result!(HelpNavigationTarget, string).err(formatError(
            "help",
            "The help interaction payload mode is invalid.",
            "Received mode `" ~ parts[5] ~ "`.",
            "Run the help command again to refresh the message."
        ));
    }

    HelpNavigationTarget target;
    target.ownerId = ownerId;
    target.page = page;
    target.query = query;
    return Result!(HelpNavigationTarget, string).ok(target);
}

private string storageKey(string key)
{
    return QueryStorageScopePrefix ~ key;
}

private string[] splitByColon(string value)
{
    string[] parts;
    string current;

    foreach (ch; value)
    {
        if (ch == ':')
        {
            parts ~= current;
            current = null;
        }
        else
        {
            current ~= ch;
        }
    }

    parts ~= current;
    return parts;
}

unittest
{
    auto state = new StateStore;
    ulong sequence;

    auto customId = buildPersistentHelpCustomId(state, sequence, Snowflake(42), "ping", 2);
    auto parsed = parsePersistentHelpCustomId(state, customId);

    assert(parsed.isOk);
    assert(parsed.value.ownerId == Snowflake(42));
    assert(parsed.value.page == 2);
    assert(parsed.value.query == "ping");
}

unittest
{
    auto state = new StateStore;
    ulong sequence;

    auto longQuery = "this-is-a-very-long-help-query-token-that-needs-external-storage-"
        ~ "because-it-will-not-fit-inside-discord-custom-id-length-limits";
    auto customId = buildPersistentHelpCustomId(state, sequence, Snowflake(7), longQuery, 3);
    assert(customId.length <= 100);

    auto parsed = parsePersistentHelpCustomId(state, customId);
    assert(parsed.isOk);
    assert(parsed.value.ownerId == Snowflake(7));
    assert(parsed.value.page == 3);
    assert(parsed.value.query == longQuery);
}
