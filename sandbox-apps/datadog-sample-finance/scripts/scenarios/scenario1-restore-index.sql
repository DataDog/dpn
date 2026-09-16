-- ── WORKSHOP SCENARIO 1 (payments slow, missing index) ──────────────────
-- Applied by `make unscenario-1`. Restores the index dropped by
-- scenario1-drop-index.sql, identical to the definition in
-- deploy/kubernetes/base/infrastructure/postgres-init.yaml.
CREATE INDEX IF NOT EXISTS idx_transactions_account_id
    ON transactions (account_id);
