/**
 * ddiscord — task UDA and scheduling metadata types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.commands.task_types;

import core.time : Duration, dur;

/// Task scheduling mode for `@Task`.
enum TaskMode
{
    Every,
    Delay,
    Cron,
}

/// Marks a method/function as a scheduled task entrypoint.
struct Task
{
    string label;
    TaskMode mode = TaskMode.Every;
    Duration interval = Duration.zero;
    string expression;
    bool runOnRegister;
    ulong count;
    bool reconnect = true;

    this(
        Duration interval,
        string label = "",
        TaskMode mode = TaskMode.Every,
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        this.label = label;
        this.mode = mode;
        this.interval = interval;
        this.runOnRegister = runOnRegister;
        this.count = count;
        this.reconnect = reconnect;
    }

    this(
        string expression,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        this.label = label;
        this.mode = TaskMode.Cron;
        this.expression = expression;
        this.runOnRegister = runOnRegister;
        this.count = count;
        this.reconnect = reconnect;
    }

    /// Task loop constructor (`seconds` + `minutes` + `hours`).
    static Task loop(
        double seconds = 0,
        double minutes = 0,
        double hours = 0,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        auto totalSeconds = seconds + (minutes * 60.0) + (hours * 3600.0);
        auto intervalMs = cast(long) (totalSeconds * 1000.0);

        Task task;
        task.label = label;
        task.mode = TaskMode.Every;
        task.interval = intervalMs <= 0 ? Duration.zero : dur!"msecs"(intervalMs);
        task.runOnRegister = runOnRegister;
        task.count = count;
        task.reconnect = reconnect;
        return task;
    }

    /// Explicit recurring-task constructor.
    static Task every(
        Duration interval,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        return Task(interval, label, TaskMode.Every, runOnRegister, count, reconnect);
    }

    /// Explicit one-shot delay-task constructor.
    static Task delay(
        Duration interval,
        string label = "",
        bool runOnRegister = false,
        bool reconnect = true
    )
    {
        return Task(interval, label, TaskMode.Delay, runOnRegister, 1, reconnect);
    }

    /// Explicit cron-task constructor.
    static Task cron(
        string expression,
        string label = "",
        bool runOnRegister = false,
        ulong count = 0,
        bool reconnect = true
    )
    {
        return Task(expression, label, runOnRegister, count, reconnect);
    }
}

unittest
{
    auto task = Task.loop(seconds: 1.5, minutes: 1, count: 3, label: "loop");
    assert(task.mode == TaskMode.Every);
    assert(task.interval > Duration.zero);
    assert(task.count == 3);
    assert(task.label == "loop");

    auto delayed = Task.delay(dur!"seconds"(2), "once");
    assert(delayed.mode == TaskMode.Delay);
    assert(delayed.count == 1);

    auto cron = Task.cron("@every:5s", "cron");
    assert(cron.mode == TaskMode.Cron);
    assert(cron.expression == "@every:5s");
}
