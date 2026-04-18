/**
 * ddiscord — attachment models.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.models.attachment;

import ddiscord.util.snowflake : Snowflake;

/// Discord attachment model.
struct Attachment
{
    Snowflake id;
    string filename;
    string url;
}
