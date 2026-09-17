-- ── WORKSHOP SCENARIO 1 (payments slow, missing index) ──────────────────
-- Applied by `make scenario-1`. Drops the index that transaction-service's
-- ledger.velocity_check query (transaction-service/src/services/ledger.js)
-- relies on, turning that per-payment SELECT into a full table scan on the
-- ledger. Reversed by scenario1-restore-index.sql (`make unscenario-1`).
DROP INDEX IF EXISTS idx_transactions_account_id;
