# AGENTS.md

This blog ([ashish1099.me](https://ashish1099.me)) is developed with assistance from Claude Code.

## Project structure

- **Static site generator:** Hugo with the [PaperMod](https://github.com/adityatelange/hugo-PaperMod) theme
- **Config:** `hugo.toml` (TOML format)
- **Posts:** `content/posts/` — one Markdown file per post
- **Deployment:** GitHub Pages via GitHub Actions

## Conventions

- Front matter uses YAML (`---` delimiters) with these fields: `title`, `date`, `draft`, `tags`, `author`, `summary`, `showToc`, `TocOpen`
- Author is "Ashish Jaiswal"
- Dates use ISO 8601 format with timezone (e.g., `2025-06-15T10:00:00+02:00`)
- Tags are lowercase, short identifiers (e.g., `["linux", "automation", "ai"]`)
- Code blocks use fenced markdown with language identifiers
- Goldmark renderer with `unsafe: true` is enabled for inline HTML
