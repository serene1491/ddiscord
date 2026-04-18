/**
 * ddiscord — autocomplete context.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.context.autocomplete;

import ddiscord.models.application_command : AutocompleteChoice;

/// Context passed to autocomplete handlers.
struct AutocompleteContext
{
    string focusedName;
    string focusedValue;
    private AutocompleteChoice[] _choices;

    /// Responds with autocomplete choices.
    void respond(AutocompleteChoice[] choices)
    {
        _choices = choices.dup;
    }

    /// Returns the collected response choices.
    AutocompleteChoice[] choices() const @property
    {
        return _choices.dup;
    }
}
