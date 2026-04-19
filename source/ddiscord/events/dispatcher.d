/**
 * ddiscord — typed event dispatcher.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.events.dispatcher;

import core.sync.mutex : Mutex;
import ddiscord.util.errors : formatError;
import std.algorithm : filter;
import std.array : array;
import std.variant : Variant;

private struct HandlerEntry(E)
{
    bool once;
    void delegate(E) handler;
}

/// Lightweight typed event dispatcher.
final class EventDispatcher
{
    private Mutex _mutex;
    private Variant[string] _handlers;
    private string[] _handlerErrors;

    this()
    {
        _mutex = new Mutex;
    }

    /// Registers a handler for an event type.
    void on(E)(void delegate(E) handler)
    {
        auto key = typeid(E).toString;
        synchronized (_mutex)
        {
            auto handlers = entries!E(key);
            handlers ~= HandlerEntry!E(false, handler);
            _handlers[key] = Variant(handlers);
        }
    }

    /// Registers a one-shot handler for an event type.
    void once(E)(void delegate(E) handler)
    {
        auto key = typeid(E).toString;
        synchronized (_mutex)
        {
            auto handlers = entries!E(key);
            handlers ~= HandlerEntry!E(true, handler);
            _handlers[key] = Variant(handlers);
        }
    }

    /// Removes a handler.
    void off(E)(void delegate(E) handler)
    {
        auto key = typeid(E).toString;
        synchronized (_mutex)
        {
            auto handlers = entries!E(key);
            handlers = handlers.filter!(entry => entry.handler != handler).array;
            _handlers[key] = Variant(handlers);
        }
    }

    /// Emits an event to all handlers of that type.
    void emit(E)(E event)
    {
        auto key = typeid(E).toString;
        HandlerEntry!E[] handlers;
        synchronized (_mutex)
            handlers = entries!E(key);
        HandlerEntry!E[] survivors;

        foreach (entry; handlers)
        {
            try
            {
                entry.handler(event);
            }
            catch (Throwable error)
            {
                synchronized (_mutex)
                {
                    _handlerErrors ~= formatError(
                        "events",
                        "An event handler raised an exception.",
                        "Event `" ~ typeid(E).toString ~ "` failed with: " ~ error.msg,
                        "Inspect the handler implementation; the dispatcher continued running other handlers."
                    );
                }
            }

            if (!entry.once)
                survivors ~= entry;
        }

        synchronized (_mutex)
            _handlers[key] = Variant(survivors);
    }

    private HandlerEntry!E[] entries(E)(string key)
    {
        if (auto existing = key in _handlers)
            return (*existing).get!(HandlerEntry!E[]).dup;
        return null;
    }

    /// Returns captured event handler failures.
    string[] handlerErrors() const @property
    {
        synchronized (_mutex)
            return _handlerErrors.dup;
    }
}

unittest
{
    auto dispatcher = new EventDispatcher;
    int calls;

    dispatcher.on!int((value) { calls += value; });
    dispatcher.emit!int(3);

    assert(calls == 3);
}

unittest
{
    auto dispatcher = new EventDispatcher;
    int calls;

    dispatcher.once!int((value) { calls += value; });
    dispatcher.emit!int(2);
    dispatcher.emit!int(2);

    assert(calls == 2);
}

unittest
{
    auto dispatcher = new EventDispatcher;
    bool survivorRan;

    dispatcher.on!int((_) { throw new Exception("boom"); });
    dispatcher.on!int((_) { survivorRan = true; });
    dispatcher.emit!int(1);

    assert(survivorRan);
    assert(dispatcher.handlerErrors.length == 1);
}
