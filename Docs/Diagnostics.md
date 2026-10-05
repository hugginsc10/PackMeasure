# Diagnostic email

Open the existing Diagnostics action on a room, object, compartment, or shelf scan/review screen before retrying or closing it. **Send diagnostics** freezes that report, shows `hugginsc10@gmail.com`, and offers an optional issue description. It does not upload automatically.

**Email report** opens the native Mail composer with the recipient, a subject containing the report ID and app build, the note, and a named UTF-8 `.txt` attachment. The attachment adds UTC export time, app version/build, device family/hardware type and iOS version, then preserves the original report verbatim. Interior reports contain header text plus replay JSON and can be several megabytes; they are attached as text rather than placed in a URL or email body. No camera photographs, device serial/name, or saved room/inventory library are added. Scan geometry and dimensions can be present; the sender reviews the recipient and taps Send.

When Mail is unavailable, **Share report** exports the same file using the iOS share sheet. Select Gmail or another app, or save to Files, and address it to the displayed inbox. Some share extensions do not fill the recipient; **Copy email address** provides it. Cancelling sharing keeps the note and snapshot open. Email cancellation, saved drafts, and failures have distinct messages and permit retry/export.

Settings → **Report a problem** produces app/device details and the note. It explicitly contains no active scan diagnostics. For scan failures, use the diagnostic action in that session; room/object/shelf reports are session-local. The existing last real compartment-sweep copy remains on the iPhone for USB retrieval.

Mail reporting `.sent` means the message was accepted for sending, not that the diagnostic inbox received it. Confirm the sender's Sent folder and the recipient's inbox; draft saving and share-sheet completion are not delivery confirmation. [Apple's Mail composer documentation](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller) describes this limit.

The receiver can find reports by the `PackMeasure` subject and report ID, then retain the attachment with the issue/screenshot and replay it where supported. There is no server-side ticket queue, automatic email delivery, or diagnostic dashboard in this feature. TestFlight's separate screenshot/crash feedback stays in App Store Connect → TestFlight → Feedback.
