# Recording format

Macros are stored as UTF-8 JSON, one macro per file, named `<uuid>.macro.json`. You can open them in any text editor. Files exported from the app use the same format, so you can copy a file to another Mac and use **Import**.

The current format version is **1**.

## Versioning

- Every file has an integer `formatVersion`.
- A file with a version this app does not know about is rejected with a clear message rather than guessed at.
  - A **newer** version asks you to update the app.
  - A **missing** or non-integer version is rejected as "not a recording".
- When a future version changes the format, the app migrates older files while loading. Version 1 has nothing to migrate yet; the hook exists in `RecordingCodec`.
- Unknown extra keys are ignored, and missing optional keys use defaults, so small additive changes do not break older files.

## Safety limits

Files are fully validated before they can be played. A file is rejected if:

- it is larger than 50 MB, is not valid JSON, or has no `formatVersion`;
- it has more than 500,000 actions;
- any delay or wait is negative, not finite, or longer than 86,400 s (24 h);
- coordinates are not finite or beyond ±100,000;
- a click count is not 1–3, a key code is not 0–255, a scroll amount is beyond ±100,000 px;
- a required field for the action kind is missing, or typed text is empty or longer than 100,000 characters.

Recordings contain **data only**. There is no field that can run a command or script.

## Top level

| Field | Type | Notes |
| --- | --- | --- |
| `formatVersion` | integer | Required. Currently `1`. |
| `id` | UUID string | Identifies the macro. Imports get a new id if it already exists. |
| `name` | string | Display name. |
| `createdAt`, `modifiedAt` | ISO 8601 date string | UTC, for example `2026-10-25T14:03:00Z`. |
| `targetApp` | object, optional | `{ "bundleID": "com.example.App", "name": "Example App" }`. App that was in front when recording started. Used by the optional foreground check. |
| `recordedScreen` | object, optional | `{ "width": 1512, "height": 982 }`. Main display size when recorded; used to warn if it differs. |
| `playbackDefaults` | object, optional | `{ "speed": 1, "repeatCount": 1, "loopDelay": 0 }`. `repeatCount` 0 means loop until stopped. |
| `notes` | string, optional | Free text. |
| `actions` | array | Ordered list of actions. |

## Actions

Every action has:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID string | Unique within the macro. Generated if missing. |
| `kind` | string | One of the kinds below. |
| `delay` | number (seconds) | Time to wait **before** this action, measured from the end of the previous action, at 1× speed. |

Using a relative delay means that deleting, duplicating or reordering actions never leaves stale absolute timestamps. The total length of a macro at 1× is the sum of all `delay` values plus all `wait` durations (typing time is not included).

| `kind` | Extra fields | Meaning |
| --- | --- | --- |
| `move` | `x`, `y` | Move the pointer. |
| `drag` | `x`, `y`, `button` | Move the pointer with a button held. |
| `mouseDown` | `x`, `y`, `button` | Press and hold a button. |
| `mouseUp` | `x`, `y`, `button` | Release a button. |
| `click` | `x`, `y`, `button`, `clickCount` | Press and release. `clickCount` 2 is a double-click, 3 a triple-click. |
| `scroll` | `scrollX` and/or `scrollY`, optional `x`, `y` | Scroll by pixels. |
| `key` | `keyCode`, `modifiers` | Press and release one key. Shortcuts, Return, arrows, and so on. |
| `text` | `text` | Type text, independent of the keyboard layout. A line break is typed as Shift+Return. |
| `wait` | `duration` | Pause for `duration` seconds (in addition to `delay`). |

Field notes:

- `x`, `y`: points in the global coordinate space, origin at the top-left of the main display.
- `button`: `"left"`, `"right"` or `"other"` (middle).
- `keyCode`: a macOS virtual key code (for example 36 = Return, 49 = Space, 40 = K).
- `modifiers`: array of any of `"control"`, `"option"`, `"shift"`, `"command"`.

## Example

```json
{
  "formatVersion": 1,
  "id": "8E0C5C26-3C5B-4C0E-9D55-2A6E6E6B0001",
  "name": "Example",
  "createdAt": "2026-10-25T14:03:00Z",
  "modifiedAt": "2026-10-25T14:03:00Z",
  "playbackDefaults": { "speed": 1, "repeatCount": 1, "loopDelay": 0 },
  "actions": [
    { "id": "…", "kind": "key",  "delay": 0,   "keyCode": 40, "modifiers": ["command"] },
    { "id": "…", "kind": "wait", "delay": 0,   "duration": 0.4 },
    { "id": "…", "kind": "text", "delay": 0.1, "text": "general" },
    { "id": "…", "kind": "key",  "delay": 0.2, "keyCode": 36, "modifiers": [] }
  ]
}
```

A complete, personal-data-free sample is in [`Samples/discord-send-message.macro.json`](../Samples/discord-send-message.macro.json).

## How playback uses the fields

- Each action's `delay` (and a `wait`'s `duration`) is divided by the playback speed.
- At speeds above 1×, clicks, key presses and typing are not scheduled faster than the *Minimum action delay* setting, and typing speed is limited by the *Delay per typed character* setting, so fast playback stays reliable. Mouse movement scales fully.
- Pointer movement samples are scheduled against the ideal timeline so that timer overshoot does not accumulate.
- Pausing freezes the timeline; resuming continues from where it stopped.
- Stopping cancels immediately; no queued action is performed afterwards, and any mouse button still held is released.
