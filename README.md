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
(* After KYC; Striga provisions the EUR account itself, open_account waits for it. *)
let%bind.Deferred.Or_error account = A.open_account adapter customer.id Money.Currency.eur in
A.enrich_account adapter account.id  (* the IBAN *)
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
| `Store`        | links Striga cannot hold (our customer, transfer, challenge, swap, card request ids), with an in-memory implementation |
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

Sandbox runs on 2026-10-14 (11 scenarios, 6 minute timeout each), first with the suite's
default person (German resident), then with the Estonian profile striga-client's live walk
had been given an EUR account with (`test/live/live.ml`): 4 passed, 7 failed both times,
with the same scenarios.

| Scenario                                                   | Result |
| ---------------------------------------------------------- | ------ |
| create_customer is idempotent on our customer id           | pass   |
| a KYC approval is published as an event and reported by kyc_status | pass |
| a webhook with a bad signature is refused                  | pass   |
| a test delivery arrives as a Ping event                    | pass   |
| an approved customer gets an EUR account with an IBAN      | fail: no EUR account |
| a deposit is published once and credits the balance       | fail: no EUR account |
| a payment confirmed by SCA settles and debits amount plus fee | fail: no EUR account |
| initiating the same transfer twice pays once               | fail: no EUR account |
| a payment above the balance does not leave the account     | fail: no EUR account |
| a wrong SCA code is refused without naming a factor        | fail: no EUR account |
| a virtual card is approved, and declined with 57 once frozen | fail: no EUR account |

Every failure has the same cause: after the simulated KYC approval (tier 1 `APPROVED`)
the sandbox provisioned the crypto accounts (BTC, ETH, BNB, POL, SOL) within seconds but
no EUR or USDC account, neither within the timeout nor (first run) about an hour later.
The person's residence and mobile made no difference. Every
EUR-dependent scenario starts by opening an EUR account, so none of them reached the
deposit, payment, SCA or card steps. The suite has no crypto scenarios, so the sandbox's
lack of crypto funding does not show here.

Verified live by this adapter: user creation and the lookup that makes it idempotent,
e-mail and mobile verification, KYC start and the simulated approval, KYC polling into
events, wallet listing (crypto accounts), webhook signature refusal, the webhook ping.
Everything else is verified on fixtures here and live (at the SDK level) in
striga-client.

## Known gaps

- **No payee check.** Striga's API has no verification of payee, so `verify_payee` and
  `simulate_payee_check` answer an error, and the conformance scenario for them fails.
  The UK rails are refused.
- **EUR and USDC accounts in the sandbox (open question for the sandbox application's
  settings).** In both runs the sandbox never provisioned them after a simulated KYC
  approval (crypto accounts only), with a German and with an Estonian test person alike,
  so deposits, SEPA payouts with SCA, wrong-code handling, double-initiation and cards
  were not exercised live by this adapter. Earlier SDK-level runs saw EUR appear minutes
  after approval, so the likely cause is on the sandbox side: whether the application
  still has EUR banking (Payment Accounts) enabled needs checking in the dashboard. The
  adapter does not change that application-wide setting.
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
  consent (`card_consent_started`); card limits are whole euros only, without ATM counts,
  MCC or country block lists; `Blocked`, `Requested` and `Expired` cannot be set.
- **`simulate_transfer_outcome`** covers confirmed SEPA payouts only.
- **`ping`** publishes its own `Ping`: Striga answers 200 whether or not the delivery
  reached the dashboard's URL.
- **SCA attempts** are counted locally (Striga allows five and does not report the rest);
  each confirmation sends the configured `end_user_ip`, since `Provider.S` carries none.
- Transfer status ordering is the adapter's own rank table over a stored status, not
  `Transfer_update.apply`, because the store keeps a record, not a full `Transfer.t`.
