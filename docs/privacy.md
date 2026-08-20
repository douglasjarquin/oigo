# Privacy

Oigo is a local dictation app.
It does not create an account.
It does not operate a cloud service.
It does not upload transcripts, recordings, dictionary entries, or clipboard contents.

## Network

Oigo initiates no network requests of its own.
It has no telemetry SDK, crash reporter, analytics client, or update checker.

Apple-managed Speech and Foundation Models assets are system services.
Those services are not Oigo network clients.
macOS may download or refresh those assets independently of Oigo.

After the required speech assets for the selected locale are installed, Oigo is intended to work with networking disabled.

## Local data

Audio, transcripts, History, and the custom dictionary stay on this Mac.

Typical locations:

- `~/Library/Application Support/Oigo/Sessions/` for durable recordings and transcripts
- `~/Library/Application Support/Oigo/custom-dictionary.json` for the custom dictionary
- UserDefaults key `oigo.settings.v1` for settings

Oigo does not sync this data.

## Diagnostics export

Export Diagnostics is an explicit user action.
The exported JSON contains versions, settings categories, state and error codes, and counts.
It does not contain transcript text, dictionary contents, audio, clipboard data, focused-element text, or file paths that include user content.
Oigo does not log the exported JSON.

## Removal

Quit Oigo, then delete `Oigo.app`.
Delete `~/Library/Application Support/Oigo` if you want recordings, transcripts, and the dictionary removed.
Remove the `oigo.settings.v1` defaults key if you want settings removed.
Launch at Login, if enabled, can be turned off in System Settings > General > Login Items.
