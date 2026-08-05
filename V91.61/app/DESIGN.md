# DESIGN.md — YakuLingo V64

## Product intent

YakuLingo is a single-purpose local translation tool for ECM materials. The default screen keeps text/file input, one primary action, job progress, and the latest result visible. History, glossary, settings, and data deletion remain in collapsed disclosure panels.

## Architecture

```text
Browser UI
  -> loopback HTTP server (session/Host/origin boundary)
      -> text translation runspace -> dedicated Edge profile/CDP -> M365 Copilot
      -> file worker process -> dedicated Excel COM instance
           -> job temp output -> integrity validation -> atomic publish
```

- The loopback server owns the session token, single-instance mutex, upload handles, and job registry.
- Text jobs run asynchronously. File jobs cross an OS process boundary so a blocked Excel COM call cannot block the HTTP listener.
- File cancellation returns while a short-lived stop helper waits for cooperative exit, then verifies PID/start-time identities before terminating only the dedicated worker and Excel process.
- `GET /api/jobs/{jobId}` is the canonical job status/result contract. Cancel, download, and open-output also require the explicit job ID.
- Runtime JSON files use temporary-file replacement. File worker state is a shared whitelist contract in `src/Runtime.ps1`.
- Copilot responses are untrusted until labels, IDs, order, expected language, and the per-request final marker pass validation.

## Output integrity

No completion path writes directly to a final output filename. The file worker writes inside `.yakulingo-job-<jobId>`, closes the workbook, validates it, and moves it to the output directory. Failure and cancellation remove the temporary directory. Incomplete-but-useful results are published only with `_INCOMPLETE` and `completed_with_warnings`.

## Privacy

Normal operation never persists source text, translated text, or full prompts. Full text is retained only in the in-process ten-item history and disappears when the server stops or the user clears history. Disk history stores metadata only. Logs use three privacy levels: `minimal` redacts diagnostic and content fields, `standard` (default) keeps exception diagnostics while redacting content fields, and `full` records unredacted diagnostic content as an explicit, time-limited opt-in. Any future dynamic business value embedded in an exception message must be enclosed in single quotes so standard-mode masking removes it.

## Interaction and accessibility

- The text/file switch uses `tablist`, `tab`, and `tabpanel` roles.
- Left/Right and Home/End move and activate tabs; selected tabs own `tabindex=0`.
- Progress uses a labeled progressbar and live regions.
- File picker and direct path are mutually exclusive.
- A file-info response produces selectable sheet chips; the actual request sends a JSON array, so characters such as `|` remain part of the sheet name.
- Warning completion uses a persistent alert, `_INCOMPLETE` name, and visually distinct download button.

## Visual principles

- Quiet, text-first, spacious single-column layout.
- One indigo primary action; outlined secondary actions.
- Results use a white surface with subtle borders; metadata uses small pills.
- Diagnostics and settings never displace the main translation form.
- Security and completeness warnings must remain visually prominent and must not use the normal-success treatment.

## Copilot window and empty-composer behavior

- An empty Copilot composer shows the voice-chat control where the text send button appears after filling. Fresh-chat verification therefore requires an empty ready editor, no responses, and no generation, but never requires the text send button. The diagnostic `composerReady` field means that the editor and either the send or voice-chat control are present; it is not a fresh-chat acceptance gate.
- Send actions accept only a verified `aria-label="送信"` or `aria-label="Send"` control; voice-chat controls remain excluded.
- YakuLingo does not move, foreground, maximize, minimize, or resize Edge during translation. The sole exception is a one-time normalization immediately after YakuLingo newly starts its dedicated Edge profile. The default is 1280x900, `edge_window_size=none` disables it, and an already-running Edge window is never changed.

## V91.56 FULL/BRIEF terminology contract

FULL and BRIEF share one semantic rendering, but differ in compression. For ordinary words and internal shorthand, glossary rows place the spelled-out FULL candidate first and the approved BRIEF abbreviation later. Established financial acronyms, formal metric names, proper nouns, and source-defined abbreviations remain protected. Candidate order alone never makes an ordinary abbreviation valid in FULL.


## V91.57 promotion-cost terminology contract

Promotion costs are mode-specific: FULL uses `sales promotion costs` and `fixed sales promotion costs`; BRIEF and file-label exact matches use `Promo. Costs`, `Fixed Promo. Costs`, and `Subs. Fixed Promo. Costs`. `MKT` remains available only where it genuinely means marketing, not as an abbreviation for promotion costs. Exact table-label matches run before shorter glossary composition.
