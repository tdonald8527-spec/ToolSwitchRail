# Changelog

## 0.4.1 — 2026-11-25

- Fixed tools landing out of line after a switch: the workspace frame is no longer read back immediately after placing a window (Electron apps apply frames asynchronously, so the read returned the old position). The requested frame is kept; the actual frame is adopted only if the app really refused it after settling.
- The rail catches up right after a switch (short burst of position checks) instead of waiting for the 1.5 s idle poll.
- The rail no longer covers other apps: it is now a normal-level window that sits on top only while one of its tools is in front, and goes behind whatever other app you switch to while staying visible.

## 0.4.0 — 2026-11-25

### Stability
- The rail is placed from the managed window's actual frame after every switch, so it no longer floats over an app that refused the requested size or position.
- Switching hides the other registered apps (`workspace.minimizeOtherRegisteredWindows` is now honoured). Background windows are no longer resized on every switch, which removes the "jumping" and the ever-growing stack size.
- The workspace frame used for the next switch is learned only from user drags/resizes, not from apps restoring their own saved frames.
- The rail tracks the app's focused (visible) window instead of the "main" one.
- `Cmd + Option + M` and web-tool matching never hide, move or resize the general browser (Chrome) as a whole.
- Accessibility calls time out after 0.5 s, so one busy app cannot freeze the rail.
- Drag isolation and rail adjacency only react when the tracked window actually moved; rapid switches can no longer be overtaken by stale activations.
- Idle polling reduced (window tracker 1.5 s, workspace scan 3.5 s, status 5 s).

### Experience
- Unread red dots removed; the unread probe no longer runs.
- New `UI/Experience.swift`: one motion vocabulary (`Motion`), one state vocabulary (`ToolStateLabel`), non-blocking toasts (`ToastCenter`), and shared actions (`RailActions`).
- Remove with undo everywhere; no confirmation dialogs.
- One settings menu for the rail gear, the dashboard gear and the menu-bar right-click (which previously could not open at all). Menu items reflect the current state ("Collapse / Show workspace", "Fill screen / Restore size").
- Removed: rail appearance toggle, "Reload configuration" (config hot-reloads), "permission OK" menu row, redundant dashboard cards and footer actions.
- Top traffic-light dots replaced by a single labelled collapse button.
- Rail show/hide fades instead of popping; toasts, reordering, insert/remove and running-state changes are animated; Reduce motion is respected.
- New `build-and-install.command`.
