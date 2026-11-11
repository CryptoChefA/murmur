# Murmur — project prompt

Paste this into a fresh session to rebuild or extend the project. It says what
Murmur is, what "done" means, and how the interface behaves.

## What it is

Murmur is a free, open-source dictation app for the Mac. Hold a key, talk,
release: your words are transcribed on the Mac, tidied by a language model, and
typed into whatever app has the cursor. It is in the same category as Wispr
Flow, Superwhisper and MacWhisper's dictation mode, and aims for the same
finish, but everything runs locally by default and it costs nothing.

It replaces an earlier version ("Flow") that was a Hammerspoon script talking to
a Python server, ffmpeg, Whisper and Ollama. That worked but kept four processes
and a multi-gigabyte model resident. Murmur is one native process.

## Hard requirements

1. **One native app.** Swift, AppKit + SwiftUI, Swift Package Manager. No
   Python, no ffmpeg, no local server, no Electron, no Xcode project needed to
   build (`./build.sh` with Command Line Tools is enough).
2. **Light when idle.** Menu-bar only (no Dock icon). At rest: 0% CPU, no
   timers, no polling, no model in memory. The Whisper model loads on the first
   key press and is released after a configurable idle period (default 5 min).
   Targets: under 60 MB idle, app bundle under 15 MB without the model.
   (Measured on an M4: 11 MB idle, 0 wake-ups, 7.6 MB bundle.)
3. **Fast.** Key release to text on screen in about a second for a normal
   sentence on Apple Silicon (Metal-accelerated whisper.cpp).
4. **Private.** Audio never leaves the Mac. No telemetry, no accounts, no
   update pings. The only network use is (a) downloading a model the user picks
   and (b) the optional cloud cleanup, which sends text only, and only if the
   user pasted their own API key.
5. **Free to release.** MIT license, no bundled secrets, no personal paths or
   names in the repo.

## Pipeline

```
hotkey ─▶ record (AVAudioEngine, 16 kHz mono) ─▶ whisper.cpp large-v3-turbo
       ─▶ rules (dictionary, snippets, spoken commands)
       ─▶ AI cleanup (Apple on-device model, or user's API key)
       ─▶ insert at cursor (paste, clipboard restored) ─▶ history
```

- **Speech:** whisper.cpp linked statically, Metal on. Default model
  `large-v3-turbo` quantized (q5_0, ~570 MB); Settings offers full precision
  (~1.6 GB) and smaller models. The user's dictionary words are passed to
  Whisper as the initial prompt so names and jargon are spelled right.
- **Cleanup:** removes fillers and false starts, fixes punctuation and
  capitalisation, applies self-corrections ("at five, no, six" → "at six"),
  formats spoken lists. It must never answer, add to, or summarise what was
  said. Default engine is Apple's on-device model (FoundationModels). Optional:
  Anthropic, OpenAI or Groq with the user's own key, stored in the Keychain.
  If cleanup fails or is slow, the raw transcript is inserted instead; a
  dictation is never lost.
- **Styles:** per-app tone. Formal in Mail, casual in Messages, verbatim in
  Terminal and code editors, matched by bundle ID, editable.
- **Insertion:** pasteboard + synthetic ⌘V, previous clipboard restored
  (or the dictation left on it, a Settings switch). If
  Accessibility is not granted the text stays on the clipboard and the pill
  says so.

## Controls

- **Hold Fn** — push to talk. Release to finish.
- **Double-tap Fn** — hands-free. Tap again, or click ✓, to finish.
- **Esc** — cancel, nothing is inserted.
- The key is configurable (Fn, Right ⌥, Right ⌘, Right ⌃).

## Interface

Three surfaces, all appearance-aware (light and dark), monochrome with a
single accent, system font, no brand colour splashed on top of the user's work.

### 1. The orb

A small liquid-chrome sphere at the bottom-centre of the screen, shown only
while dictating. Non-activating panel: it never steals focus from the app
being typed into.

- Listening: the orb stands alone in the centre. Its metal flows faster,
  stirs harder, swells and brightens with the voice. Holding the key shows the
  orb alone (release is "done", Esc is "cancel"); hands-free adds a small
  cancel (✕) and stop (■) either side of it.
- Thinking: the orb shrinks and slides left as a dark glass capsule opens
  beside it reading "Transcribing".
- Done: it fades out; the text arriving is the confirmation. A problem turns
  the chrome red and shows one short line in the capsule ("Didn't hear
  anything", "No microphone access").
- One small Metal shader, compiled from source at first use, so there are no
  shader files and the project still builds with Command Line Tools. Drawing
  stops completely when the orb is hidden.

### 2. The menu-bar item

A small glyph that fills while recording. Menu: start/stop dictation, paste
last transcript, the five most recent transcripts (click to copy), open
Murmur, pause, quit.

### 3. The main window

Sidebar on the left, content on the right. Opened from the menu bar; closing
it returns the app to zero UI.

| Section    | What it shows |
|------------|---------------|
| Overview   | Words dictated today / this week / all time, speaking pace (wpm), time saved versus typing, a 14-day activity chart, current streak, engine status. |
| History    | Searchable list of every dictation: cleaned text, the raw transcript behind it, app it went to, duration. Copy, re-insert, delete, clear all. Retention setting (forever / 30 days / off). |
| Dictionary | Words Murmur should always spell your way, and "heard as → write as" replacements. |
| Snippets   | Spoken trigger → expansion ("my address" → the full address). |
| Styles     | Per-app tone rules and the default cleanup level (Off / Light / Polished). |
| Settings   | Hotkey, microphone, model picker with download progress, cleanup engine and API key, model idle timeout, launch at login, sounds, language. |
| Setup      | Permission checklist (Microphone, Accessibility) with live status and a button to open the right System Settings pane, plus a "try it here" test box. |

First launch opens Setup. Everything else stays out of the way.

## Quality bar

- Every state has a visible answer: no model yet, no permission, mic
  unplugged, cleanup unavailable, empty transcript.
- No dictation is ever silently dropped; the worst case is raw text on the
  clipboard and an entry in History.
- Unit checks for the text rules (dictionary, snippets, commands, stats) and a
  command-line mode (`Murmur --transcribe file.wav`) so the speech path can be
  tested without a microphone.
- Measured, not assumed: idle CPU, idle memory, wake-ups, and
  release-to-text latency are recorded in the README.

## Out of scope for v1

iOS, Windows, meeting recording, speaker labels, live streaming captions,
team features, auto-update.

## Repo layout

```
Murmur/
  Package.swift
  build.sh              # builds whisper.cpp, the app, and Murmur.app
  Sources/Murmur/       # app
  Sources/MurmurCore/   # pure logic: rules, stats, storage (testable)
  Sources/MurmurCheck/  # the checks, as a plain executable (no Xcode needed)
  Resources/            # Info.plist, entitlements
  vendor/whisper.cpp    # fetched by build.sh, not committed
  README.md  LICENSE  PROJECT_PROMPT.md
```
