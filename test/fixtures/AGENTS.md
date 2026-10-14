# AGENTS.md: test/fixtures/

Provider response bodies and webhook payloads, read by `test/fixture.ml`. `README.md` in this directory
says how they were made.

- Replace ids with placeholders and scrub personal data, sender names and tokens before committing.
- Addresses and IBANs are public test values that the payments-core checksum accepts. Keep them valid.
- Do not edit a fixture to make a test pass; check the mapping against the documented shape first.
