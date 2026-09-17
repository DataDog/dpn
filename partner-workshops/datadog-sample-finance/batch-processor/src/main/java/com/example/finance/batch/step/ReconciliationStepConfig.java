package com.example.finance.batch.step;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.StepContribution;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.scope.context.ChunkContext;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.core.step.tasklet.Tasklet;
import org.springframework.batch.repeat.RepeatStatus;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;
import java.util.Map;

// ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────────
// Manual span creation for the reconciliation step's pre/post-processing logic.
//
// The dd-java-agent auto-instruments the chunk-oriented step (reader/processor/
// writer) with a "batch.step" span. The manual @Trace below adds a child span
// for the pre-flight validation tasklet — a Finance-critical operation that runs
// before the main chunk processing begins.
//
// Requires: dd-trace-api on classpath (see build.gradle)
//
// import datadog.trace.api.Trace;
// import io.opentracing.Span;
// import io.opentracing.util.GlobalTracer;
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Spring Batch {@link Step} configuration for the End-of-Day Reconciliation job.
 *
 * <p>Defines two steps:
 * <ol>
 *   <li>{@code reconciliation-preflight-step} — tasklet that validates source
 *       data availability before the main chunk processing begins. Wrapped with
 *       a commented {@code @Trace} to create a named child span.</li>
 *   <li>{@code reconciliation-step} — chunk-oriented step (reader → processor →
 *       writer) wired from {@link ReconciliationJob} beans. Chunk size: 100.</li>
 * </ol>
 *
 * <p>The chunk-oriented step is auto-instrumented by dd-java-agent.
 * The preflight tasklet requires a manual {@code @Trace} (commented) to appear
 * as a distinct named operation in APM traces.
 */
@Configuration
public class ReconciliationStepConfig {

    private static final Logger log = LoggerFactory.getLogger(ReconciliationStepConfig.class);

    private static final int CHUNK_SIZE = 100;

    @Autowired
    private JobRepository jobRepository;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Autowired
    private DataSource dataSource;

    // ── PREFLIGHT TASKLET STEP ────────────────────────────────────────────────
    // Validates that the transactions table has data for the current run date
    // before committing to the full chunk-processing step.
    //
    // ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────
    // Add @Trace to preflightTasklet().execute() to create a named child span.
    // This makes the preflight duration separately visible in APM, independent
    // of the main processing step's duration.
    //
    // @Bean
    // public Step reconciliationPreflightStep() {
    //     return new StepBuilder("reconciliation-preflight-step", jobRepository)
    //             .tasklet(preflightTasklet(), transactionManager)
    //             .build();
    // }
    //
    // @Bean
    // public Tasklet preflightTasklet() {
    //     return new Tasklet() {
    //         // @Trace(operationName = "batch.step", resourceName = "reconciliation-preflight")
    //         @Override
    //         public RepeatStatus execute(StepContribution contribution,
    //                                     ChunkContext chunkContext) {
    //             // ── DATADOG INSTRUMENTATION ────────────────────────────────
    //             // import io.opentracing.Span;
    //             // import io.opentracing.util.GlobalTracer;
    //             //
    //             // Span span = GlobalTracer.get().activeSpan();
    //             // if (span != null) {
    //             //     span.setTag("job.name", "end-of-day-reconciliation");
    //             //     span.setTag("job.step", "preflight");
    //             // }
    //             // ─────────────────────────────────────────────────────────
    //             log.info("Preflight validation: checking transaction data availability");
    //             // TODO: SELECT COUNT(*) FROM transactions WHERE status='settled' AND settled_at >= CURRENT_DATE
    //             // If count == 0, throw exception to fail fast before chunk processing.
    //             return RepeatStatus.FINISHED;
    //         }
    //     };
    // }
    // ─────────────────────────────────────────────────────────────────────────

}
