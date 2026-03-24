Continue the most recent interrupted task from the current conversation and workspace state.

Instructions:
1. Infer the latest unfinished user request, active plan step, or interrupted action from the visible context.
2. Resume from the last meaningful checkpoint instead of restarting work that is already done.
3. If the interruption looks transient, such as a network, sandbox, or timeout failure, retry the blocked next step when appropriate.
4. Preserve the existing scope, constraints, and prior decisions unless the user explicitly changes them.
5. If the prior objective is ambiguous or there is no clear unfinished task, say so briefly and ask for the minimal clarification needed.
6. Keep the continuation focused and practical, with a short progress update before any tool calls.

Return:
- Either continue the task directly, or briefly explain why it cannot be resumed yet and what is needed.
