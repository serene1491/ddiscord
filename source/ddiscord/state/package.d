/**
 * ddiscord — in-memory scoped state store.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.state;

import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.variant : Variant;

private struct StateEntry
{
    Variant value;
    bool hasExpiry;
    SysTime expiresAt;
}

/// Scoped state view.
struct StateScope
{
    private StateEntry[string]* _entries;

    /// Writes a value into the scope.
    void set(T)(string key, T value, SysTime expiresAt = SysTime.init)
    {
        StateEntry entry;
        entry.value = Variant(value);
        entry.hasExpiry = expiresAt != SysTime.init;
        entry.expiresAt = expiresAt;
        (*_entries)[key] = entry;
    }

    /// Reads a typed value from the scope.
    T get(T)(string key)
    {
        auto entry = requireEntry(key);
        return entry.value.get!T;
    }

    /// Reads a typed value or fallback.
    T getOr(T)(string key, T fallback)
    {
        auto entryPtr = key in *_entries;
        if (entryPtr is null || expired(*entryPtr))
            return fallback;
        return (*entryPtr).value.get!T;
    }

    private StateEntry requireEntry(string key)
    {
        auto entryPtr = key in *_entries;
        if (entryPtr is null)
        {
            throw new DdiscordException(formatError(
                "state",
                "The requested state key does not exist.",
                "Missing key: `" ~ key ~ "`.",
                "Use `getOr` when a missing key is expected, or initialize the key before reading it."
            ));
        }

        if (expired(*entryPtr))
        {
            (*_entries).remove(key);
            throw new DdiscordException(formatError(
                "state",
                "The requested state key has already expired.",
                "Expired key: `" ~ key ~ "`.",
                "Refresh the value, extend its TTL, or use `getOr` to provide a fallback."
            ));
        }
        return *entryPtr;
    }

    private bool expired(StateEntry entry)
    {
        return entry.hasExpiry && Clock.currTime >= entry.expiresAt;
    }
}

/// In-memory state root with Discord-like scopes.
final class StateStore
{
    private StateEntry[string][string] _storage;

    /// Global scope.
    StateScope global() @property
    {
        return scopeFor("global");
    }

    /// Guild scope.
    StateScope guild(Snowflake guildId)
    {
        return scopeFor("guild:" ~ guildId.toString);
    }

    /// Channel scope.
    StateScope channel(Snowflake channelId)
    {
        return scopeFor("channel:" ~ channelId.toString);
    }

    /// User scope.
    StateScope user(Snowflake userId)
    {
        return scopeFor("user:" ~ userId.toString);
    }

    /// Member scope.
    StateScope member(Snowflake guildId, Snowflake userId)
    {
        return scopeFor("member:" ~ guildId.toString ~ ":" ~ userId.toString);
    }

    private StateScope scopeFor(string key)
    {
        auto _ = key in _storage;
        if (_ is null)
        {
            StateEntry[string] entries;
            _storage[key] = entries;
        }

        StateScope stateScope;
        stateScope._entries = &_storage[key];
        return stateScope;
    }
}

unittest
{
    auto state = new StateStore;
    state.global.set("count", 3);
    assert(state.global.get!int("count") == 3);
    assert(state.global.getOr!int("missing", 9) == 9);
}
