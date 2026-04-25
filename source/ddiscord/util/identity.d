/**
 * ddiscord — library identity constants.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.identity;

/// Repository URL used in Discord user-agent strings.
enum DdiscordRepositoryUrl = "https://github.com/soloverdrive/ddiscord";

/// Library version used in Discord user-agent strings.
enum DdiscordVersion = "0.3.2.1";

/// Discord-compliant user-agent used by default in HTTP and REST clients.
enum DdiscordUserAgent = "DiscordBot (" ~ DdiscordRepositoryUrl ~ ", " ~ DdiscordVersion ~ ")";
