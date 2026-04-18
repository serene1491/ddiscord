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
    Guilds = 1u << 0,
    GuildMembers = 1u << 1,
    GuildMessages = 1u << 9,
    GuildMessageReactions = 1u << 10,
    DirectMessages = 1u << 12,
    MessageContent = 1u << 15,
}
