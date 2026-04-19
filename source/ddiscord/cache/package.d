/**
 * ddiscord — in-memory cache store.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.cache;

import core.sync.mutex : Mutex;
import ddiscord.models.channel : Channel;
import ddiscord.models.guild : Guild;
import ddiscord.models.message : Message;
import ddiscord.models.role : Role;
import ddiscord.models.user : User;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;

/// In-memory cache for common Discord entities.
final class CacheStore
{
    private Mutex _mutex;
    private User[ulong] _users;
    private Channel[ulong] _channels;
    private Guild[ulong] _guilds;
    private Role[ulong] _roles;
    private Message[ulong] _messages;

    this()
    {
        _mutex = new Mutex;
    }

    /// Stores a user.
    void store(User user)
    {
        synchronized (_mutex)
            _users[user.id.value] = user;
    }

    /// Stores a channel.
    void store(Channel channel)
    {
        synchronized (_mutex)
            _channels[channel.id.value] = channel;
    }

    /// Stores a guild.
    void store(Guild guild)
    {
        synchronized (_mutex)
            _guilds[guild.id.value] = guild;
    }

    /// Stores a role.
    void store(Role role)
    {
        synchronized (_mutex)
            _roles[role.id.value] = role;
    }

    /// Stores a message.
    void store(Message message)
    {
        synchronized (_mutex)
            _messages[message.id.value] = message;
    }

    /// Looks up a user.
    Nullable!User user(Snowflake id)
    {
        synchronized (_mutex)
        {
            if (auto value = id.value in _users)
                return Nullable!User.of(*value);
            return Nullable!User.init;
        }
    }

    /// Looks up a channel.
    Nullable!Channel channel(Snowflake id)
    {
        synchronized (_mutex)
        {
            if (auto value = id.value in _channels)
                return Nullable!Channel.of(*value);
            return Nullable!Channel.init;
        }
    }

    /// Looks up a guild.
    Nullable!Guild guild(Snowflake id)
    {
        synchronized (_mutex)
        {
            if (auto value = id.value in _guilds)
                return Nullable!Guild.of(*value);
            return Nullable!Guild.init;
        }
    }

    /// Looks up a role.
    Nullable!Role role(Snowflake id)
    {
        synchronized (_mutex)
        {
            if (auto value = id.value in _roles)
                return Nullable!Role.of(*value);
            return Nullable!Role.init;
        }
    }

    /// Looks up a message.
    Nullable!Message message(Snowflake id)
    {
        synchronized (_mutex)
        {
            if (auto value = id.value in _messages)
                return Nullable!Message.of(*value);
            return Nullable!Message.init;
        }
    }
}

unittest
{
    auto cache = new CacheStore;
    User user;
    user.id = Snowflake(1);
    user.username = "alice";
    cache.store(user);
    assert(cache.user(Snowflake(1)).get.username == "alice");
}
