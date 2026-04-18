/**
 * ddiscord — async task helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.tasks;

import core.time : Duration, dur;
import ddiscord.util.errors : DdiscordException, formatError;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import std.datetime : Clock, SysTime;
import std.exception : enforce;
import std.string : startsWith;
import std.conv : to;

/// Lightweight awaitable task wrapper.
struct Task(T)
{
    static if (!is(T == void))
        T value;

    private Nullable!string _errorMessage;

    /// Waits for the task to complete.
    T await()
    {
        if (!_errorMessage.isNull)
            throw new DdiscordException(_errorMessage.get);

        static if (is(T == void))
            return;
        else
            return value;
    }

    /// Returns the task outcome as a result without throwing.
    auto awaitResult()
    {
        static if (is(T == void))
        {
            if (_errorMessage.isNull)
                return Result!(bool, string).ok(true);
            return Result!(bool, string).err(_errorMessage.get);
        }
        else
        {
            if (_errorMessage.isNull)
                return Result!(T, string).ok(value);
            return Result!(T, string).err(_errorMessage.get);
        }
    }

    /// Returns whether the task failed.
    bool failed() const @property
    {
        return !_errorMessage.isNull;
    }

    /// Returns the failure message, if any.
    Nullable!string errorMessage() const @property
    {
        return _errorMessage;
    }

    /// Creates a successful task.
    static if (!is(T == void))
    {
        static Task!T success(T value)
        {
            Task!T task;
            task.value = value;
            return task;
        }
    }
    else
    {
        static Task!T success()
        {
            Task!T task;
            return task;
        }
    }

    /// Creates a failed task.
    static Task!T failure(string message)
    {
        Task!T task;
        task._errorMessage = Nullable!string.of(message);
        return task;
    }
}

/// Lightweight scheduler used by the client surface.
final class TaskScheduler
{
    private struct ScheduledTask
    {
        string label;
        SysTime dueAt;
        bool recurring;
        Duration interval;
        void delegate() callback;
    }

    private ScheduledTask[string] _tasks;
    private string[] _taskErrors;

    /// Registers a delayed task.
    void schedule(string label, Duration delay, void delegate() callback)
    {
        ScheduledTask task;
        task.label = label;
        task.dueAt = Clock.currTime + delay;
        task.callback = callback;
        _tasks[label] = task;
    }

    /// Registers a recurring task.
    void every(string label, Duration interval, void delegate() callback)
    {
        ScheduledTask task;
        task.label = label;
        task.dueAt = Clock.currTime + interval;
        task.recurring = true;
        task.interval = interval;
        task.callback = callback;
        _tasks[label] = task;
    }

    /// Registers a lightweight cron-style task using `@every:<seconds>s`.
    void cron(string label, string expression, void delegate() callback)
    {
        enforce(expression.startsWith("@every:"), "Only @every:<seconds>s cron expressions are supported.");
        auto secondsValue = expression["@every:".length .. $];
        enforce(secondsValue.length > 1 && secondsValue[$ - 1] == 's', "Expected seconds suffix in cron expression.");
        auto seconds = secondsValue[0 .. $ - 1].to!long;
        every(label, dur!"seconds"(seconds), callback);
    }

    /// Cancels a task.
    void cancel(string label)
    {
        _tasks.remove(label);
    }

    /// Returns whether a task is scheduled.
    bool has(string label) const
    {
        return cast(bool) (label in _tasks);
    }

    /// Returns every registered task label.
    string[] labels() const @property
    {
        return _tasks.keys.dup;
    }

    /// Runs all due tasks at the current time.
    size_t runDue()
    {
        return runUntil(Clock.currTime);
    }

    /// Runs all tasks that are due up to a specific time.
    size_t runUntil(SysTime now)
    {
        string[] dueLabels;

        foreach (label, task; _tasks)
        {
            if (task.dueAt <= now)
                dueLabels ~= label;
        }

        size_t executed;
        foreach (label; dueLabels)
        {
            auto taskPtr = label in _tasks;
            if (taskPtr is null)
                continue;

            auto task = *taskPtr;
            if (task.callback !is null)
            {
                try
                {
                    task.callback();
                }
                catch (Throwable error)
                {
                    _taskErrors ~= formatError(
                        "tasks",
                        "A scheduled task raised an exception.",
                        "Task `" ~ label ~ "` failed with: " ~ error.msg,
                        "Inspect the callback implementation; the scheduler kept running."
                    );
                }
            }
            executed++;

            if (task.recurring)
            {
                task.dueAt = now + task.interval;
                _tasks[label] = task;
            }
            else
            {
                _tasks.remove(label);
            }
        }

        return executed;
    }

    /// Returns captured task execution failures.
    string[] taskErrors() const @property
    {
        return _taskErrors.dup;
    }
}

unittest
{
    auto scheduler = new TaskScheduler;
    int calls;

    scheduler.schedule("once", dur!"seconds"(1), { calls++; });
    assert(scheduler.has("once"));
    auto later = Clock.currTime + dur!"seconds"(2);
    assert(scheduler.runUntil(later) == 1);
    assert(calls == 1);
    assert(!scheduler.has("once"));
}

unittest
{
    auto scheduler = new TaskScheduler;
    int calls;

    scheduler.every("heartbeat", dur!"seconds"(5), { calls++; });
    auto later = Clock.currTime + dur!"seconds"(5);
    assert(scheduler.runUntil(later) == 1);
    assert(calls == 1);
    assert(scheduler.has("heartbeat"));
}

unittest
{
    auto scheduler = new TaskScheduler;
    scheduler.schedule("broken", dur!"seconds"(1), { throw new Exception("boom"); });
    auto later = Clock.currTime + dur!"seconds"(2);
    assert(scheduler.runUntil(later) == 1);
    assert(scheduler.taskErrors.length == 1);
}
