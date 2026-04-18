/**
 * ddiscord — presence models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.presence;

/// Activity kind.
enum ActivityType : int
{
    Playing = 0,
    Streaming = 1,
    Listening = 2,
    Watching = 3,
    Custom = 4,
    Competing = 5,
}

/// Presence status.
enum StatusType : string
{
    Online = "online",
    Idle = "idle",
    DoNotDisturb = "dnd",
    Invisible = "invisible",
    Offline = "offline",
}

/// Presence activity model.
struct Activity
{
    ActivityType type;
    string name;
}
