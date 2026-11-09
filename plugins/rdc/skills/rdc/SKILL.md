---
name: rdc
description: Control another computer through RDC. Use when the user wants something done on a different computer (their PC, Mac, a test machine) and RDC is running there — connect with the link from the RDC window and work from screenshots with the rdc MCP tools.
---

# Working on another computer through RDC

RDC shows a 9-digit code and a link (`http://<ip>:7700/#<code>`) in its window on the computer to control. The person there copies the link with **Copy link** and gives it to you.

## Workflow

1. `connect` with the link (or `address` + `code`). You get a screenshot and the computer becomes the current device. Up to 4 computers at once; name them with `name` and pick one with `device` in later calls.
2. Read the screenshot. Every coordinate you pass is a pixel of the **latest full screenshot** (its size is in the text next to the picture).
3. Act: `click`, `type`, `key`, `scroll`, `drag`, `move`. Each action waits for the screen to settle and returns a fresh screenshot — look at it before the next step.
4. Small text: `screenshot` with `region` enlarges a part of the screen. Coordinates still refer to the full screenshot.
5. Done: `disconnect`.

## Tips

- Click a field before `type`. `type` sends real Unicode text, so any language and symbols work; set `enter: true` to submit.
- `key` takes names and shortcuts separated by spaces: `enter`, `ctrl+s`, `cmd+space`, `alt+tab`, `down down enter`, `shift+tab`. On a Mac use `cmd`; on Windows use `ctrl` and `win`.
- `scroll` takes a direction and an amount in wheel notches (3 ≈ a third of a screen).
- A page or app that is still loading: `wait` (seconds), then look again.
- Confirm with the user before irreversible actions: deleting, sending, paying, closing unsaved work.

## When something goes wrong

- *Wrong code* / *refused*: the code changes when the person presses **New code**. Ask for a fresh link.
- *Nothing answers*: RDC is not running there, or this machine cannot reach it (different network and no tunnel).
- *No picture*: on a Mac, RDC needs the **Screen Recording** permission (System Settings → Privacy & Security); the person grants it and restarts RDC.
- *The connection ended*: the person pressed **Stop AI agent** in the RDC window or in their browser, or closed RDC. Ask them before connecting again.
