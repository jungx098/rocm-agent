Generate release notes from the following git repository changes.

Format the output as markdown with the following structure:

# Release Title (e.g., "v2.0.0 - Major Performance Update")

## Summary
A brief overview paragraph of the key changes and improvements.

## New Features
- Feature 1
- Feature 2

## Bug Fixes
- Fix 1
- Fix 2

## Improvements
- Improvement 1
- Improvement 2

## Breaking Changes (if any)
- Breaking change 1

## Technical Details (optional)
Additional technical information if relevant.

Rules:
- Include a descriptive release title as H1 (suggest version number if tags are present, or a descriptive name)
- Be concise and user-friendly
- Group related changes together
- Highlight breaking changes prominently
- Use clear, descriptive bullet points
- Focus on user-facing changes, not implementation details
- Output ONLY the release notes in markdown format, nothing else — no explanation, no quotes, no markdown fences

# Context

- Repository: {{REPO_NAME}}
- Branch: {{BRANCH}}
- Source: {{SOURCE_LABEL}}

## Commit Log

{{COMMIT_LOG}}

## Changed Files

{{FILE_LIST}}

## Diff Summary

{{STAT}}

## Full Diff

{{DIFF}}
