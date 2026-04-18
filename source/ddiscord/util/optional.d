/**
 * ddiscord — lightweight nullable container.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.optional;

import std.exception : enforce;

/// Lightweight nullable value container.
struct Nullable(T)
{
    private bool _isNull = true;
    private T _value;

    /// Returns whether the container has no value.
    bool isNull() const @property
    {
        return _isNull;
    }

    /// Returns the wrapped value.
    ref inout(T) get() inout @property
    {
        enforce(!_isNull, "Nullable value is null.");
        return _value;
    }

    /// Returns the wrapped value or a fallback.
    T getOr(scope T fallback)
    {
        return _isNull ? fallback : _value;
    }

    /// Returns the wrapped value or a fallback.
    const(T) getOr(scope const(T) fallback) const
    {
        return _isNull ? fallback : _value;
    }

    /// Transforms the value if present.
    auto map(F)(scope F fn)
    {
        alias Mapped = typeof(fn(T.init));

        if (_isNull)
            return Nullable!Mapped.init;

        return Nullable!Mapped.of(fn(_value));
    }

    /// Returns this value or a lazily-created replacement.
    Nullable!T orElse(scope Nullable!T delegate() fallback)
    {
        return _isNull ? fallback() : this;
    }

    /// Transforms the value if present.
    auto map(F)(scope F fn) const
    {
        alias Mapped = typeof(fn(T.init));

        if (_isNull)
            return Nullable!Mapped.init;

        return Nullable!Mapped.of(fn(_value));
    }

    /// Returns this value or a lazily-created replacement.
    const(Nullable!T) orElse(scope const(Nullable!T) delegate() fallback) const
    {
        return _isNull ? fallback() : this;
    }

    /// Creates a non-null container.
    static Nullable!T of(T value)
    {
        Nullable!T result;
        result._isNull = false;
        result._value = value;
        return result;
    }
}

unittest
{
    auto value = Nullable!int.of(42);
    int doubler(int x)
    {
        return x * 2;
    }

    assert(!value.isNull);
    assert(value.get == 42);
    assert(value.getOr(10) == 42);
    assert(value.map(&doubler).get == 84);
}

unittest
{
    Nullable!string none;
    assert(none.isNull);
    assert(none.getOr("fallback") == "fallback");
    assert(none.orElse(() => Nullable!string.of("alt")).get == "alt");
}
