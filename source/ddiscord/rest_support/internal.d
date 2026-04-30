/**
 * ddiscord — internal REST support storage.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.rest_support.internal;

import core.sync.mutex : Mutex;
import ddiscord.models.application_command : ApplicationCommandDefinition;
import ddiscord.models.message : Message;
import ddiscord.util.snowflake : Snowflake;

package(ddiscord) final class MessageHistory
{
    private Mutex _mutex;
    private Message[] _messages;
    private ulong _nextId = 1;

    this()
    {
        _mutex = new Mutex;
    }

    void store(Message message)
    {
        synchronized (_mutex)
        {
            if (message.id.value == 0)
                message.id = Snowflake(_nextId++);
            _messages ~= message;
        }
    }

    Message[] items()
    {
        synchronized (_mutex)
            return _messages.dup;
    }

    Message[] inChannel(Snowflake channelId)
    {
        Message[] items;
        synchronized (_mutex)
        {
            foreach (message; _messages)
            {
                if (message.channelId == channelId)
                    items ~= message;
            }
        }
        return items;
    }
}

package(ddiscord) final class ApplicationCommandStore
{
    private Mutex _mutex;
    private ApplicationCommandDefinition[] _commands;

    this()
    {
        _mutex = new Mutex;
    }

    ApplicationCommandDefinition[] overwrite(ApplicationCommandDefinition[] definitions)
    {
        synchronized (_mutex)
        {
            _commands = definitions.dup;
            return _commands.dup;
        }
    }

    ApplicationCommandDefinition[] items()
    {
        synchronized (_mutex)
            return _commands.dup;
    }
}
