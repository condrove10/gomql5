# Synthetic fixtures — NOT vendor data

Every file here was written by hand for tests and replay demos. The field names
follow the example in the Myfxbook API documentation as recorded in the
project handoff; the numbers are invented. None of these files is a captured
response, and records produced from them are labelled `source_mode: "replay"`.

## Captured vendor responses (unauthenticated errors only)

`captured-2026-11-04-*.json` are real bodies returned by
`https://www.myfxbook.com/api/…` on 2026-11-04 (HTTP 200,
`application/json;charset=utf-8`, served through Cloudflare) to requests with
no or an invalid session. They pin the application-error shape. No successful
(authenticated) response has been captured.
