---
name: confluence-retrieval
description: >-
  Retrieve and summarize Confluence wiki pages using the REST API with
  authentication. Use when the user shares a Confluence/Atlassian wiki URL,
  asks to fetch a Confluence page, or wants to summarize wiki content.
---

# Confluence Page Retrieval

Fetch Confluence page content via REST API and present it in readable form.

## Prerequisites

Two environment variables must be set:
- `CONF_EMAIL` — Atlassian account email
- `CONF_API_TOKEN` — Atlassian API token (generate at https://id.atlassian.com/manage-profile/security/api-tokens)

## Instructions

### Step 1: Extract the Page ID from the URL

Confluence URLs contain the page ID in the path. Examples:

| URL Pattern | Page ID |
|-------------|---------|
| `https://{site}/wiki/spaces/{SPACE}/pages/{ID}/{title}` | `{ID}` |
| `https://{site}/wiki/spaces/{SPACE}/pages/{ID}` | `{ID}` |

Extract the numeric page ID and the base site URL (e.g., `https://amd.atlassian.net`).

### Step 2: Fetch Page Content via REST API

Use `curl.exe` with PowerShell-compatible syntax. The key is using `body.storage` expansion to get the raw page content:

```powershell
curl.exe -s -u "${env:CONF_EMAIL}:${env:CONF_API_TOKEN}" "https://{site}/wiki/rest/api/content/{PAGE_ID}?expand=body.storage,version,title" -o "$env:TEMP\confluence_page.json"
```

**Important**: Use `curl.exe` (not `curl`) to avoid the PowerShell `Invoke-WebRequest` alias, and use `${env:VAR}` syntax for environment variables (not `$VAR`).

### Step 3: Read and Parse the JSON

Read the saved JSON file. The page content is in the `body.storage.value` field as Confluence storage-format HTML.

Key JSON fields:
- `title` — Page title
- `body.storage.value` — Full page content (HTML)
- `version.by.displayName` — Last editor
- `version.when` — Last edit timestamp
- `version.number` — Version number

### Step 4: Extract Readable Text

The `body.storage.value` contains Confluence storage-format HTML. To interpret it:

- **Headings**: `<h2>`, `<h3>`, etc.
- **Code blocks**: `<ac:structured-macro ac:name="code">` with content in `<ac:plain-text-body><![CDATA[...]]></ac:plain-text-body>`
- **Tables**: Standard `<table>`, `<tr>`, `<th>`, `<td>` elements
- **Lists**: Standard `<ul>`, `<ol>`, `<li>` elements
- **Block quotes**: `<blockquote>` elements
- **Inline code**: `<code>` elements
- **Links**: `<a href="...">` elements

Parse the HTML mentally and present the content in clean markdown to the user.

### Step 5: Present the Content

Summarize or display the content based on what the user asked for:
- If they asked to "summarize," provide a structured summary
- If they asked to "show" a specific section, display that section verbatim (converted to markdown)
- If they asked a question about the page, answer from the content

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `Variable reference is not valid` | Using `$VAR:$VAR` in PowerShell | Use `"${env:CONF_EMAIL}:${env:CONF_API_TOKEN}"` |
| 401 Unauthorized | Bad credentials | Verify `CONF_EMAIL` and `CONF_API_TOKEN` are set |
| Empty body | Wrong expand parameter | Ensure `?expand=body.storage` is in the URL |
| HTML boilerplate instead of content | Used page URL directly instead of REST API | Use `/wiki/rest/api/content/{ID}?expand=body.storage` |
| Timeout | Page requires VPN or is very large | Check network connectivity |

## Fetching Child Pages

If the page has child pages, check with:

```powershell
curl.exe -s -u "${env:CONF_EMAIL}:${env:CONF_API_TOKEN}" "https://{site}/wiki/rest/api/content/{PAGE_ID}/child/page" -o "$env:TEMP\confluence_children.json"
```
