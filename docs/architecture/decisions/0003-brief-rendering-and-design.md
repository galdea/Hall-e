# ADR 0003: Corporate Brief Rendering and Persistent Project Design

Status: Accepted and implemented locally — user-approved 2026-08-09; historical execution remains gated by ADR 0004
Date: 2026-08-09

## Context

Hall-E needs a compact, repeatable corporate briefing in Markdown and PDF. Project repositories may supply initial visual cues but may later be deleted, so report rendering cannot depend on a live repository or remote asset.

## Decision

Persist canonical `briefing.v1.json`, deterministic Markdown, and a PDF per meeting. Markdown is merged into the Hall-E-managed Obsidian briefing section. PDF is rendered from local HTML/CSS with `WKWebView.createPDF`; no Pandoc or remote renderer.

The renderer protects headline, objectives, individual tasks, and decisions. It targets one page, uses two only when the protected core cannot fit, and never emits a third page. Optional low-priority content is summarized as overflow with a link to the full note.

## Project design profile

Each project receives a small self-contained Hall-E design profile. Initial colors, logo, and typography may be imported from a project repository, but Hall-E copies the validated profile and permitted local assets into the Obsidian project folder:

`Hall-e/Projects/<Project>/Design/briefing-design.json`

The repository is an import source, never a runtime dependency. Deleting it does not affect future reports.

Minimal fields: schema/profile version, accent/background/text colors, local raster logo (PNG/JPEG only), font family/fallbacks, density, margins, section names/order, language, and tone. No SVG, JavaScript, remote CSS/fonts/assets, arbitrary HTML, or paths outside the project Design folder. Render with JavaScript disabled and a file-scoped base URL restricted to that Design folder.

Resolution order: explicit project profile, project frontmatter reference, workspace default, built-in `corporateCloseKnit`. Invalid fields fall back individually. A profile cannot hide objectives, tasks, or decisions.

## Options considered

- Render directly from each project repository: rejected because repositories are temporary sources.
- Remote templates or a headless browser service: rejected because they enlarge the privacy and operational boundary.
- Pandoc or another document toolchain: rejected because `WKWebView.createPDF` is already available in the native app.
- Validated local profile plus built-in fallback: selected for portability and bounded customization.

## Consequences

- PDF page count becomes deterministic and testable.
- Imported design assets remain durable after repository deletion.
- Obsidian remains the portable visible source; an Application Support cache may be rebuilt.
- Report facts are renderer-independent and identical across JSON, Markdown, and PDF.

## Rollback

Disable PDF rendering and retain JSON/Markdown. Remove or replace a project design profile without regenerating transcription or analysis.

## Reconsider when

Reports require email/distribution, richer brand systems, remote assets, accessibility variants, or more than two pages.
