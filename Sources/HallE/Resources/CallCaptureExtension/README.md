# Hall-e Browser Calls

Load this folder with Chrome’s **Extensions → Developer mode → Load unpacked**.
Copy the extension ID Chrome displays into Hall-e’s **Settings → Browser & Calls**
and install the local native host there. The extension only sends approved call
URL metadata to that local host; it does not upload browsing data or capture audio.
# Hall-e Browser Calls

This is Hall-e's unpacked Manifest V3 extension. It watches only approved call
domains and passes a minimal local signal to the native helper; it does not
upload page content, browsing history, or audio.

Install it from **Hall-e → Settings → Browser & Calls**. For a custom call
domain, add it in Hall-e, then use this extension's **Options** page to approve
the same exact host in Chrome's permission dialog.
