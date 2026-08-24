# DESIGN.md — YakuLingo V91.62

## Product intent

YakuLingo has one default entry and one clearly separated supporting workflow. The default entry is **text translation**: a lightweight two-pane surface for pasting text, explicitly starting translation, reviewing the result, optionally shortening or rephrasing it, and copying it. **Excel translation** remains one top-level action away and deterministically reuses confirmed bilingual assets before users fill unresolved cells and write a non-destructive workbook copy.

Text translation does not collect display conditions. Font, point size, column width, row count, wrapping, merged-cell state, target length, shortening percentage, and free-form preserved-term fields are outside its responsibility. Result adjustments are explicit one-shot actions based on the current masked translation; the first translation never starts a second Copilot request automatically. Numbers and units remain protected by the existing masking and preservation contracts, while company names, person names, and the text itself remain covered by the disclosure shown in the UI.

Excel may hand the text surface only the source text, cell identity, return URL, and the index needed to return an adopted translation. Layout metadata is not copied into the text UI or prompt. Saved Excel project URLs remain rooted at `/cat`.

Bilingual asset generation and reuse are separate trust boundaries. Copilot may use document context, neighboring content, headings, numeric/unit evidence, and 1:1, 1:N, or N:1 relations to propose alignments. Deterministic validation and explicit confirmation create translation-memory records. Reapplication never uses AI similarity to write a cell; only confirmed, uniquely resolved records may be applied.

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

- `/` and `/quick` open text translation; `/cat` opens Excel translation and preserves project/import query parameters.
- The header exposes exactly two product modes: `テキスト翻訳` and `Excel翻訳`. The current mode uses `aria-current` plus visible background, border, and text changes.
- Text translation keeps language selection, source, target, copy, explicit translate, cancel, retry, and post-result rewrite actions in one focused surface.
- Translation starts only from the button or `Ctrl+Enter`; no paste/input event and no completed first result triggers another Copilot request.
- At 900px and below the source and target panes stack in source-to-target order. Keyboard focus has a visible outline, and disabled controls retain readable text.
- The Excel workspace retains its cell list, selected-cell editor, status/live regions, output preflight, and non-destructive write workflow.

## Visual principles

- Quiet, text-first start screen with large adjacent source and target panes; a focused Excel workspace remains separate.
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


## Bilingual asset lifecycle

1. Import the official Japanese and English versions from the Excel start screen.
2. Build structural candidates, then use Copilot for contextual alignment.
3. Retain IDs, confidence, rationale, and relation cardinality; reject numeric, unit, proper-noun, duplicate-ID, empty/formula-cell, and existing-memory conflicts deterministically.
4. Confirm only valid pairs into translation memory. Terminology remains separate.
5. Apply unique exact or safe-normalized matches to a new workbook; leave missing and ambiguous text unchanged.
