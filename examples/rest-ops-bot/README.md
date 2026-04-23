# rest-ops-bot

`rest-ops-bot` demonstrates newer REST surfaces in `ddiscord`:

- message lifecycle (`edit`, `delete`, `bulkDelete`)
- message utility operations (`crosspost`, `pin`, `unpin`, `pins`)
- reactions (`add`, `removeSelf`)
- guild moderation (`timeoutMember`, `clearMemberTimeout`) with optional audit-log reason
- threads (`createFromMessage`, `join`, `leave`, `archive`)
- webhook execution (`webhooks.execute`)
- command-context message helpers (`ctx.react`, `ctx.pin`, `ctx.crosspost`, `ctx.messageRef`)

## Commands (prefix)

- `!react [emoji]`
- `!unreact [emoji]`
- `!guild-check`
- `!purge2 <messageIdA> <messageIdB>`
- `!crosspost [messageId]`
- `!pin [messageId] [reason]`
- `!unpin <messageId> [reason]`
- `!pins`
- `!timeout <userId> [minutes] [reason]`
- `!untimeout <userId> [reason]`
- `!thread [name]`
- `!thread-join <threadId>`
- `!thread-leave <threadId>`
- `!thread-archive <threadId>`
- `!webhook-send <webhookId> <token> [content]`

Some commands require guild context and proper Discord permissions.
