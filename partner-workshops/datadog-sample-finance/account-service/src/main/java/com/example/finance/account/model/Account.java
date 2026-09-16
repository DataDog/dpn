package com.example.finance.account.model;

import java.math.BigDecimal;
import java.time.Instant;

/**
 * Represents a financial account in the ledger.
 *
 * Finance domain tags to attach to spans/logs when handling this entity:
 *   account.tier    → retail | premium | corporate  (SLA-aware alerting)
 *   payment.currency → EUR | USD | GBP             (regulatory / regional analysis)
 *
 * WARNING — High cardinality: never use `id` or `ownerId` as a span tag directly.
 * Tag with bucketed / categorical values only.
 * Docs: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags
 */
public class Account {

    private String id;
    private String ownerId;
    private BigDecimal balance;
    private String currency;

    /**
     * Account tier drives SLA alerting in Datadog.
     * Valid values: retail | premium | corporate
     * Used as span tag: account.tier
     */
    private String tier;

    private Instant createdAt;

    public Account() {}

    public Account(String id, String ownerId, BigDecimal balance, String currency, String tier, Instant createdAt) {
        this.id = id;
        this.ownerId = ownerId;
        this.balance = balance;
        this.currency = currency;
        this.tier = tier;
        this.createdAt = createdAt;
    }

    public String getId() { return id; }
    public void setId(String id) { this.id = id; }

    public String getOwnerId() { return ownerId; }
    public void setOwnerId(String ownerId) { this.ownerId = ownerId; }

    public BigDecimal getBalance() { return balance; }
    public void setBalance(BigDecimal balance) { this.balance = balance; }

    public String getCurrency() { return currency; }
    public void setCurrency(String currency) { this.currency = currency; }

    public String getTier() { return tier; }
    public void setTier(String tier) { this.tier = tier; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
