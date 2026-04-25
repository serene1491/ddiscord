/**
 * ddiscord — command install/context metadata helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.commands.metadata;

import ddiscord.command_types : CommandPolicyDescriptor;
import ddiscord.models.application_command : ApplicationIntegrationType, InteractionContextType;
import std.algorithm : canFind;

void appendIntegrationTypes(
    ref ApplicationIntegrationType[] destination,
    scope const(ApplicationIntegrationType)[] values
)
{
    foreach (value; values)
    {
        if (!destination.canFind(value))
            destination ~= value;
    }
}

ApplicationIntegrationType[] normalizedIntegrationTypes(
    scope const(ApplicationIntegrationType)[] values
)
{
    ApplicationIntegrationType[] normalized;
    appendIntegrationTypes(normalized, values);
    return normalized;
}

void appendInteractionContexts(
    ref InteractionContextType[] destination,
    scope const(InteractionContextType)[] values
)
{
    foreach (value; values)
    {
        if (!destination.canFind(value))
            destination ~= value;
    }
}

InteractionContextType[] normalizedInteractionContexts(
    scope const(InteractionContextType)[] values
)
{
    InteractionContextType[] normalized;
    appendInteractionContexts(normalized, values);
    return normalized;
}

InteractionContextType[] projectedContextsFromPolicy(CommandPolicyDescriptor policy)
{
    if (policy.guildOnly)
        return [InteractionContextType.Guild];

    if (policy.directMessageOnly)
        return [InteractionContextType.BotDM, InteractionContextType.PrivateChannel];

    return null;
}
