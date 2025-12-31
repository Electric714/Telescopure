# Agent Mode

Agent Mode lets Telescopure drive pages inside the built-in WKWebView with help from the Gemini API. It captures a snapshot of the current page, sends it to Gemini together with your goal and a short rolling log, and executes the actions returned by the model. Everything runs on-device inside the app—no external proxy or backend is used.

## Setup

1. Open the new **Agent Mode** panel from the header toolbar (sparkles icon).
2. Enter your **Gemini API key**. The key is encrypted in the iOS Keychain and only read by the app when sending requests to Gemini.
3. Provide a **goal** that describes what the agent should accomplish.
4. Use **Refresh Models** to fetch available Gemini models. The app prefers `gemini-2.5-flash`, then `gemini-2.5-pro`, then `gemini-3-flash`, then `gemini-3-pro`, otherwise it falls back to the first model that supports `generateContent`. You can manually override the model name; invalid overrides are rejected and reverted.
5. Toggle **Enable Agent Mode**.
6. Optional: use **Test Gemini** to confirm your key replies with `OK`.

## Running the agent

- **Step Once** performs a single request/response loop.
- **Run** performs automatic steps up to the configured **Auto run step limit** (default 10) or until the model returns `done`/`complete`.
- **Stop** cancels any active run task. Runs can also pause when waiting for safety confirmation.
- **Describe Screen** sends the current snapshot to Gemini with a short prompt and logs the response.
- If a safety warning is raised, tap **Continue after safety warning** to resume.
- The panel shows the selected model (read-only) and a manual override field. A “Refresh Models” action re-queries the Gemini model list using the `x-goog-api-key` header.

## Supported actions

Gemini responses should be JSON (plain or in a fenced code block) with an `actions` array. The agent understands:

- `navigate(url)`: Loads the provided URL using `webView.load(URLRequest(url:))`.
- `click_at(x,y)`: Clicks `document.elementFromPoint` at normalized coordinates (0–1000) mapped to the WKWebView viewport or captured snapshot size.
- `scroll(deltaY)`: Executes `window.scrollBy(0, deltaY)`.
- `type(text)`: Appends text to `document.activeElement.value` and dispatches an `input` event.
- `wait(ms)`: Sleeps for the requested milliseconds.

## Loop details & safety

- Each step captures a PNG screenshot via `takeSnapshot`, base64 encodes it, and sends it to Gemini using the `x-goog-api-key` header. If the snapshot is identical to the last one, the agent logs “no visual change” and waits instead of re-sending it.
- The rolling log includes timestamps, raw model output, parsed actions, execution results, warnings, and errors. The Agent panel also shows the current run state (idle/running/paused) and step counter.
- A hard step limit prevents infinite loops and the run task is cancellation-aware.
- Before every action the agent scans the page title and visible text for destructive keywords (purchase, buy, pay, send, delete, confirm, submit order). Execution pauses until you explicitly resume.
- Basic exponential backoff is used for rate limits and server errors. When rate limited the agent pauses instead of spinning.

## Known limitations

- Parsing is best-effort; malformed or non-JSON responses are logged and skipped rather than crashing the app.
- Coordinates assume the current WKWebView viewport matches the snapshot size; resizing the view between steps may affect targeting accuracy. Gemini returns normalized coordinates in the range 0–1000 that the agent converts to pixels using the captured snapshot size.
- Gemini calls require network access and a valid API key; failures appear in the log and rate limits trigger short waits.
