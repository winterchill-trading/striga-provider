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

### Removed

- `Config.provisioning_timeout`.

### Fixed

- The default 3-D Secure password contained hyphens, which are outside Striga's charset,
  so card creation was refused. The default now uses letters, digits and `#`/`!`, and a
  configured password is checked before calling Striga.
