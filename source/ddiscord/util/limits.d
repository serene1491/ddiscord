/**
 * ddiscord — Discord API limits and named constants.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.util.limits;

/// Discord REST API base URL.
enum DiscordApiBase = "https://discord.com/api/v10";

/// Discord CDN base URL.
enum DiscordCdnBase = "https://cdn.discordapp.com";

/// Maximum message content length.
enum DiscordMaxMessageLength = 2_000;

/// Maximum embeds per message.
enum DiscordMaxEmbedsPerMessage = 10;

/// Maximum embed fields.
enum DiscordMaxEmbedFields = 25;

/// Maximum embed title length.
enum DiscordMaxEmbedTitleLength = 256;

/// Maximum embed description length.
enum DiscordMaxEmbedDescriptionLength = 4_096;

/// Maximum autocomplete choice count.
enum DiscordMaxAutocompleteChoices = 25;

/// Discord global bot request limit per second.
enum DiscordGlobalRestRequestsPerSecond = 50;

/// Discord gateway version.
enum DiscordGatewayVersion = 10;
