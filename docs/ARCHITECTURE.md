# Architecture

`src/pet.ps1` owns native UI, presentation state and isolated operations. `modules/` handles window safety, task-derived states, diagnostics and reset cards. `renderer/` is the Electron/Live2D UI with a narrow preload API and session-bound file command bridge. `account_sync/` uses separate workers for account inspection and explicit transactions; `quota_pages/` holds per-account views. `notice_monitor/` fetches public reset data and reduces it into notices. `i18n/` supplies the shared four-language catalogue and native translation adapter.

Each renderer session has an owner PID and isolated state. Hidden/tray operation suspends animation; explicit recovery is separate from routine topmost polling. The Codex observer accepts tested versions and validates project/thread scope before attributing task events. User text remains content rather than translated interface labels.

Community feed, forecast and timeline are independent inputs. Cached data carries freshness/error state. A community completion is never promoted to verified account recovery; probabilities alone never emit reset-completed alerts. Public API requests contain no account credentials, use an identifiable User-Agent and rate-limit/backoff handling.
