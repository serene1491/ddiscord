/**
 * ddiscord — service container.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.services;

import ddiscord.util.errors : DdiscordException, formatError;
import std.variant : Variant;

/// Lightweight DI container backed by type keys.
final class ServiceContainer
{
    private Variant[TypeInfo] _instances;

    /// Registers an already-created instance by type.
    void add(T)(T instance)
    {
        _instances[typeid(T)] = Variant(instance);
    }

    /// Registers a default-constructed instance by type.
    void add(T)()
        if (is(T == class) || is(T == struct))
    {
        static if (is(T == class))
            add!T(new T);
        else
            add!T(T.init);
    }

    /// Registers an implementation for an interface or base type.
    void add(T, Impl : T)()
    {
        static if (is(Impl == class))
            add!T(cast(T) new Impl);
        else
            add!T(cast(T) Impl.init);
    }

    /// Registers an instance produced by a factory.
    void addFactory(T)(T delegate() factory)
    {
        add!T(factory());
    }

    /// Returns whether the container has a registration for T.
    bool has(T)() const
    {
        return cast(bool) (typeid(T) in _instances);
    }

    /// Tries to read a registered instance without creating one.
    bool tryGet(T)(out T value)
    {
        if (auto stored = typeid(T) in _instances)
        {
            value = (*stored).get!T;
            return true;
        }

        value = T.init;
        return false;
    }

    /// Returns a registered instance, creating a default one if possible.
    T get(T)()
    {
        if (auto stored = typeid(T) in _instances)
            return (*stored).get!T;

        static if (is(T == class))
        {
            auto instance = new T;
            add!T(instance);
            return instance;
        }
        else static if (is(T == struct))
        {
            auto instance = T.init;
            add!T(instance);
            return instance;
        }
        else
        {
            throw new DdiscordException(formatError(
                "services",
                "A requested service is not registered in the container.",
                "Missing service: `" ~ typeid(T).toString ~ "`.",
                "Register the service before use or inject it through the client setup path."
            ));
        }
    }

    /// Removes a registration.
    void remove(T)()
    {
        _instances.remove(typeid(T));
    }

    /// Creates a shallow child container.
    ServiceContainer fork()
    {
        auto child = new ServiceContainer;
        child._instances = _instances.dup;
        return child;
    }
}
