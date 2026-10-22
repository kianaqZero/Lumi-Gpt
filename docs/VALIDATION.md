# Validation snapshot — 2026-10-22

R10 development candidate, not a public installed release. 130 scenario assertions passed: site reducer 24, four-language Chromium UI 31, native offscreen WPF 23, isolated real Cubism/WebGL renderer 44, patch apply/rollback 8. JavaScript syntax checks: 45 files. PowerShell syntax checks: 54 files. Public feed, forecast and timeline requests succeeded and initial connection emitted zero notices.

Renderer tests used synthetic tasks/accounts/cards, isolated language settings and a hidden test window. They exercised preload IPC, 15 model transitions, tray suspension beyond 45 seconds, explicit restore and renderer-crash recovery. No real account switch or credit was consumed. Synthetic wheel input used Chromium's input protocol; physical focus was not changed.

These checks do not establish long-run reliability, compatibility with all GPU/full-screen applications, live screenshot hotkey behavior, real switch recovery, real card eligibility or complete translation quality. Existing user software was not replaced to obtain these results. Public source also has portable Codex Home configuration; that configuration path was checked separately and remains a development assembly workflow.
