Generate a git commit message. Format:

<type>: <short description>

- bullet 1
- bullet 2

Rules:
- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Subject line: capitalize first letter, imperative mood, no period, max 50 characters
- Body: 1-3 short bullet points summarizing key changes, separated from subject by a blank line
- Body lines must not exceed 72 characters. Do NOT wrap lines that already fit. When wrapping is needed, fill each line as close to 72 characters as possible before breaking. Break at a natural clause boundary and indent continuation lines by 2 spaces

CRITICAL OUTPUT RULES:
- Respond with ONLY the raw commit message text — nothing before it, nothing after it
- Do NOT include any preamble like "Here is the commit message" or "Based on the diff"
- Do NOT wrap the message in markdown code fences or quotes
- Your entire response must start with the type prefix (e.g. "feat:") and contain nothing else

# Context

- Source: {{SOURCE_LABEL}}
- Branch: {{BRANCH}}
- Recent commits (for style reference):
{{RECENT_LOG}}{{EXISTING_MSG_SECTION}}

## Changed Files

{{FILE_LIST}}

## Diff Summary

{{STAT}}

## Full Diff

{{DIFF}}
