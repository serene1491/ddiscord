/**
 * ddiscord — registration filter helpers for client auto-registration.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_filters;

import ddiscord.client_support.types : CommandRegistrationFilter, RegistrationCandidate;
import std.algorithm : canFind;

bool matchesRegistrationFilter(
    CommandRegistrationFilter filter,
    RegistrationCandidate candidate
)
{
    if (candidate.freeFunction && !filter.includeFreeFunctions)
        return false;
    if (candidate.typeSymbol && !filter.includeTypes)
        return false;
    if (candidate.event && !filter.includeEvents)
        return false;
    if (candidate.plugin && !filter.includePlugins)
        return false;
    if (candidate.task && !filter.includeTasks)
        return false;
    if (!matchesFilterTokens(candidate.moduleName, filter.includeModules))
        return false;
    if (matchesAnyToken(candidate.moduleName, filter.excludeModules))
        return false;
    if (!matchesFilterTokens(candidate.ownerName, filter.includeOwners))
        return false;
    if (matchesAnyToken(candidate.ownerName, filter.excludeOwners))
        return false;
    if (!(candidate.typeSymbol && candidate.commandName.length == 0))
    {
        auto nameValue = candidate.commandName.length == 0 ? candidate.symbolName : candidate.commandName;
        if (!matchesNameFilterTokens(nameValue, filter.includeNames))
            return false;
        if (matchesAnyNameToken(nameValue, filter.excludeNames))
            return false;
    }
    if (!matchesFilterTokens(candidate.category, filter.includeCategories))
        return false;
    if (matchesAnyToken(candidate.category, filter.excludeCategories))
        return false;
    return true;
}

private bool matchesFilterTokens(string value, string[] includes)
{
    if (includes.length == 0)
        return true;
    return matchesAnyToken(value, includes);
}

private bool matchesNameFilterTokens(string value, string[] includes)
{
    if (includes.length == 0)
        return true;
    return matchesAnyNameToken(value, includes);
}

private bool matchesAnyToken(string value, string[] tokens)
{
    foreach (token; tokens)
    {
        if (token.length == 0)
            continue;
        if (value == token || value.canFind(token))
            return true;
    }

    return false;
}

private bool matchesAnyNameToken(string value, string[] tokens)
{
    foreach (token; tokens)
    {
        if (token.length == 0)
            continue;
        if (value == token)
            return true;
    }

    return false;
}

unittest
{
    RegistrationCandidate candidate;
    candidate.moduleName = "example.commands";
    candidate.ownerName = "AdminGroup";
    candidate.symbolName = "ping";
    candidate.commandName = "ping";
    candidate.category = "Utility";
    candidate.freeFunction = true;
    candidate.command = true;

    CommandRegistrationFilter filter = CommandRegistrationFilter
        .modules("example")
        .exceptNames("debug")
        .categories("Utility");

    assert(matchesRegistrationFilter(filter, candidate));
}

unittest
{
    RegistrationCandidate candidate;
    candidate.moduleName = "example.tasks";
    candidate.ownerName = "BackgroundTasks";
    candidate.symbolName = "heartbeat";
    candidate.commandName = "heartbeat";
    candidate.typeSymbol = true;
    candidate.task = true;

    auto denied = CommandRegistrationFilter.modules("example").withoutTasks();
    assert(!matchesRegistrationFilter(denied, candidate));

    auto allowed = CommandRegistrationFilter.modules("example");
    assert(matchesRegistrationFilter(allowed, candidate));
}
