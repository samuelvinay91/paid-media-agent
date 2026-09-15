# Changelog

## Unreleased

### Added

- Paid-media analysis through a shared Deep Agents assembly, with a credential-free fixture demo.
- A local setup console and CLI for models, account connections, and deployment.
- Pipeboard tool discovery and read-only direct adapters behind a host-controlled account catalog.
- Deterministic period comparisons and HTML/PDF reports with source reconciliation.
- Typed proposals, verified human approvals, one mutation attempt, and bounded readback receipts.
- Managed Deep Agents deployment with Slack and schedule declarations, plus a self-hosted API,
  Slack adapter, and optional Postgres persistence.
- Runtime skills and editable business context shared across both deployment paths.
- Vertex AI model providers (`google_vertexai`, `google_anthropic_vertex`) through the `vertex`
  extra, authenticated with Application Default Credentials.
- Terraform and scripts for a single Compute Engine VM deployment in `deploy/gcp/`.

### Fixed

- Gemini on Vertex AI tool selection: the selector schema is rewritten to a string enum in
  JSON mode, since the Vertex client drops `const` and rejects `anyOf`.
- Live Pipeboard catalogs: read tools and discovery cover only platforms with a mapped account,
  the selector legend carries one-line summaries, and Meta `get_insights` is admitted by binding
  the mapped ad account to `object_id` (act_-prefixed) with the allowlist `account_id` injected
  host-side.
- The model's filesystem view is limited to `/skills` and `/workspace` in every runtime, matching
  the managed sandbox; application source and configuration are no longer readable.
- Self-hosted Slack replies: the SDK's asynchronous `chat_stream` is awaited before text and tool
  progress are appended, so mentions and direct messages get a streamed answer instead of a
  silent failure.

Live provider writes remain disabled by default and require the documented release gates.

### Changed

- Clarify the README's capabilities, setup, deployment, and company customization guidance.
- Use the LangChain company logo in the README, with light and dark variants.
