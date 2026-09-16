package com.example.finance.batch;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

// ── DATADOG INSTRUMENTATION ───────────────────────────────────────────────────
// The Datadog Java agent is loaded via the JVM -javaagent flag, NOT via a code
// import. No changes are needed in this file to enable APM auto-instrumentation.
//
// See: JAVA_TOOL_OPTIONS in Dockerfile and .env.example for agent flags.
// Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/
//
// When the agent is attached, Spring Batch steps, JDBC calls, and scheduler
// invocations are all auto-instrumented with zero code changes here.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Finance Sample App — Batch Processor
 *
 * <p>Runs two scheduled Spring Batch jobs:
 * <ul>
 *   <li>{@code ReconciliationJob} — nightly end-of-day settlement reconciliation</li>
 *   <li>{@code StatementJob}      — monthly account statement generation</li>
 * </ul>
 *
 * <p>All Datadog instrumentation is commented out. The app runs cleanly with
 * no {@code DD_*} environment variables set. Follow the Learning Progression
 * in README.md to progressively enable observability layers.
 */
@SpringBootApplication
@EnableScheduling
public class BatchProcessorApplication {

    public static void main(String[] args) {
        // Spring Batch auto-runs jobs on startup by default.
        // Set spring.batch.job.enabled=false in application.yml to disable
        // and rely on the @Scheduled triggers instead.
        SpringApplication.run(BatchProcessorApplication.class, args);
    }
}
