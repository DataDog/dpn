package com.example.finance.account.service;

// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
// Step 5 — Custom span via @Trace annotation:
//   import datadog.trace.api.Trace;
//
// Step 6 — DogStatsD custom metrics:
//   import com.timgroup.statsd.NonBlockingStatsDClientBuilder;
//   import com.timgroup.statsd.StatsDClient;
//
//   private static final StatsDClient statsd = new NonBlockingStatsDClientBuilder()
//       .prefix("finance")
//       .hostname(System.getenv().getOrDefault("DD_AGENT_HOST", "localhost"))
//       .port(8125)
//       .build();
//
//   Docs: https://docs.datadoghq.com/developers/dogstatsd/
//
// Step 10 — Data Streams Monitoring (DSM) for JMS production:
//   import datadog.trace.api.experimental.DataStreamsCheckpointer;
//
//   Docs: https://docs.datadoghq.com/data_streams/java/
// ─────────────────────────────────────────────────────────────────────

import com.example.finance.account.messaging.PaymentEventProducer;
import com.example.finance.account.model.Account;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.Collection;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class AccountService {

    private static final Logger log = LoggerFactory.getLogger(AccountService.class);

    // In-memory store — replace with a JPA repository backed by PostgreSQL.
    // When PostgreSQL is wired up, enable DBM (Step 9) on the Agent side.
    // Docs: https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/
    private final Map<String, Account> store = new ConcurrentHashMap<>();

    private final PaymentEventProducer paymentEventProducer;

    public AccountService(PaymentEventProducer paymentEventProducer) {
        this.paymentEventProducer = paymentEventProducer;

        // Seed data for local development
        var seed = new Account(
                "acc-001",
                "owner-42",
                new BigDecimal("12500.00"),
                "EUR",
                "premium",
                Instant.now()
        );
        store.put(seed.getId(), seed);
    }

    public Optional<Account> findById(String id) {
        return Optional.ofNullable(store.get(id));
    }

    public Collection<Account> findAll() {
        return store.values();
    }

    /**
     * Publishes a payment-initiated alert for the given account, resolving the
     * account's tier so the alert carries Finance-domain context.
     * Called by the gateway right after a finance-trader or finance-admin
     * successfully initiates a payment. Best-effort: notification dispatch
     * must never block or fail the payment itself.
     *
     * @return true if the account was found and the alert was published.
     */
    public boolean sendPaymentAlert(String accountId, String currency) {
        return findById(accountId)
                .map(account -> {
                    paymentEventProducer.sendPaymentAlert(accountId, currency, account.getTier());
                    return true;
                })
                .orElseGet(() -> {
                    log.warn("event=payment_alert status=account_not_found account_id={}", accountId);
                    return false;
                });
    }

    /**
     * Atomically applies a balance delta to an account.
     * Negative delta = debit (payment approved).
     * Positive delta = credit (refund or reversal).
     *
     * Thread-safe via ConcurrentHashMap#compute.
     */
    public Optional<Account> applyDelta(String id, BigDecimal delta) {
        Account[] result = { null };
        store.compute(id, (key, account) -> {
            if (account == null) return null;
            account.setBalance(account.getBalance().add(delta));
            result[0] = account;
            return account;
        });
        log.info("event=account.balance_updated account_tier={} currency={} delta={}",
                result[0] != null ? result[0].getTier() : "unknown",
                result[0] != null ? result[0].getCurrency() : "unknown",
                delta);
        return Optional.ofNullable(result[0]);
    }

    /**
     * Returns the current balance for the given account.
     *
     * This is a critical business operation. Instrument with:
     *   - A custom APM span (Step 5)
     *   - A DogStatsD gauge metric (Step 6)
     */
    // ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
    // Step 5 — Uncomment to create a dedicated APM span for balance check logic:
    // @Trace(operationName = "account.balance_check", resourceName = "AccountService#getBalance")
    //
    // Why: separates the DB read latency from the HTTP handler, visible as a child span in the trace.
    // ─────────────────────────────────────────────────────────────────────
    public BigDecimal getBalance(Account account) {
        log.info("event=account.balance_check account_tier={} currency={}",
                account.getTier(), account.getCurrency());

        BigDecimal balance = account.getBalance();

        // ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
        // Step 6 — Uncomment to emit a DogStatsD gauge for the account balance.
        // This enables real-time balance distribution in Datadog Metrics Explorer.
        //
        // NOTE: Sample this metric — do NOT emit on every request for large fleets.
        // The example below samples at 10% to reduce DogStatsD volume.
        //
        // WARNING — PII: never include raw account IDs in tags. Tag with tier/currency only.
        // Docs: https://docs.datadoghq.com/developers/dogstatsd/
        //
        // statsd.recordGaugeValue(
        //     "account.balance",
        //     balance.doubleValue(),
        //     0.1,   // sample rate — emit 10% of calls
        //     "account.tier:" + account.getTier(),
        //     "payment.currency:" + account.getCurrency(),
        //     "env:" + System.getenv().getOrDefault("DD_ENV", "unknown")
        // );
        // ─────────────────────────────────────────────────────────────────────

        return balance;
    }

    /**
     * Creates a new account and publishes an account-created event to the JMS broker.
     * The JMS publish triggers a fraud scoring pipeline (fraud.score.queue).
     *
     * DSM (Step 10) tracks the producer checkpoint on the JMS message in PaymentEventProducer.
     */
    // ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
    // Step 5 — Uncomment to trace account creation as a root business span:
    // @Trace(operationName = "account.create", resourceName = "AccountService#createAccount")
    // ─────────────────────────────────────────────────────────────────────
    public Account createAccount(Account request) {
        String id = "acc-" + UUID.randomUUID().toString().substring(0, 8);
        var account = new Account(
                id,
                request.getOwnerId(),
                request.getBalance() != null ? request.getBalance() : BigDecimal.ZERO,
                request.getCurrency() != null ? request.getCurrency() : "EUR",
                request.getTier() != null ? request.getTier() : "retail",
                Instant.now()
        );
        store.put(account.getId(), account);

        log.info("event=account.create status=persisted account_tier={} currency={}",
                account.getTier(), account.getCurrency());

        // ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
        // Step 6 — Uncomment to emit a counter each time an account is created:
        //
        // statsd.incrementCounter(
        //     "account.created",
        //     "account.tier:" + account.getTier(),
        //     "payment.currency:" + account.getCurrency()
        // );
        // ─────────────────────────────────────────────────────────────────────

        // Publish account-created event — fraud pipeline picks this up via JMS
        paymentEventProducer.sendAccountCreatedEvent(account);

        return account;
    }
}
