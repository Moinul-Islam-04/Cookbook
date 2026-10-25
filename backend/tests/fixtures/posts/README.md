# Device payload fixtures

Each file is one `POST /v1/import-drafts` body as the user's device would send it
(`payload`), and the `RawPost` that `app.ingest.normalize` must produce from it
(`expected`). Tests never contact Instagram or TikTok.

All of these are written by hand (`"synthetic": true`); the preview-text format matches
the iOS test `InstagramAndPairingTests`. Replace them with saved real payloads once the
device sends the extra fields.
