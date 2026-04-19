/**
 * ddiscord — logging primitives.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.logging;

import std.datetime : Clock, SysTime;
import std.stdio : stderr, stdout;

/// Standard library log levels.
enum LogLevel
{
    Error,
    Warning,
    Information,
    Debug,
    Trace,
}

/// Structured log entry.
struct LogRecord
{
    SysTime timestamp;
    LogLevel level;
    string category;
    string message;
}

/// Sink used by the runtime logger.
alias LogSink = void delegate(scope const LogRecord record);

/// Default logger used by the client surface.
final class Logger
{
    private LogLevel _minimumLevel = LogLevel.Information;
    private LogSink _sink;

    this(LogLevel minimumLevel = LogLevel.Information, LogSink sink = null)
    {
        _minimumLevel = minimumLevel;
        if (sink is null)
        {
            _sink = (scope const LogRecord record) {
                defaultConsoleSink(record);
            };
        }
        else
        {
            _sink = sink;
        }
    }

    /// Writes a record when the current level allows it.
    void log(LogLevel level, string category, string message)
    {
        if (!shouldLog(level))
            return;

        LogRecord record;
        record.timestamp = Clock.currTime;
        record.level = level;
        record.category = category;
        record.message = message;
        _sink(record);
    }

    /// Emits an error record.
    void error(string category, string message)
    {
        log(LogLevel.Error, category, message);
    }

    /// Emits a warning record.
    void warning(string category, string message)
    {
        log(LogLevel.Warning, category, message);
    }

    /// Emits an informational record.
    void information(string category, string message)
    {
        log(LogLevel.Information, category, message);
    }

    /// Emits a debug record.
    void debugMessage(string category, string message)
    {
        log(LogLevel.Debug, category, message);
    }

    /// Emits a trace record.
    void trace(string category, string message)
    {
        log(LogLevel.Trace, category, message);
    }

    /// Returns the configured minimum level.
    LogLevel minimumLevel() const @property
    {
        return _minimumLevel;
    }

    /// Updates the minimum level.
    void minimumLevel(LogLevel value) @property
    {
        _minimumLevel = value;
    }

    private bool shouldLog(LogLevel level) const
    {
        return cast(int) level <= cast(int) _minimumLevel;
    }
}

private void defaultConsoleSink(scope const LogRecord record)
{
    auto line = "[" ~ levelLabel(record.level) ~ "][" ~ record.category ~ "] " ~ record.message;
    if (record.level == LogLevel.Error)
        stderr.writeln(line);
    else
        stdout.writeln(line);
}

private string levelLabel(LogLevel level)
{
    final switch (level)
    {
        case LogLevel.Error:
            return "error";
        case LogLevel.Warning:
            return "warning";
        case LogLevel.Information:
            return "info";
        case LogLevel.Debug:
            return "debug";
        case LogLevel.Trace:
            return "trace";
    }
}
