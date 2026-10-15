# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `start_session` and `complete_session`: open the customer's SCA session (SMS login),
  which Striga needs before it lists or reads EUR and USDC accounts.
- `Config.sandbox_code`, `Config.account_retry`, `Config.deposit_timeout` and
  `Config.payment_account_consent`.
- `Config.valid_3ds_password` and `Config.random_password`.
- `Config.bic_for`: the payee's BIC for a SEPA payout when the beneficiary has none.
- `Config.tagged_email` (the default `email_for`).
- `Store.find_card_token` and `Store.set_card_token`: the card display token is kept in
  the store, so a restart does not ask the cardholder for a new code.

### Changed

- `open_account` no longer waits minutes for Striga to "provision" EUR: the account
  exists from KYC approval on and is listed once the customer has an SCA session. On the
  sandbox the adapter opens the session itself; the listing is retried for
  `account_retry` (30 s) only. An EUR account is enriched (IBAN) before it is returned.
- `open_account` for EUR records the Payment Account consent through striga-client
  (`User.set_payment_account_consent`) unless one is already recorded.
- Account reads that Striga answers with `30070` (`SCA_REQUIRED`) open a session on the
  sandbox and retry once.
- `simulate_deposit` waits `deposit_timeout` (1 minute) for the asynchronous credit.

- A SEPA payout to an IBAN of an account the adapter knows goes intraledger (Striga
  refuses SEPA inside one application with `31003`); without a BIC a SEPA payout is
  refused before calling Striga.
- The credit side of an intraledger move has its own event id (`...:in`).

### Removed

- `Config.provisioning_timeout`.

### Fixed

- Webhook notices on the known channels with no event of their own (`ACCOUNT_ENRICHED` and
  the other `type` bodies on `/tx`) were refused as an unhandled channel, so Striga
  delivered each one again and again. They are acknowledged now, and an enrichment's IBAN
  is remembered for intraledger routing.

- A SEPA payout routed intraledger (to one of the application's own IBANs) was recorded
  with the SEPA rail, so the sandbox's immediate settlement asked `/simulate/sepa` for it
  and got `500 "No banking tx id found"`. The transfer now records the rail used.

- A simulated deposit was never found: the sandbox's memo is
  `SEPA_PAYIN_COMPLETED <amount> EUR <reference>`, not the bare reference. The reference
  is now matched at the end of the memo.
- After an intraledger payment was confirmed, neither side received an event: the
  confirmation marked the entry's id as published under a Submitted update, and the
  payee's entry shares that id. The confirmation now publishes the entry's own update
  (Settled) and the payee's credit has its own id.
- The tagged e-mail could pass the 64-character local part (`400 00002 "Invalid e-mail
  ID"`); a long tag is now cut and ends in a digest of the customer id.
- A code that is not six digits (`400 00002 "Invalid verificationCode"`) is a wrong code,
  not an error.

- The default 3-D Secure password contained hyphens, which are outside Striga's charset,
  so card creation was refused. The default now uses letters, digits and `#`/`!`, and a
  configured password is checked before calling Striga.
