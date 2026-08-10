# DESIGN.md — YakuLingo V64

## Product intent

YakuLingo is a local translation tool with two experiences: Quick Translation for transient understanding and drafting, and Document Translation for source/target review, terminology control, translation-memory reuse, QC, and DRAFT output. Quick Translation never reads or writes reusable language assets. Document Translation exposes the provenance of every reusable candidate and requires human confirmation before a segment becomes translation memory.

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

## Zero-seed reusable-language contract

The distribution contains no company- or document-specific glossary, terminology, translation memory, corpus, or proper-noun list. This prevents an internal-document convention from silently affecting an external disclosure, and prevents a public-document expression from being presented as an internal standard. Runtime candidates come only from:

- project or personal terminology explicitly registered by the user;
- segments that the user passed through QC and explicitly marked reviewed on the same device; and
- a prior version explicitly supplied for the current project.

Project terminology never leaks into another project. Personal terminology may be reused in later projects. A term record controls a word or short expression; a `cell_exact` record may pretranslate only an entirely matching cell. In-sentence terms are constraints and QA evidence, never blind search-and-replace instructions.

Marking a segment reviewed is the user's intent to add that segment to translation memory. Machine drafts, candidate insertion, and prior-version import do not add translation memory by themselves. Translation-memory and prior-version candidates are never silently injected into the Copilot prompt and never inherit reviewed status after insertion.

An empty termbase or translation memory is a normal first-run state, not an error. The UI explains how each resource grows at the point where its empty candidate list appears. Application updates preserve user terminology, translation memory, legacy personal-glossary migration data, projects, and existing reference traces.

Numeric masking and deterministic notation conversions such as `億円` to `oku` are application rules, not seed terminology. They remain available in an otherwise empty reusable-language state.
