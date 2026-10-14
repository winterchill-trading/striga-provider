# Mapping: banking-provider to Striga

How each `Provider.S` and `Sandbox.S` operation is carried out with the Striga v1 API
(through `striga-client`), how Striga's webhooks and ledger entries become `Event.t`, and
what has no Striga counterpart. Paths are relative to `/api/v1`.

## Ids

| Ours                     | Striga                                   | Where the link lives                    |
| ------------------------ | ---------------------------------------- | --------------------------------------- |
| `Customer_ref.t`         | user id                                  | the ref itself                          |
| `Kyc_core.Customer_id.t` | none (Striga has no external id field)   | `Store.find_customer`, plus a `+<id>` e-mail tag so a lost store can be rebuilt with `get-by-email` |
| `Account_ref.t`          | `<user id>/<account id>` (`Refs`)        | the ref itself                          |
| `Transfer.Id.t`          | challenge id, then transaction id        | `Store.Transfer_record`                 |
| `Sca.Id.t`               | `striga:<challenge id>`                  | `Store.Challenge_record`                |
| `Swap.Id.t`              | none until executed (`swp-<uuid>`)       | `Store.Swap_record`                     |
| card `request_id`        | none                                     | `Store.find_card_request`               |
| `Card_id.t`              | card id                                  | the id itself                           |
| `Event_id.t`             | derived from Striga data (see Events)    | none: both poll and webhook derive it   |

Striga takes no idempotency keys, so every create is made idempotent by looking up the
store first. A `Store_pg` in the consuming service keeps these across restarts.

## Operations

| `Provider.S`            | Striga endpoint(s)                                                       | Notes |
| ----------------------- | ------------------------------------------------------------------------ | ----- |
| `name`                  | none                                                                     | `"striga"` |
| `create_customer`       | `POST /user/get-by-email` (a lost response may have created the user), else `POST /user/create`; a known customer: `GET /user/{id}` | e-mail made unique per customer id; mobile split into calling code and number |
| `update_customer`       | `PATCH /user/update`                                                     | |
| `start_verification`    | Email: `POST /user/resend-email`; Mobile: `POST /user/resend-sms`; document, liveness, address, source of funds: `POST /user/kyc/start` with the tier | returns `Code_sent` or `Hosted` (verification link, else the SDK token) |
| `complete_verification` | `POST /user/verify-email`, `POST /user/verify-mobile`                    | hosted steps are decided at Striga; this reads `GET /user/kyc/{id}` |
| `kyc_status`            | `GET /user/kyc/{id}`                                                     | publishes the change as events |
| `open_account`          | `GET /user/{id}` + `POST /wallets/get/all` (polled)                     | Striga opens one account per enabled currency itself after KYC; opening is waiting up to `provisioning_timeout` |
| `accounts`              | `GET /user/{id}`, `POST /wallets/get/all`                                | currencies `money` does not know are skipped |
| `balance`               | `POST /wallets/get/account`                                              | `posted = available`, no holds (see `Account_map`) |
| `enrich_account`        | `POST /wallets/account/enrich`, `POST /wallets/get/account`              | IBAN for EUR, deposit addresses for crypto |
| `statement`             | `POST /wallets/get/account`, `POST /wallets/get/account/statement` (paged) | entries mapped by `Tx_map` |
| `quote_fee`             | none                                                                     | SEPA and intraledger: zero (the application charges none); on-chain and Lightning: error (Striga estimates only at initiation) |
| `initiate_transfer`     | SEPA: `POST /wallets/send/initiate/bank`; intraledger: `POST /wallets/send/intra/initiate`; on-chain: `POST /wallets/whitelist-address` then `POST /wallets/send/initiate/onchain`; Lightning: `POST /wallets/send/initiate/lightning` | always returns a challenge; the fee is the initiation's `feeEstimate` |
| `transfer`              | `POST /wallets/account/get-transactions-by-id`, else the statement       | |
| `cancel_transfer`       | none                                                                     | only before the code is confirmed: the initiation lapses at Striga |
| `confirm_sca`           | transfers and swaps: `POST /wallets/transaction/confirm`; card details: `POST /card/confirm-consent` | `41009`/`41010` wrong code; `61004`/`31090` insufficient funds becomes `Failed Insufficient_funds` |
| `quote_swap`            | `POST /wallets/get/account`, `POST /trade/rates`                         | quote held locally (Striga has no quote id) |
| `execute_swap`          | `POST /wallets/swap`, then the challenge                                 | |
| `issue_virtual_card`    | `GET /user/{id}`, `POST /card/create` (virtual), `GET /card/{id}`       | the create answer lacks fields, so the card is read back |
| `card`, `cards`         | `GET /card/{id}`, `POST /card/get-all`                                   | |
| `set_card_status`       | Frozen: `POST /card/block`; Active: `POST /card/unblock`; Destroyed: `POST /card/burn` | Blocked, Requested, Expired cannot be set |
| `set_card_limits`       | `PATCH /card/limits`, `PATCH /card/security`                             | EUR whole units only |
| `card_details_token`    | none server-side; `card_consent_started` + `confirm_sca` (`/card/confirm-consent`) | the consent starts in Striga's browser component |
| `create_standing_order`, `cancel_standing_order` | none                            | Striga standing orders convert deposits; they are not scheduled payments |
| `events`                | polling `GET /user/kyc/{id}`, the account statements, `POST /card/statement` | only while subscribed |
| `ingest_webhook`        | none (verifies with `Webhook.verify_and_parse`)                          | |

| `Sandbox.S`                 | Striga endpoint(s)                                                   | Notes |
| --------------------------- | -------------------------------------------------------------------- | ----- |
| `simulate_deposit`          | `PATCH /simulate/accounts/deposit`, then the statement (polled)      | EUR by SEPA only; found again by its memo, as the simulator returns no id |
| `simulate_kyc_decision`     | `POST /user/verify-email`, `/user/verify-mobile` (code `123456`), `POST /user/kyc/start`, `PATCH /simulate/user/kyc` | `Approve` APPROVED, `Reject` REJECTED_FINAL, `Request_resubmission` REJECTED with labels |
| `simulate_card_auth`        | `POST /simulate/card/authorization`, then `GET /card/{id}`, `POST /card/statement` | the simulator says only APPROVED/DECLINED; the code comes from the card's status or `declineDetails` |
| `simulate_transfer_outcome` | `PATCH /simulate/sepa`                                               | SEPA payouts only: `Settled` completes, `Rejected`/`Failed`/`Returned` fail |
| `ping`                      | `POST /simulate/webhook/ping`                                        | publishes the `Ping` itself: Striga answers 200 whether or not the delivery arrived |

Every `Sandbox.S` call refuses to run against a host other than the sandbox.

## Events

Webhook channel (by path, or guessed from the body when the receiving server does not
pass `x-webhook-path`) and statement entry to `Event.Kind.t`:

| Striga                                   | Event                                         | Event id |
| ---------------------------------------- | --------------------------------------------- | -------- |
| `/kyc` (and each KYC poll)               | `Kyc_step` per changed step, then `Kyc` transitions | `kyc:<user>:step:<Step>:<State>`, `kyc:<user>:<From>:<Transition>` |
| `/tx` `*_INITIATED` (confirmed)          | `Transfer Submitted`                          | `tx:<id>:<txType>` |
| `/tx` `ON_CHAIN_WITHDRAWAL_PENDING`      | `Transfer Pending`                            | same |
| `/tx` `SEPA_PAYOUT_COMPLETED`, `LN_OUTGOING_CONFIRMED`, `ON_CHAIN_WITHDRAWAL_CONFIRMED`, `INTRA_LEDGER_SEND` (debit) | `Transfer Settled` | same |
| `/tx` `SEPA_PAYOUT_DENIED`               | `Transfer (Rejected MS03)`                    | same |
| `/tx` `SEPA_PAYOUT_REVERTED`             | `Transfer (Returned MS03)`                    | same |
| `/tx` other `*_FAILED`, `*_DENIED`       | `Transfer (Failed Provider_error)`            | same |
| `/tx` `SEPA_PAYIN_COMPLETED`, `LN_INCOMING_CONFIRMED`, `ON_CHAIN_DEPOSIT_CONFIRMED`, `INTRA_LEDGER_SEND` (credit) | `Incoming_transfer` (settled) | same |
| `/tx` `ON_CHAIN_DEPOSIT_PENDING`         | nothing (no amount on the entry)              | |
| `/tx` `SEPA_PAYIN_DENIED`, `_FAILED`, `_REVERTED` | `Transfer` Rejected / Returned on the deposit | same |
| `/tx` card entries, card statement `CARD_AUTHORIZATION` | `Card Auth_advice` approved   | `card:<related id>:<type>` |
| `CARD_AUTHORIZATION_DECLINED`            | `Card Auth_advice` declined (code from `declineDetails`) | same |
| `CARD_AUTHORIZATION_REVERSAL`, `_RELEASE` | `Card Reversal`                              | same |
| `CARD_AUTHORIZATION_SETTLEMENT_CONFIRMED` | `Card Clearing`                              | same |
| `/card/watch`, `set_card_status`         | `Card Status_changed`                         | `card:<id>:status:<Status>` |
| `/ping`                                  | `Ping`                                        | `ping:<md5 of body>` |
| confirm wrong-balance answer             | `Transfer (Failed Insufficient_funds)`        | `failed:<transfer id>` |
| `cancel_transfer`                        | `Transfer Cancelled`                          | `cancel:<transfer id>` |
| swap confirmed / refused                 | `Swap_executed` / `Swap_failed`               | `tx:<id>:<txType>` or `swap:<id>`, `swap-failed:<id>` |

Striga sends no ISO 20022 reason with a denial or a revert; `MS03` stands in for it.

## Currencies and networks

| Striga ticker | `Money.Currency`     | Striga unit       | Ours   |
| ------------- | -------------------- | ----------------- | ------ |
| EUR           | `eur`                | cents (2)         | 2      |
| BTC           | `btc`                | satoshis (8)      | 8      |
| ETH           | `eth` (wide)         | wei (18)          | 18     |
| USDC, USDT    | `usdc`, `usdt` (untagged) | cents (2)    | 6 (rescaled; a sub-cent amount is refused) |
| BNB, POL, SOL | registered on first use | per balance unit | per Striga |

Lightning moves the BTC account; `btc_lightning` has no Striga ticker. Withdrawal
networks: Bitcoin and Bitcoin testnet `BTC`, Ethereum `ETH`, Polygon `POLYGON`, Solana
`SOL`; Tron is refused. Sandbox deposit addresses are on testnet3 (`tb1...`) and Sepolia;
an address on a network payments-core does not model (BSC) is left out.

## KYC tiers

| kyc-core step                  | Striga                  |
| ------------------------------ | ----------------------- |
| `Email`, `Mobile`              | tier 0 (`emailVerified`, `mobileVerified`) |
| `Identity_document`, `Liveness` | tier 1 (document and selfie, hosted)  |
| `Address_proof`                | tier 2                  |
| `Source_of_funds`              | tier 3                  |

| Striga status                               | `Kyc_core.Status.t` |
| ------------------------------------------- | ------------------- |
| `NOT_STARTED`                               | `Created`           |
| `INITIATED`, `PENDING_REVIEW`, `ON_HOLD`    | `Verifying`         |
| `APPROVED` (any tier from 1 up)             | `Approved`          |
| `REJECTED`                                  | `Needs_resubmission` (fields from the labels) |
| `REJECTED_FINAL`                            | `Rejected`          |

A customer approved at tier 1 stays `Approved` when an upgrade to tier 2 is rejected
(Striga's top-level status then says `REJECTED`); the failed step shows it.

## SCA

| Striga verification method | `Sca.Kind.t` |
| -------------------------- | ------------ |
| `TOTP`                     | `Totp`       |
| `PASSKEY`                  | `Passkey`    |
| `SMS`, other, none         | `Otp`        |

Striga allows five attempts per challenge without reporting how many remain, so
`attempts_left` is counted locally. Each confirmation carries the end user's IP, which
`Provider.S` does not; `Config.end_user_ip` is sent.

## Cards

Statuses: `CREATED`, `DISPATCHED` to `Requested`; `ACTIVE`, `ACTIVATED` to `Active`;
`BLOCKED` to `Frozen` (reversible); `CLOSED` to `Destroyed`; `EXPIRED` to `Expired`;
anything else to `Blocked`. Limits are whole euros: `transactionPurchase`,
`dailyPurchase`, `monthlyPurchase`, `dailyWithdrawal`, and the online, contactless and ATM
toggles. The PAN component's `cardAuthToken` (from `/card/confirm-consent`) becomes a
`Pan_display_token.t` valid 24 hours.

## Gaps

- No idempotency keys or external ids at Striga: the store is load-bearing.
- Standing orders: Striga's are deposit conversions, not dated payments.
- Fee quotes for on-chain and Lightning: only known once initiated.
- Card ATM counts, MCC and country block lists, non-EUR limits, the `Blocked`,
  `Requested` and `Expired` statuses as targets.
- `card_details_token` needs Striga's browser component to start the consent.
- Sandbox: deposits only in EUR by SEPA; outcomes only for SEPA payouts; no crypto funding.
