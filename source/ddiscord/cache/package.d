/**
 * ddiscord — in-memory cache store.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.cache;

import ddiscord.models.channel : Channel;
import ddiscord.models.message : Message;
import ddiscord.models.user : User;
import ddiscord.util.optional : Nullable;
import ddiscord.util.snowflake : Snowflake;

/// In-memory cache for common Discord entities.
final class CacheStore
{
    private User[ulong] _users;
    private Channel[ulong] _channels;
    private Message[ulong] _messages;

    /// Stores a user.
    void store(User user)
    {
        _users[user.id.value] = user;
    }

    /// Stores a channel.
    void store(Channel channel)
    {
        _channels[channel.id.value] = channel;
    }

    /// Stores a message.
    void store(Message message)
    {
        _messages[message.id.value] = message;
    }

    /// Looks up a user.
    Nullable!User user(Snowflake id)
    {
        if (auto value = id.value in _users)
            return Nullable!User.of(*value);
        return Nullable!User.init;
    }

    /// Looks up a channel.
    Nullable!Channel channel(Snowflake id)
    {
        if (auto value = id.value in _channels)
            return Nullable!Channel.of(*value);
        return Nullable!Channel.init;
    }

    /// Looks up a message.
    Nullable!Message message(Snowflake id)
    {
        if (auto value = id.value in _messages)
            return Nullable!Message.of(*value);
        return Nullable!Message.init;
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
