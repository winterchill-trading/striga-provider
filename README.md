# striga-provider

`banking-provider`'s `Provider.S` and `Sandbox.S` implemented over the Striga v1 API
(`striga-client`): customers and KYC, EUR and crypto accounts, SEPA, intraledger,
on-chain and Lightning payouts confirmed by SCA, swaps, virtual cards, statements, and
webhooks normalized into `banking-provider` events. Sandbox by default.

## Why separate

`banking-provider` describes what an application needs from any banking-as-a-service
provider and stays free of provider names; `striga-client` is a plain SDK for one API.
This adapter is the only place that knows both, so swapping providers, or running the
fake in tests and the mock mode, never touches application code.

## Quick start

```sh
cp .env.example .env               # sandbox credentials from the dashboard
set -a; . ./.env; set +a
dune build
STRIGA_LIVE_TESTS=1 dune test      # also runs the conformance suite on the sandbox
```

```ocaml
module A = Striga_provider.Adapter

let%bind.Deferred.Or_error adapter = return (A.of_env ()) in
let%bind.Deferred.Or_error customer = A.create_customer adapter ~customer_id ~person in
(* After KYC approval. Striga lists EUR only for a customer with an SCA session: on the
   sandbox open_account opens one itself; elsewhere call A.start_session and
   A.complete_session with the customer's SMS code first. An EUR account comes back
   enriched (with its IBAN). *)
let%bind.Deferred.Or_error account = A.open_account adapter customer.id Money.Currency.eur in
```

A service passes its own `Store.t` (persisted links between our ids and Striga's; see
below) and hands each webhook delivery to `ingest_webhook`. Without a public webhook URL
the adapter polls KYC, account statements and card statements while `events` has a
subscriber.

## Environment

| Variable                | Required | Purpose                                                    |
| ----------------------- | -------- | ---------------------------------------------------------- |
| `STRIGA_API_KEY`        | yes      | request signing; webhook signature key                     |
| `STRIGA_API_SECRET`     | yes      | request signing                                            |
| `STRIGA_BASE_URL`       | no       | defaults to the sandbox; any other host needs `~live:true` in striga-client |
| `STRIGA_APPLICATION_ID`, `STRIGA_UI_SECRET` | no | the browser card-number component      |
| `STRIGA_LIVE_TESTS`     | no       | `1` lets `dune test` run the conformance suite             |
| `STRIGA_CONFORMANCE_ONLY` | no     | runs only the scenarios whose name contains this text      |

Credentials are read only from the environment and never logged.

## Modules

| Module         | What it does                                                                 |
| -------------- | ---------------------------------------------------------------------------- |
| `Adapter`      | `Provider.S`, `Sandbox.S`, webhook ingestion, the poller                     |
| `Store`        | links Striga cannot hold (our customer, transfer, challenge, swap, card request ids) and card display tokens, with an in-memory implementation |
| `Refs`         | account and standing order refs carrying the Striga user id                 |
| `Units`        | Striga tickers and smallest units to `Money` (USDC cents rescaled to micro-units) |
| `Kyc_map`      | Striga tiers and statuses to kyc-core steps, status and events              |
| `Account_map`  | accounts, enrichment (IBAN, deposit addresses), balances                    |
| `Tx_map`       | ledger entries to transfer updates and deposits                             |
| `Card_map`, `Card_tx_map` | cards, statuses, EUR limits; card transactions to card-core advices |
| `Striga_time`  | ISO and epoch-millisecond timestamps                                        |

`docs/mapping.md` lists every operation with its Striga endpoints, every webhook and
ledger entry with its event, the currency, KYC tier, SCA and card mappings, and the gaps.

## Conformance

`test/live` runs `banking-provider`'s `Conformance` functor (the scenarios the fake
passes) against the sandbox when `STRIGA_LIVE_TESTS=1` and the credentials are set;
otherwise it prints one line and passes, which is what CI sees. Each run creates new
sandbox users prefixed with a timestamp. Offline, the mappings are tested on recorded and
documented Striga bodies in `test/fixtures` (ids and IBANs redacted).

Sandbox run on 2026-10-15 (14 scenarios; the suite has grown from 11, 2-minute timeout
each, Estonian test person): **13 passed, 1 failed**. The run on 2026-10-14 passed 4 of
11: every EUR scenario stopped at `open_account`, because Striga lists the EUR account
only once the customer has an SCA session and the adapter was waiting for it to
appear instead of opening one.

| Scenario                                                   | 2026-10-14 | 2026-10-15 |
| ---------------------------------------------------------- | ---------- | ---------- |
| create_customer is idempotent on our customer id           | pass       | pass       |
| a KYC approval is published as an event and reported by kyc_status | pass | pass |
| an approved customer gets an EUR account with an IBAN      | fail       | pass       |
| a deposit is published once and credits the balance       | fail       | pass       |
| a payment confirmed by SCA settles and debits amount plus fee | fail    | pass       |
| initiating the same transfer twice pays once               | fail       | pass       |
| a payment above the balance does not leave the account     | fail       | pass       |
| a wrong SCA code is refused without naming a factor        | fail       | pass       |
| a webhook with a bad signature is refused                  | pass       | pass       |
| a test delivery arrives as a Ping event                    | pass       | pass       |
| a virtual card is approved, and declined with 57 once frozen | fail     | pass       |
| an account keeps its details when opened and enriched again | not in the suite | pass |
| a KYC decision set to wait comes after its delay           | not in the suite | pass |
| verify_payee answers, and a simulated answer is returned   | not in the suite | fail: Striga offers no payee check |

What it took, besides the session: the simulator's deposit memo reads
`SEPA_PAYIN_COMPLETED 100 EUR <reference>`, so the deposit is found by the reference at
the end of the memo; Striga's SEPA payout needs a BIC (`400 00002 "Invalid BIC"`
without one), which the live run answers through `Config.bic_for`; a code that is not
six digits fails as `400 00002 "Invalid verificationCode"` and is now a wrong code; the
default 3-D Secure password had hyphens, outside Striga's charset.

Verified live by this adapter: user creation and its idempotency, e-mail and mobile
verification, KYC start and the simulated approval, KYC events, the SCA session (SMS
login with the sandbox code), the Payment Account consent, EUR account listing and
enrichment, simulated SEPA deposits, SEPA payouts confirmed by SMS code and settled by
the simulator, double initiation, the overdraft refusal, the wrong-code path, virtual
card issuing, simulated authorizations and the frozen-card decline, webhook signature
refusal and the ping. Intraledger moves between two customers are verified on fixtures
only (the suite has no intraledger scenario).

## Known gaps

- **No payee check.** Striga's API has no verification of payee, so `verify_payee` and
  `simulate_payee_check` answer an error, and the conformance scenario for them fails.
  The UK and US rails are refused.
- **SCA session for EUR and USDC.** Striga lists and reads EUR and USDC accounts only
  while the customer has an SCA session (180 days; a 2FA reset revokes it). On the
  sandbox the adapter opens one itself with `Config.sandbox_code`; elsewhere the
  application calls `start_session` and `complete_session` with the customer's SMS
  code, or `open_account` and account reads fail with `30070` `SCA_REQUIRED`.
- **SEPA needs a BIC.** Striga's payout takes IBAN plus BIC. The adapter uses the
  beneficiary's BIC, then the SEPA details', then `Config.bic_for`; without one it
  refuses before calling Striga. A payout to an IBAN of one of this application's
  accounts known to the adapter goes intraledger, since Striga refuses it as SEPA
  (`400 31003`, "use the inter/intra methods").
- **Payment Account consent** is recorded by the adapter before the EUR account is
  opened (`Config.payment_account_consent`, default `` `Record None ``, with
  `end_user_ip`); a service that collects the customer's acceptance itself sets
  `` `By_application ``.
- **No crypto funding in the sandbox**: on-chain, crypto intraledger and Lightning
  payouts stop at Striga's balance or invoice checks; `simulate_deposit` credits EUR by
  SEPA only.
- **No idempotency keys or external ids at Striga**: the `Store` is what makes creates
  idempotent; a service must persist it (only the in-memory store ships here).
- **Standing orders** return an error: Striga's are deposit conversions, not dated
  payments. Schedule those in the application.
- **Fee quotes** for on-chain and Lightning are only known once a payout is initiated;
  SEPA and intraledger quote zero (the sandbox application charges none).
- **Card numbers**: `card_details_token` needs Striga's browser component to start the
  consent (`card_consent_started`); the resulting token (24 hours) lives in the `Store`; card limits are whole euros only, without ATM counts,
  MCC or country block lists; `Blocked`, `Requested` and `Expired` cannot be set.
- **`simulate_transfer_outcome`** covers confirmed SEPA payouts only.
- **`ping`** publishes its own `Ping`: Striga answers 200 whether or not the delivery
  reached the dashboard's URL.
- **SCA attempts** are counted locally (Striga allows five and does not report the rest);
  each confirmation sends the configured `end_user_ip`, since `Provider.S` carries none.
- Transfer status ordering is the adapter's own rank table over a stored status, not
  `Transfer_update.apply`, because the store keeps a record, not a full `Transfer.t`.
