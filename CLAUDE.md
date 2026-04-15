# Blog

Personal blog at pH14.dev, built with Zola and the Serene theme, deployed on Cloudflare Pages.

## Local development

Run these in separate terminals:

```sh
zola serve --drafts        # live-reloading site at http://127.0.0.1:1111
make watch-all             # re-renders diagrams on save
```

Drop `--drafts` to preview only published posts.

## Post file naming

Post filenames follow `YYYY-MM-slug.md`, e.g. `2026-04-ai-part-1-throwaway.md`. The year-month prefix matches the post's `date` front matter.

## Diagrams (D2)

Source files live in `diagrams/`, rendered SVGs go to `static/img/diagrams/`. Theme, font, and layout are configured in the Makefile.

```sh
make diagrams              # render all
make watch D=<name>        # live preview of one diagram (opens browser)
make watch-all             # re-render all on any .d2 change
make list                  # show diagrams and render status
```

Embed in a post:

```markdown
{{ figure(src="/img/diagrams/<name>.svg", alt="description", width="600") }}
```
