package com.example.finance.batch.job;

import com.example.finance.batch.listener.DatadogJobListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.JobParameters;
import org.springframework.batch.core.JobParametersBuilder;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.launch.JobLauncher;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.item.ItemProcessor;
import org.springframework.batch.item.ItemWriter;
import org.springframework.batch.item.database.JdbcCursorItemReader;
import org.springframework.batch.item.database.builder.JdbcCursorItemReaderBuilder;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.Map;

// ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────────
// No imports needed here for basic APM — the Java agent auto-instruments
// Spring Batch Job and Step execution automatically.
//
// For Data Jobs Monitoring (Step 11) and custom span tagging, see:
//   DatadogJobListener.java — beforeJob/afterJob span tag injection
//   ReconciliationStepConfig.java — @Trace on the tasklet
//
// Docs: https://docs.datadoghq.com/data_jobs/java/
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Spring Batch configuration for the nightly End-of-Day Reconciliation Job.
 *
 * <p>Reads all settled transactions from the {@code transactions} table,
 * compares against an external ledger stub, and writes a discrepancy report.
 *
 * <p>Scheduled to run nightly at 23:00 UTC (configurable in application.yml).
 * JobParameters include {@code run.date} to make each nightly run uniquely
 * identifiable — essential for the Data Jobs Monitoring run history timeline.
 *
 * <p>Chunk size: 100 records — tune based on memory and DB throughput.
 *
 * Finance span tags applied (when Datadog agent is active):
 * <ul>
 *   <li>{@code job.name} = "end-of-day-reconciliation"</li>
 *   <li>{@code job.batch_size} = 100</li>
 *   <li>{@code job.status} = "completed" | "failed" | "partial"</li>
 * </ul>
 */
@Configuration
public class ReconciliationJob {

    private static final Logger log = LoggerFactory.getLogger(ReconciliationJob.class);

    private static final String JOB_NAME = "end-of-day-reconciliation";
    private static final int CHUNK_SIZE = 100;

    @Autowired
    private JobLauncher jobLauncher;

    @Autowired
    private JobRepository jobRepository;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Autowired
    private DataSource dataSource;

    @Autowired
    private DatadogJobListener datadogJobListener;

    // ── SCHEDULER ─────────────────────────────────────────────────────────────
    // Uncomment the @Scheduled annotation to enable nightly execution.
    // Cron expression: "0 0 23 * * *" = every day at 23:00 UTC.
    // Requires @EnableScheduling on BatchProcessorApplication.
    // Set spring.batch.job.enabled=false to prevent auto-launch on startup.
    //
    // @Scheduled(cron = "${batch.reconciliation.cron:0 0 23 * * *}")
    // ─────────────────────────────────────────────────────────────────────────
    public void launchReconciliationJob() throws Exception {
        JobParameters params = new JobParametersBuilder()
                .addString("run.date", LocalDate.now().toString())
                .addLong("run.timestamp", System.currentTimeMillis()) // ensures uniqueness
                .toJobParameters();

        log.info("Launching reconciliation job for date={}", LocalDate.now());
        jobLauncher.run(reconciliationBatchJob(), params);
    }

    @Bean
    public Job reconciliationBatchJob() {
        return new JobBuilder(JOB_NAME, jobRepository)
                .listener(datadogJobListener)
                .start(reconciliationStep())
                .build();
    }

    // ── STEP ─────────────────────────────────────────────────────────────────
    // Chunk-oriented step: reader → processor → writer, 100 records per commit.
    // Auto-instrumented by dd-java-agent as a 'batch.step' span when the agent
    // is attached. No code changes are needed here to see the step in APM.
    @Bean
    public Step reconciliationStep() {
        return new StepBuilder("reconciliation-step", jobRepository)
                .<Map<String, Object>, Map<String, Object>>chunk(CHUNK_SIZE, transactionManager)
                .reader(reconciliationItemReader())
                .processor(reconciliationItemProcessor())
                .writer(reconciliationItemWriter())
                .build();
    }

    // ── ITEM READER ───────────────────────────────────────────────────────────
    // JdbcCursorItemReader: streams rows from the transactions table.
    // Cursor-based streaming avoids loading all rows into memory — important
    // for high-volume end-of-day runs processing thousands of transactions.
    //
    // ⚠ DATADOG DBM NOTE: When DBM is enabled (Step 9), every JDBC query here
    // will appear in Databases > Query Samples with explain plans attached.
    // Ensure the WHERE clause uses indexed columns (status, settled_at) to
    // avoid full-table scans surfaced by DBM's slow query detection.
    // ─────────────────────────────────────────────────────────────────────────
    // ── WORKSHOP SCENARIO 2 (nightly reconciliation fails silently) ─────────────
    // RECONCILIATION_SCENARIO_ENABLED defaults to false (no behavior change).
    // Set to true via `make scenario-2` to simulate a data integrity issue that
    // silently excludes a settlement currency from the reconciliation read
    // (narrative: the query was never updated after JPY settlements went live
    // — a currency corridor is silently dropped forever, not a one-off blip).
    // The job still completes successfully (no exception thrown), but
    // job.records_processed (finance.batch.records_processed span metric)
    // drops by roughly a fifth (payments.js/generate-traffic.py pick a
    // currency uniformly at random from 5 options, so excluding one drops
    // ~20% of rows — a real, measurable difference, not a rounding artifact).
    // Nothing here suppresses Datadog telemetry: the anomaly is fully visible
    // in Data Jobs Monitoring, it's just that no monitor exists yet to alert
    // on it (see the reconciliation_low_record_count monitor added to
    // deploy/terraform/datadog/main.tf). Reset via `make unscenario-2`.
    //
    // BUG FIX: this used to filter `account_id NOT LIKE 'ACC-CORP%'`, but no
    // account ID in this app ever matches that pattern (real IDs are
    // acc-<8 hex chars>, generated in account-service) — the scenario was a
    // complete no-op, records_processed never actually dropped. Filtering on
    // currency instead works because currency genuinely varies per row.
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public JdbcCursorItemReader<Map<String, Object>> reconciliationItemReader() {
        boolean scenarioEnabled = Boolean.parseBoolean(
                System.getenv().getOrDefault("RECONCILIATION_SCENARIO_ENABLED", "false"));
        String whereClause = "status = 'settled' AND settled_at >= CURRENT_DATE - INTERVAL '1 day'"
                + (scenarioEnabled ? " AND currency <> 'JPY'" : "");

        return new JdbcCursorItemReaderBuilder<Map<String, Object>>()
                .name("reconciliationItemReader")
                .dataSource(dataSource)
                .sql("""
                        SELECT id, account_id, amount, currency, status, settled_at
                        FROM transactions
                        WHERE %s
                        ORDER BY settled_at ASC
                        """.formatted(whereClause))
                .rowMapper((rs, rowNum) -> {
                    Map<String, Object> row = new HashMap<>();
                    row.put("id", rs.getString("id"));
                    row.put("account_id", rs.getString("account_id"));
                    row.put("amount", rs.getBigDecimal("amount"));
                    row.put("currency", rs.getString("currency"));
                    row.put("status", rs.getString("status"));
                    row.put("settled_at", rs.getTimestamp("settled_at"));
                    return row;
                })
                .build();
    }

    // ── ITEM PROCESSOR ────────────────────────────────────────────────────────
    // Stub: compares each transaction row against an external ledger entry.
    // In production, this would call an external reconciliation API.
    //
    // ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────
    // Wrap the external ledger call in a manual span to capture its latency
    // separately from the overall step. See ReconciliationStepConfig for the
    // @Trace annotation pattern.
    //
    // import datadog.trace.api.Trace;
    //
    // @Trace(operationName = "ledger.reconcile", resourceName = "external-ledger")
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public ItemProcessor<Map<String, Object>, Map<String, Object>> reconciliationItemProcessor() {
        return item -> {
            // Stub: flag discrepancies — in production, compare with external ledger
            log.debug("Processing transaction id={} amount={} currency={}",
                    item.get("id"), item.get("amount"), item.get("currency"));

            // ⚠ HIGH-CARDINALITY WARNING: Never tag with raw transaction.id in spans.
            // Use job.name and job.batch_size for cardinality-safe aggregation.
            // Docs: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags

            item.put("reconciled", true);
            item.put("discrepancy", false);
            return item;
        };
    }

    // ── ITEM WRITER ───────────────────────────────────────────────────────────
    // Stub: writes reconciliation results to the discrepancy_report table.
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public ItemWriter<Map<String, Object>> reconciliationItemWriter() {
        return chunk -> {
            log.info("Writing {} reconciliation records to discrepancy_report", chunk.size());
            // In production: batch INSERT into discrepancy_report table via JdbcBatchItemWriter
            // or flag and escalate discrepancies via the notification-service queue.
        };
    }
}
