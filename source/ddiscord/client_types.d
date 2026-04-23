/**
 * ddiscord — client support types.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.client_types;

import ddiscord.commands : CommandDescriptor;
import ddiscord.context.command : CommandContext;
import ddiscord.models.message : MessageCreate;

/// Runtime filter used by automatic module-level registration helpers.
struct CommandRegistrationFilter
{
    string[] includeModules;
    string[] excludeModules;
    string[] includeOwners;
    string[] excludeOwners;
    string[] includeNames;
    string[] excludeNames;
    string[] includeCategories;
    string[] excludeCategories;
    bool includeFreeFunctions = true;
    bool includeTypes = true;
    bool includeEvents = true;
    bool includePlugins = true;

    static CommandRegistrationFilter modules(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeModules = values.dup;
        return filter;
    }

    static CommandRegistrationFilter owners(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeOwners = values.dup;
        return filter;
    }

    static CommandRegistrationFilter names(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeNames = values.dup;
        return filter;
    }

    static CommandRegistrationFilter categories(string[] values...)
    {
        CommandRegistrationFilter filter;
        filter.includeCategories = values.dup;
        return filter;
    }

    CommandRegistrationFilter exceptModules(string[] values...)
    {
        excludeModules ~= values;
        return this;
    }

    CommandRegistrationFilter exceptOwners(string[] values...)
    {
        excludeOwners ~= values;
        return this;
    }

    CommandRegistrationFilter exceptNames(string[] values...)
    {
        excludeNames ~= values;
        return this;
    }

    CommandRegistrationFilter exceptCategories(string[] values...)
    {
        excludeCategories ~= values;
        return this;
    }

    CommandRegistrationFilter freeFunctionsOnly()
    {
        includeTypes = false;
        return this;
    }

    CommandRegistrationFilter typesOnly()
    {
        includeFreeFunctions = false;
        return this;
    }

    CommandRegistrationFilter withoutEvents()
    {
        includeEvents = false;
        return this;
    }

    CommandRegistrationFilter withoutPlugins()
    {
        includePlugins = false;
        return this;
    }
}

/// User-facing classification for surfaced command failures.
enum CommandErrorKind
{
    UnknownCommand,
    MissingCommandName,
    MissingArgument,
    InvalidArgument,
    TooManyArguments,
    PolicyDenied,
    HandlerFailure,
    Unknown,
}

/// Rich error context exposed to the customizable error behavior.
struct CommandErrorContext
{
    CommandErrorKind kind = CommandErrorKind.Unknown;
    string route;
    string commandName;
    string error;
    CommandContext command;
}

/// User-facing help entry prepared from a command descriptor.
struct CommandHelpEntry
{
    string name;
    string description;
    string usage;
    string routes;
    string category;
    string sourceModule;
    string owner;
    string policies;
    CommandDescriptor descriptor;
}

/// Prepared help page delivered to the help renderer.
struct CommandHelpPage
{
    string commandName;
    string query;
    size_t page = 1;
    size_t pageSize;
    size_t totalEntries;
    size_t totalPages = 1;
    CommandHelpEntry[] entries;
    bool hasPrevious;
    bool hasNext;
    string previousCustomId;
    string nextCustomId;
}

/// Configures the built-in help command and its rendering pipeline.
final class CommandHelpBehavior
{
    bool enabled = true;
    string commandName = "help";
    string description = "Show registered commands";
    size_t pageSize = 6;
    bool showBuiltinCommands;
    bool useComponentsV2 = true;
    bool delegate(CommandDescriptor) includeCommand;
    CommandHelpEntry delegate(CommandDescriptor, string) buildEntry;
    MessageCreate delegate(CommandHelpPage) renderPage;
}

/// Configures how the client surfaces command failures back to Discord users.
final class CommandErrorBehavior
{
    bool enabled = true;
    bool surfaceUnknownCommand = true;
    bool surfaceMissingCommandName;
    bool surfaceArgumentErrors = true;
    bool surfacePolicyErrors;
    bool surfaceHandlerFailures = true;
    bool surfaceOtherErrors = true;
    bool delegate(CommandErrorContext) shouldSurface;
    MessageCreate delegate(CommandErrorContext) render;
}

struct RegistrationCandidate
{
    string moduleName;
    string ownerName;
    string symbolName;
    string commandName;
    string category;
    bool freeFunction;
    bool typeSymbol;
    bool command;
    bool event;
    bool plugin;
}

struct HelpRequest
{
    string query;
    size_t page = 1;
}
