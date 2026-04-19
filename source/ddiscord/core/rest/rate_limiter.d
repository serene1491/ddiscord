/**
 * ddiscord — Discord REST rate limiter.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.core.rest.rate_limiter;

import core.sync.mutex : Mutex;
import ddiscord.util.errors : formatError;
import ddiscord.util.limits : DiscordGlobalRestRequestsPerSecond;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import std.array : appender;
import std.conv : to;
import std.datetime : Clock, Duration, SysTime;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : split, strip;
import core.thread : Thread;
import core.time : dur;

/// Parsed outcome of rate-limit handling.
struct RateLimitOutcome
{
    bool shouldRetry;
    Duration waitTime;
    bool global;
}

/// Rate-limit state for a Discord bucket.
struct RateLimitBucketState
{
    string bucketId;
    uint limit;
    int remaining = int.max;
    SysTime resetAt;
}

/// Blocking REST rate limiter for sequential client usage.
final class RestRateLimiter
{
    private Mutex _stateMutex;
    private RateLimitBucketState[string] _bucketStates;
    private string[string] _routeToBucket;
    private SysTime _globalResetAt;

    this()
    {
        _stateMutex = new Mutex;
    }

    /// Waits until a route is safe to call again.
    void acquire(string routeKey)
    {
        Duration waitTime = Duration.zero;

        synchronized (_stateMutex)
        {
            auto now = Clock.currTime;
            if (_globalResetAt > now)
                waitTime = _globalResetAt - now;

            auto bucketId = routeKeyToBucket(routeKey);
            if (!bucketId.isNull)
            {
                auto statePtr = bucketId.get in _bucketStates;
                if (statePtr !is null && (*statePtr).remaining <= 0 && (*statePtr).resetAt > now)
                {
                    auto bucketWait = (*statePtr).resetAt - now;
                    if (bucketWait > waitTime)
                        waitTime = bucketWait;
                }
            }
        }

        if (waitTime > Duration.zero)
            sleepFor(waitTime);
    }

    /// Updates bucket and global state from a response.
    RateLimitOutcome update(
        string routeKey,
        ushort statusCode,
        string[string] headers,
        string body = ""
    )
    {
        RateLimitOutcome outcome;

        synchronized (_stateMutex)
        {
            auto bucketId = getHeader(headers, "x-ratelimit-bucket");
            if (!bucketId.isNull)
                _routeToBucket[routeKey] = bucketId.get;

            auto effectiveBucket = routeKeyToBucket(routeKey).getOr("");
            if (effectiveBucket.length != 0)
            {
                auto state = _bucketStates.get(effectiveBucket, RateLimitBucketState.init);
                state.bucketId = effectiveBucket;

                auto limit = parseUIntHeader(headers, "x-ratelimit-limit");
                if (!limit.isNull)
                    state.limit = limit.get;

                auto remaining = parseIntHeader(headers, "x-ratelimit-remaining");
                if (!remaining.isNull)
                    state.remaining = remaining.get;

                auto resetAfter = parseDurationHeader(headers, "x-ratelimit-reset-after");
                if (!resetAfter.isNull)
                    state.resetAt = Clock.currTime + resetAfter.get;

                _bucketStates[effectiveBucket] = state;
            }

            if (statusCode != 429)
                return outcome;

            auto retryAfter = parseRetryAfter(headers, body);
            auto scopeName = getHeader(headers, "x-ratelimit-scope").getOr("");
            auto isGlobal = getHeader(headers, "x-ratelimit-global").getOr("") == "true" || scopeName == "global";

            if (retryAfter.isNull && isGlobal)
                retryAfter = Nullable!Duration.of(dur!"seconds"(60));

            if (!retryAfter.isNull)
            {
                outcome.shouldRetry = true;
                outcome.waitTime = retryAfter.get;
                outcome.global = isGlobal;

                if (isGlobal)
                    _globalResetAt = Clock.currTime + retryAfter.get;
                else if (effectiveBucket.length != 0)
                {
                    auto state = _bucketStates.get(effectiveBucket, RateLimitBucketState.init);
                    state.bucketId = effectiveBucket;
                    state.remaining = 0;
                    state.resetAt = Clock.currTime + retryAfter.get;
                    _bucketStates[effectiveBucket] = state;
                }
            }
        }

        return outcome;
    }

    /// Returns the configured Discord-wide soft limit used by the client.
    uint globalRequestsPerSecond() const @property
    {
        return DiscordGlobalRestRequestsPerSecond;
    }

    private Nullable!string routeKeyToBucket(string routeKey)
    {
        if (auto bucket = routeKey in _routeToBucket)
            return Nullable!string.of(*bucket);
        return Nullable!string.init;
    }

    private void sleepFor(Duration amount)
    {
        if (amount <= Duration.zero)
            return;
        Thread.sleep(amount);
    }
}

private Nullable!string getHeader(string[string] headers, string name)
{
    foreach (key, value; headers)
    {
        if (normalizeHeader(key) == normalizeHeader(name))
            return Nullable!string.of(value.strip);
    }
    return Nullable!string.init;
}

private Nullable!uint parseUIntHeader(string[string] headers, string name)
{
    auto value = getHeader(headers, name);
    if (value.isNull)
        return Nullable!uint.init;

    try
    {
        return Nullable!uint.of(value.get.to!uint);
    }
    catch (Exception)
    {
        return Nullable!uint.init;
    }
}

private Nullable!int parseIntHeader(string[string] headers, string name)
{
    auto value = getHeader(headers, name);
    if (value.isNull)
        return Nullable!int.init;

    try
    {
        return Nullable!int.of(value.get.to!int);
    }
    catch (Exception)
    {
        return Nullable!int.init;
    }
}

private Nullable!Duration parseDurationHeader(string[string] headers, string name)
{
    auto value = getHeader(headers, name);
    if (value.isNull)
        return Nullable!Duration.init;

    try
    {
        return Nullable!Duration.of(parseSeconds(value.get));
    }
    catch (Exception)
    {
        return Nullable!Duration.init;
    }
}

private Nullable!Duration parseRetryAfter(string[string] headers, string body)
{
    auto headerValue = getHeader(headers, "retry-after");
    if (!headerValue.isNull)
    {
        try
        {
            return Nullable!Duration.of(parseSeconds(headerValue.get));
        }
        catch (Exception)
        {
        }
    }

    if (body.length != 0)
    {
        try
        {
            auto json = parseJSON(body);
            auto retryAfter = json.object.get("retry_after", JSONValue.init);
            if (retryAfter.type != JSONType.null_)
            {
                auto value = retryAfter.type == JSONType.float_
                    ? retryAfter.floating
                    : retryAfter.integer;
                return Nullable!Duration.of(parseSeconds(value.to!string));
            }
        }
        catch (Exception)
        {
        }
    }

    return Nullable!Duration.init;
}

private Duration parseSeconds(string value)
{
    auto trimmed = value.strip;
    auto parts = trimmed.split(".");
    auto seconds = parts[0].length == 0 ? 0L : parts[0].to!long;
    auto result = dur!"seconds"(seconds);

    if (parts.length > 1)
    {
        auto fraction = parts[1];
        if (fraction.length > 3)
            fraction = fraction[0 .. 3];
        while (fraction.length < 3)
            fraction ~= "0";
        result += dur!"msecs"(fraction.to!long);
    }

    return result;
}

private string normalizeHeader(string value)
{
    auto builder = appender!string;
    foreach (ch; value)
    {
        if (ch >= 'A' && ch <= 'Z')
            builder.put(cast(char) (ch + 32));
        else
            builder.put(ch);
    }
    return builder.data;
}

unittest
{
    auto limiter = new RestRateLimiter;
    string[string] headers;
    headers["X-RateLimit-Bucket"] = "abc";
    headers["X-RateLimit-Limit"] = "5";
    headers["X-RateLimit-Remaining"] = "0";
    headers["X-RateLimit-Reset-After"] = "1";

    auto outcome = limiter.update("POST:/channels/1/messages", 200, headers);
    assert(!outcome.shouldRetry);
}

unittest
{
    auto limiter = new RestRateLimiter;
    string[string] headers;
    headers["Retry-After"] = "1.5";
    headers["X-RateLimit-Global"] = "true";
    headers["X-RateLimit-Scope"] = "global";

    auto outcome = limiter.update("GET:/users/@me", 429, headers, `{"message":"You are being rate limited.","retry_after":1.5,"global":true}`);
    assert(outcome.shouldRetry);
    assert(outcome.global);
}
