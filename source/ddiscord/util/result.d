/**
 * ddiscord — result container.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.result;

import std.exception : enforce;

/// Tagged result type for fallible operations.
struct Result(T, E)
{
    private bool _isOk;
    private T _value = T.init;
    private E _error = E.init;

    /// Creates a success result.
    static Result!(T, E) ok(T value)
    {
        Result!(T, E) result;
        result._isOk = true;
        result._value = value;
        return result;
    }

    /// Creates an error result.
    static Result!(T, E) err(E error)
    {
        Result!(T, E) result;
        result._isOk = false;
        result._error = error;
        return result;
    }

    /// Returns whether the result is successful.
    bool isOk() const @property
    {
        return _isOk;
    }

    /// Returns whether the result is an error.
    bool isErr() const @property
    {
        return !_isOk;
    }

    /// Returns the successful value.
    ref inout(T) value() inout @property
    {
        enforce(_isOk, "Result does not contain a value.");
        return _value;
    }

    /// Returns the error value.
    ref inout(E) error() inout @property
    {
        enforce(!_isOk, "Result does not contain an error.");
        return _error;
    }

    /// Maps the success value if present.
    auto map(F)(scope F fn)
    {
        alias Mapped = typeof(fn(T.init));

        if (_isOk)
            return Result!(Mapped, E).ok(fn(_value));

        return Result!(Mapped, E).err(_error);
    }

    /// Flat-maps the success value if present.
    auto flatMap(F)(scope F fn)
    {
        alias Mapped = typeof(fn(T.init));
        static assert(is(Mapped == Result!(U, V), U, V), "flatMap must return Result.");

        if (_isOk)
            return fn(_value);

        return Mapped.err(_error);
    }

    /// Maps the success value if present.
    auto map(F)(scope F fn) const
    {
        alias Mapped = typeof(fn(T.init));

        if (_isOk)
            return Result!(Mapped, E).ok(fn(_value));

        return Result!(Mapped, E).err(_error);
    }

    /// Flat-maps the success value if present.
    auto flatMap(F)(scope F fn) const
    {
        alias Mapped = typeof(fn(T.init));
        static assert(is(Mapped == Result!(U, V), U, V), "flatMap must return Result.");

        if (_isOk)
            return fn(_value);

        return Mapped.err(_error);
    }

    /// Returns the success value or throws with a message.
    T expect(string message)
    {
        enforce(_isOk, message);
        return _value;
    }

    /// Returns the success value or throws with a message.
    const(T) expect(string message) const
    {
        enforce(_isOk, message);
        return _value;
    }

    /// Runs one of two callbacks depending on state.
    void match(OnOk, OnErr)(scope OnOk onOk, scope OnErr onErr)
    {
        if (_isOk)
            onOk(_value);
        else
            onErr(_error);
    }

    /// Runs one of two callbacks depending on state.
    void match(OnOk, OnErr)(scope OnOk onOk, scope OnErr onErr) const
    {
        if (_isOk)
            onOk(_value);
        else
            onErr(_error);
    }
}

unittest
{
    auto okValue = Result!(int, string).ok(4);
    int doubler(int x)
    {
        return x * 2;
    }

    assert(okValue.isOk);
    assert(okValue.map(&doubler).expect("map failed") == 8);
}

unittest
{
    auto errValue = Result!(int, string).err("nope");
    assert(errValue.isErr);
    bool sawErr = false;

    void onOk(int _)
    {
    }

    void onErr(string err)
    {
        sawErr = err == "nope";
    }

    errValue.match(&onOk, &onErr);
    assert(sawErr);
}
