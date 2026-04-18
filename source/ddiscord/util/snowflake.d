/**
 * ddiscord — Discord snowflake wrapper.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.snowflake;

import std.conv : to;

/// Discord epoch in milliseconds.
enum discordEpoch = 1_420_070_400_000UL;

/// Human-readable timestamp wrapper used by docs and examples.
struct SnowflakeTimestamp
{
    string rendered;

    /// Simple printable form.
    string toSimpleString() const @property
    {
        return rendered;
    }
}

/// Typed wrapper around a Discord snowflake identifier.
struct Snowflake
{
    ulong value;

    /// Creates a new snowflake wrapper.
    this(ulong value)
    {
        this.value = value;
    }

    /// String representation.
    string toString() const
    {
        return value.to!string;
    }

    /// Approximate creation time derived from the snowflake.
    SnowflakeTimestamp createdAt() const @property
    {
        const timestampMs = (value >> 22) + discordEpoch;
        return SnowflakeTimestamp(timestampMs.to!string);
    }
}
