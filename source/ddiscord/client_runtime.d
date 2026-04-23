/**
 * ddiscord — client runtime helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_runtime;

import ddiscord.util.snowflake : Snowflake;
import std.conv : to;
import std.datetime : Clock, SysTime;

/// Uptime helper used by docs, examples, and runtime diagnostics.
struct UptimeSample
{
    private bool _running;
    private SysTime _startedAt;
    private long _elapsedMilliseconds;

    /// Resets uptime tracking to zero.
    void reset()
    {
        _running = false;
        _startedAt = SysTime.init;
        _elapsedMilliseconds = 0;
    }

    /// Marks runtime startup.
    void markStarted()
    {
        if (_running)
            return;
        _running = true;
        _startedAt = Clock.currTime;
    }

    /// Marks runtime stop and accumulates elapsed time.
    void markStopped()
    {
        if (!_running)
            return;

        _elapsedMilliseconds += (Clock.currTime - _startedAt).total!"msecs";
        _running = false;
    }

    /// Returns whether uptime tracking is active.
    bool running() const @property
    {
        return _running;
    }

    /// Returns elapsed uptime in milliseconds.
    long milliseconds() const @property
    {
        if (!_running)
            return _elapsedMilliseconds;
        return _elapsedMilliseconds + (Clock.currTime - _startedAt).total!"msecs";
    }

    /// Returns human-readable uptime text.
    string toString() const
    {
        return formatUptimeMilliseconds(milliseconds);
    }
}

/// Returns current latency between now and a snowflake creation timestamp.
long snowflakeLatencyMilliseconds(Snowflake id)
{
    if (id.value == 0)
        return 0;

    enum unixEpochStdTime = 621355968000000000L;
    auto nowMs = cast(long) ((Clock.currTime.stdTime - unixEpochStdTime) / 10_000);
    auto createdMs = cast(long) id.timestampMilliseconds;
    if (nowMs <= createdMs)
        return 0;
    return nowMs - createdMs;
}

private string formatUptimeMilliseconds(long milliseconds)
{
    if (milliseconds <= 0)
        return "0s";

    auto totalSeconds = milliseconds / 1000;
    auto days = totalSeconds / 86_400;
    totalSeconds %= 86_400;
    auto hours = totalSeconds / 3_600;
    totalSeconds %= 3_600;
    auto minutes = totalSeconds / 60;
    auto seconds = totalSeconds % 60;

    string output;
    if (days != 0)
        output ~= days.to!string ~ "d ";
    if (hours != 0 || days != 0)
        output ~= hours.to!string ~ "h ";
    if (minutes != 0 || hours != 0 || days != 0)
        output ~= minutes.to!string ~ "m ";
    output ~= seconds.to!string ~ "s";
    return output;
}

unittest
{
    assert(formatUptimeMilliseconds(0) == "0s");
    assert(formatUptimeMilliseconds(999) == "0s");
    assert(formatUptimeMilliseconds(1_000) == "1s");
    assert(formatUptimeMilliseconds(61_000) == "1m 1s");
    assert(formatUptimeMilliseconds(3_661_000) == "1h 1m 1s");
    assert(formatUptimeMilliseconds(90_061_000) == "1d 1h 1m 1s");
}

unittest
{
    UptimeSample uptime;
    assert(!uptime.running);
    assert(uptime.milliseconds == 0);
    assert(uptime.toString() == "0s");
}

