(lang dune 3.17)

(name striga-provider)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/striga-provider))

(package
 (name striga-provider)
 (synopsis "banking-provider's Provider.S implemented over the Striga API")
 (description
  "Adapter from the provider-neutral banking-provider interface to striga-client: customers and KYC, EUR and crypto accounts, SEPA, Lightning, on-chain and intraledger transfers with SCA, swaps, virtual cards, statements and webhooks normalized into banking-provider events. Sandbox by default.")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_kernel
  ppx_jane
  yojson
  zarith
  money
  ledger
  kyc-core
  payments-core
  card-core
  banking-provider
  striga-client))
