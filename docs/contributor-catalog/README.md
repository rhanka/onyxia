# Onyxia Contributor Catalog Draft

Status: draft, non-executable.

This directory is a GitOps-style intake catalog for Sent-Tech contributor assets. It is not an Onyxia runtime feature yet. It gives each track a stable ID, owner/status fields, dependencies, UAT links, and references to existing Onyxia services or future connectors.

## Files

- `catalog-item.schema.json`: minimal JSON schema for catalog item documents.
- `items/*.json`: draft catalog item records.
- `validate.mjs`: dependency-free validator for the draft item set.

## Current Scope

This catalog intentionally sits above existing Onyxia concepts:

- Onyxia `api.catalogs` remains the Helm service catalog.
- `X-Onyxia` remains the runtime injection mechanism for user/project/S3/Kafka context.
- This catalog records data sources, APIs, MCP actions, workflows, marketplace services, UAT status, and dependencies.

## Validate

```bash
node docs/contributor-catalog/validate.mjs
```

Expected:

```text
validated 9 catalog items
```
