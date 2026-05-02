/**
 * ddiscord — public REST surface support types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.rest_support.types;

import core.time : Duration;
import ddiscord.core.http.client : HttpTransport;
import ddiscord.util.identity : DdiscordUserAgent;
import ddiscord.util.limits : DiscordApiBase;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;
import std.datetime : dur;

/// Minimal latency sample.
struct LatencySample
{
    long milliseconds;

    /// Returns the latency in the requested unit.
    long total(string unit)() const
    {
        static if (unit == "msecs")
            return milliseconds;
        else
            return milliseconds;
    }
}

/// Runtime configuration for the public REST client.
struct RestClientConfig
{
    string token;
    Nullable!Snowflake applicationId;
    string apiBase = DiscordApiBase;
    string userAgent = DdiscordUserAgent;
    Duration timeout = dur!"seconds"(15);
    size_t sessionPoolSize = 2;
    Duration maxSessionIdle = dur!"seconds"(55);
    bool autoRetryRateLimits = true;
    uint maxRateLimitRetries = 3;
    bool autoRetryServerErrors = true;
    uint maxServerErrorRetries = 3;
    Duration retryBaseDelay = dur!"msecs"(500);
    Duration maxRetryDelay = dur!"seconds"(30);
    Nullable!HttpTransport transport;
    LatencySample* latencyTarget;
}

/// Query options for listing channel messages.
struct MessageQuery
{
    Nullable!Snowflake before;
    Nullable!Snowflake after;
    Nullable!Snowflake around;
    ushort limit = 50;
}

/// Query options for listing users who reacted with one emoji.
struct ReactionQuery
{
    ushort limit = 25;
    Nullable!Snowflake after;
}

/// Session start limits returned by `GET /gateway/bot`.
struct GatewaySessionStartLimit
{
    uint total;
    uint remaining;
    uint resetAfterMilliseconds;
    uint maxConcurrency;
}

/// Gateway discovery payload returned by Discord.
struct GatewayBotInfo
{
    string url;
    uint shards;
    GatewaySessionStartLimit sessionStartLimit;
}
