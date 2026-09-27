# Modeleaf Settings

Press **Cmd+,** or choose **Modeleaf → Settings…**. Settings are a draft until you choose **Apply**.

## General

- **Small scroll**: `1–512 pt`, default `32 pt`.
- **Large scroll**: `10–200%` of the viewport, default `80%`.
- **Zoom**: magnification factor `1.01–2.00×`, default `1.10×`.
- **Confirm external links**: True/False button aligned with the other value controls. True requires confirmation before opening external URLs.

## Key Bindings

Key Bindings uses the same action catalog and ordering as **?** Keyboard Help. Fixed-only actions are omitted; unassigned editable actions stay available. **Prefix & Sequences** groups Common Prefix with Sequence timeout (`100–2,000 ms`, default `400 ms`). The timeout also applies to ordinary two-key sequences.

## Keyboard navigation
- **Right-hand selected row:** j/k or arrows moves through rows. Enter edits a number, toggles True/False, or records a shortcut. h returns directly to the sidebar. Only one row across the two panels is highlighted.
- **Closing:** Escape outside editing or search closes clean settings immediately. Unsaved changes show Continue Editing (Esc), Discard and Close (n), Save and Close (y). Save and Close is initially selected; Enter activates the selected choice. h/l or left/right moves the choice. Save errors leave Settings open. There is no Cmd+Enter save shortcut.
- **Left sidebar:** j/k selects General or Key Bindings. l or Enter enters the first right-hand row and removes the sidebar highlight.
- **Numeric editing:** Enter validates and confirms the row's draft value. Escape restores the value from before this edit. Invalid values remain in edit mode with an explanation.
- **Shortcut recording:** Enter confirms, Escape cancels. Empty Enter removes the primary editable binding, except on Common Prefix where it keeps the previous prefix. During recording, navigation keys are recorded rather than dispatched.
- **Search:** / enters action-name search in Key Bindings. Enter/Escape returns to the list, retaining the query. Footer hints describe the current input context.

## Binding rules

One input is one ordinary key with zero to four modifiers. Direct two-key sequences require both inputs to be physically unmodified, including Shift. The common prefix accepts exactly one following input with any modifiers. Modifier-only presses do not add a step. Canonical storage and collision checks stay independent from presentation.

Settings, help and palette share compact labels: produced characters remain `?`, `|`, `U`; modified chords use symbols such as `⌘⇧p`; sequences use `→`; symbolic prefixes display as `<pre>`. Layout-confirmed input instructions appear as secondary details. Help lists editable aliases before fixed keys; the palette prefers the first editable alias, then a fixed key.

PDF arrow navigation, **Cmd+Shift+P** command-palette access, Escape search cancellation, and native prompt lifecycle controls remain fixed in their owning contexts. Resetting an action restores its default aliases without removing foundational keys.

## Apply, Discard, and defaults

- **Apply** validates both sections, saves them together and activates the saved generation immediately.
- **Discard** abandons pending changes. Closing a dirty window asks for confirmation.
- **Restore Defaults** prepares General and Key Bindings defaults in the draft; Apply saves them. Theme and link-indicator state are unaffected.
- **Reload saved settings** is available for blocked file-conflict or invalid-file recovery.

Invalid JSON, unsupported versions, unknown fields, or invalid values report a diagnostic without silently replacing the saved file. The maximum settings document size is 256 KiB.

## Storage and compatibility

The app manages `~/Library/Application Support/Modeleaf/settings.json`. Version 1 stores differences from built-in defaults; missing values inherit those defaults. The UI is the supported editing surface. Opening Settings creates no file; Apply saves atomically.

Existing `~/.config/modeleaf/config.toml` is ignored, not deleted or migrated. Re-enter preferences in Settings. Write Default Config, Reload Config and Reset Config have been removed. Themes and link-destination indicators retain their separate pickers and state storage.
