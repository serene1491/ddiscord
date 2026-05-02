/**
 * ddiscord — shared backoff helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.core.backoff;

import std.datetime : Clock, Duration;
import core.time : dur;

/// Default bounded jitter percentage used for retry and reconnect sleeps.
enum DefaultBackoffJitterPercent = 20;

/// Denominator used for percent-based jitter calculations.
enum BackoffJitterDenominator = 100;

/// Base value that keeps jitter ranges non-empty.
enum BackoffJitterBase = 1;

/// Returns an exponential backoff delay capped by `maxDelay`.
Duration cappedExponentialBackoff(Duration delay, Duration maxDelay)
{
    if (delay <= Duration.zero)
        return delay;

    auto doubled = delay + delay;
    if (maxDelay <= Duration.zero || doubled <= maxDelay)
        return doubled;
    return maxDelay;
}

/// Adds bounded pseudo-random jitter derived from wall-clock ticks.
Duration addClockJitter(Duration delay, uint jitterPercent = DefaultBackoffJitterPercent)
{
    if (delay <= Duration.zero || jitterPercent == 0)
        return delay;

    auto baseMs = delay.total!"msecs";
    if (baseMs <= 0)
        return delay;

    auto maxJitterMs = (baseMs * jitterPercent) / BackoffJitterDenominator;
    if (maxJitterMs <= 0)
        return delay;

    auto tick = Clock.currTime.stdTime;
    auto jitterMs = (tick % (maxJitterMs + BackoffJitterBase));
    return delay + dur!"msecs"(jitterMs);
}

unittest
{
    auto delay = dur!"seconds"(10);
    auto jittered = addClockJitter(delay);
    assert(jittered >= delay);
    assert(jittered <= dur!"seconds"(12));
}

unittest
{
    auto next = cappedExponentialBackoff(dur!"seconds"(4), dur!"seconds"(10));
    assert(next == dur!"seconds"(8));

    auto capped = cappedExponentialBackoff(dur!"seconds"(8), dur!"seconds"(10));
    assert(capped == dur!"seconds"(10));
}
