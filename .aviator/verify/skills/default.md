---
description: How to drive the MicroBin preview app — what it is, the routes and main flows (no login needed), and what can't be exercised in a preview.
---

# Driving the MicroBin preview

MicroBin is a self-hosted pastebin, file host and URL shortener. The preview
serves the whole web UI at the preview URL. **There is no login gate on the
main flows** — the create form, the paste list and every paste view are open to
anyone with the URL. Only `/admin` asks for credentials.

## The main flow: create a paste

The landing page (`/`) *is* the create form. It has:

- a **Content** textarea (the main input)
- an **attach file** control (multi-file)
- selects for **Expiration**, **Burn After**, **Syntax** highlighting, and
  **Privacy**
- a **Password** field, used by the protected/encrypted privacy levels
- a **Save** submit button

Submitting posts to `/upload` and lands on the new paste's page. Paste IDs are
animal-word slugs, not numbers (`/p/<some-animal-words>`), unless the instance
was started with hash IDs.

Privacy levels, all available on preview defaults:

| Level | Behaviour |
| --- | --- |
| Public | listed on `/list`, no password |
| Unlisted | reachable by URL, hidden from `/list` |
| Read-only | password required to edit or remove |
| Private | server-side encrypted, password to view |
| Secret | client-side encrypted in the browser, password to view |

## Routes worth knowing

- `/` — create form. `/list` — all listed pastes. `/guide` — the built-in usage
  and API guide, and the target of every `?` link on the form.
- `/p/{id}` and `/upload/{id}` — view a paste. `/raw/{id}` — raw text.
- `/url/{id}` and `/u/{id}` — the URL-shortener redirect. Paste a bare URL as
  content and MicroBin hands back a short link that 302s to it.
- `/edit/{id}` — edit an existing paste (editing is on by default).
  `/remove/{id}` — delete it.
- `/file/{id}` — download an attached file. `/archive/{id}` — the paste plus
  its files as an archive.
- `/qr/{id}` — QR code for a paste. The route always exists, but the QR button
  is hidden in the UI unless the instance was started with QR enabled, so
  navigate to it directly rather than hunting for a button.
- `/auth/{id}`, `/auth_raw/{id}`, `/auth_file/{id}`,
  `/auth_edit_private/{id}`, `/auth_remove_private/{id}` — the password prompts
  you get redirected to for a protected or encrypted paste.
- `/admin` — admin panel (bulk paste management). It redirects to
  `/auth_admin`; the preview runs on the defaults, username `admin`, password
  `m1cr0b1n`. These are the upstream defaults baked into the binary, not
  secrets, so they can be typed literally.

Anything not matched renders the 404 page.

## What is NOT exercised in a preview

- **Nothing here is hot-reloadable.** The askama templates and the static CSS
  and JS are compiled *into* the binary, so a template or asset edit is only
  visible after the preview rebuilds and restarts — never conclude a template
  change didn't work by refreshing the page.
- **No outbound network.** Telemetry and the "new version available" check on
  the admin page are both disabled in the preview, so don't try to verify
  update banners.
- **Data does not reset between runs.** The paste directory is preserved across
  preview boots, so `/list` may already hold pastes from earlier runs. Verify
  against a paste you just created, not against the list being empty.
- Long expiry and garbage-collection behaviour, and "burn after N reads" past
  the first read or two, are hard to observe in a short session — prefer the
  immediate signals (the paste renders, the redirect fires, the password gate
  appears).
