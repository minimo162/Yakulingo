# DESIGN.md — YakuLingo V64

## Product intent

YakuLingo is an Excel-first translation tool that creates translations which fit the existing workbook layout with minimal manual work.

The primary flow is deliberately limited to opening an Excel workbook, translating untranslated cells, correcting only cells that need review, and writing a translated Excel copy. Translation memory, terminology, QC, and layout measurement support that flow without becoming permanent work panes. Word, text, and CSV compatibility are auxiliary capabilities and do not determine the main UI information architecture.

YakuLingo also provides a deliberately lightweight transient text translator for casual translation. It is a separate surface and does not participate in Excel project state, translation memory, terminology, QC, or review workflows. The product relationship is intentionally asymmetric: Excel translation remains the default and primary experience; text translation is a small auxiliary entry point for paste, translate, and copy.

## Architecture

```text
Normal Microsoft Edge tab (no custom EXE or WebView2 runtime)
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

- The start screen has one primary entry: an Excel drop target with an equivalent file-picker button.
- The workspace has one cell list and one selected-cell editor. Its filters are `未訳 / 要確認 / すべて`.
- The primary actions are derived from actual state: translate untranslated cells, review flagged cells, and write Excel.
- Layout preview is closed initially and opens from a selected cell that needs visual confirmation.
- Progress, import, save, and output conditions use labeled status/live regions.
- Warning completion uses a persistent alert, `_INCOMPLETE` name, and visually distinct download button.

## Visual principles

- Quiet, Excel-first start screen and a focused two-pane workspace.
- One indigo primary action; outlined secondary actions.
- The same cell is never shown in multiple permanent lists.
- Candidates, translation memory, terminology, history, preview, and advanced tools appear only on demand.
- Diagnostics and settings never displace the main translation form.
- Security and completeness warnings must remain visually prominent and must not use the normal-success treatment.

## Copilot window and empty-composer behavior

- An empty Copilot composer shows the voice-chat control where the text send button appears after filling. Fresh-chat verification therefore requires an empty ready editor, no responses, and no generation, but never requires the text send button. The diagnostic `composerReady` field means that the editor and either the send or voice-chat control are present; it is not a fresh-chat acceptance gate.
- Send actions accept only a verified `aria-label="送信"` or `aria-label="Send"` control; voice-chat controls remain excluded.
- The main UI opens as a normal tab in the user's existing Edge profile, so YakuLingo does not add another indistinguishable Edge taskbar icon. There is no notification-area resident process and no Windows sign-in auto-start.
- Each YakuLingo tab reports a tab-scoped presence ID. Closing the last YakuLingo tab stops the PowerShell server and the dedicated Copilot profile after a short navigation grace period. The browser asks for confirmation only while translation is active. The user's Edge process and other tabs are never stopped.
- Normal translation keeps the dedicated Copilot profile in the background. A detected login requirement is surfaced in the main UI, where the user can explicitly open that dedicated Copilot window.

## Zero-seed reusable-language contract

The distribution contains no company- or document-specific glossary, terminology, translation memory, corpus, or proper-noun list. This prevents an internal-document convention from silently affecting an external disclosure, and prevents a public-document expression from being presented as an internal standard. Runtime candidates come only from:

- project or personal terminology explicitly registered by the user;
- segments that the user passed through QC and explicitly marked reviewed on the same device; and
- a prior version explicitly supplied for the current project.

Project terminology never leaks into another project. Personal terminology may be reused in later projects. A term record controls a word or short expression; a `cell_exact` record may pretranslate only an entirely matching cell. In-sentence terms are constraints and QA evidence, never blind search-and-replace instructions.

Marking a segment reviewed is the user's intent to add that segment to translation memory. Machine drafts, candidate insertion, and prior-version import do not add translation memory by themselves. Translation-memory and prior-version candidates are never silently injected into the Copilot prompt and never inherit reviewed status after insertion.

An empty termbase or translation memory is a normal first-run state, not an error. The UI explains how each resource grows at the point where its empty candidate list appears. Application updates preserve user terminology, translation memory, legacy personal-glossary migration data, projects, and existing reference traces.

Numeric masking and deterministic notation conversions such as `億円` to `oku` are application rules, not seed terminology. They remain available in an otherwise empty reusable-language state.
