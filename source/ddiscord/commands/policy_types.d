/**
 * ddiscord — command policy UDAs and rate-limit types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.commands.policy_types;

import core.time : Duration;

/// Marks a command that requires bot ownership.
struct RequireOwner
{
}

/// Marks a command that requires specific permissions.
struct RequirePermissions
{
    ulong permissions;

    this(ulong permissions)
    {
        this.permissions = permissions;
    }
}

/// Singular alias for `RequirePermissions`.
alias RequirePermission = RequirePermissions;

/// Rate limit bucket selector.
enum RateLimitBucket
{
    User,
    Guild,
    Channel,
    Global,
}

/// Rate limit attribute.
struct RateLimit
{
    uint count;
    Duration window;
    RateLimitBucket bucket;

    this(uint count, Duration window, RateLimitBucket bucket = RateLimitBucket.User)
    {
        this.count = count;
        this.window = window;
        this.bucket = bucket;
    }
}

/// Alias for `RateLimit` with the same payload semantics.
alias CooldownRate = RateLimit;
