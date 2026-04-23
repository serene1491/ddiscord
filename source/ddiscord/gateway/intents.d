/**
 * ddiscord — gateway intents.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.gateway.intents;

/// Discord gateway intent flags.
enum GatewayIntent : uint
{
    None = 0u,
    Guilds = 1u << 0,
    GuildMembers = 1u << 1,
    GuildMessages = 1u << 9,
    GuildMessageReactions = 1u << 10,
    DirectMessages = 1u << 12,
    MessageContent = 1u << 15,

    /// Ready for most prefix/slash command bots in guild text channels.
    GuildTextCommands = Guilds | GuildMessages | MessageContent,

    /// Guild text commands plus reactions/events commonly used by moderation flows.
    GuildTextCommandsWithReactions = GuildTextCommands | GuildMessageReactions,

    /// DM-only command flows that still need message content.
    DirectTextCommands = DirectMessages | MessageContent,

    /// Practical default for hybrid bots that support guild + DM command usage.
    DefaultCommandBot = GuildTextCommands | DirectMessages,

    /// All currently available non-privileged intents in this surface.
    NonPrivileged = Guilds | GuildMessages | GuildMessageReactions | DirectMessages,
}

unittest
{
    assert((cast(uint) GatewayIntent.GuildTextCommands) ==
        (cast(uint) (GatewayIntent.Guilds | GatewayIntent.GuildMessages | GatewayIntent.MessageContent)));
    assert((cast(uint) GatewayIntent.DefaultCommandBot) &
        (cast(uint) GatewayIntent.DirectMessages));
}
