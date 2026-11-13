# Authentik issuer slash

- Finding: Authentik 2026.8.5's per-provider issuer for Forgeledger is
  `https://auth.stealthdragonland.net/application/o/forgeledger/`,
  trailing slash included, and that is the discovery `issuer`.
  Forgeledger cbf9c5d strips trailing slashes from `FL_OIDC_ISSUER`
  and then compares that trimmed value to the ID token `iss`.
- Evidence: A discovery GET on 2026-11-12 returned that issuer.
  `git grep` of cbf9c5d `crates/fl-api/src/sso.rs` shows
  `trim_end_matches('/')` at line 113, and `check_claims` compares
  `iss` to the stored issuer.
- Scope: `manifests/01_infrastructure/authentik/` and
  `manifests/productivity/forgeledger/20_deployment.yml`.
  The trim lives in forgeledger, not in this repo.
- Owner: forgeledger sign-in.
- Review trigger: a new Forgeledger image that keeps the issuer
  string, or an Authentik issuer that does not end in a slash.
