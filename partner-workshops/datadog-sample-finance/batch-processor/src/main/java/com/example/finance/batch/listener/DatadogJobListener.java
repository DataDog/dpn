package com.example.finance.batch.listener;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobExecutionListener;
import org.springframework.batch.core.StepExecution;
import org.springframework.stereotype.Component;

import io.opentracing.Scope;
import io.opentracing.Span;
import io.opentracing.Tracer;
import io.opentracing.util.GlobalTracer;

/**
 * Spring Batch {@link JobExecutionListener} that:
 * <ul>
 *   <li><b>Active (always on):</b> emits structured JSON log events at job
 *       start and completion for Log Management correlation.</li>
 *   <li><b>Active:</b> wraps each job execution in a dedicated "batch.job"
 *       APM span tagged with Finance-domain attributes for Data Jobs
 *       Monitoring and APM trace correlation.</li>
 * </ul>
 *
 * <p>Register this listener on each {@link org.springframework.batch.core.Job}
 * bean via {@code .listener(datadogJobListener)} in the job builder chain.
 *
 * <p><b>Why a span must be created here (not just tagged):</b> Spring Batch
 * jobs are launched either at application startup or via an on-demand
 * HTTP trigger (see {@code BatchJobController}) — neither path has an
 * ambient/active APM span the way an inbound HTTP request auto-creates one
 * for a web controller. Merely tagging {@code tracer.activeSpan()} (as an
 * earlier version of this listener did) is a no-op when there is no active
 * span, which is normally the case for a batch job — so no span, and no
 * Data Jobs Monitoring visibility, was ever produced. This listener instead
 * explicitly starts a span in {@link #beforeJob} and finishes it in
 * {@link #afterJob}, activating it for the job's duration so that the
 * auto-instrumented {@code batch.step} span (and any JDBC spans within it)
 * attach as children, giving a complete trace: batch.job → batch.step → db.query.
 */
@Component
public class DatadogJobListener implements JobExecutionListener {

    private static final Logger log = LoggerFactory.getLogger(DatadogJobListener.class);

    // ThreadLocal — Spring Batch may launch jobs from different threads
    // (e.g. the startup thread vs. an HTTP-triggered async JobLauncher), and
    // beforeJob/afterJob for a given execution always run on the same thread,
    // so ThreadLocal correctly isolates concurrent job runs from each other.
    private final ThreadLocal<Span> activeJobSpan = new ThreadLocal<>();
    private final ThreadLocal<Scope> activeJobScope = new ThreadLocal<>();

    // ── BEFORE JOB ────────────────────────────────────────────────────────────

    @Override
    public void beforeJob(JobExecution jobExecution) {
        String jobName = jobExecution.getJobInstance().getJobName();
        Long jobId = jobExecution.getJobId();

        // ── Active: structured log at job start (always enabled) ──────────────
        log.info("Batch job starting job.name={} job.id={} job.parameters={}",
                jobName,
                jobId,
                jobExecution.getJobParameters());

        Tracer tracer = GlobalTracer.get();
        Span span = tracer.buildSpan("batch.job")
                .withTag("resource.name", jobName)
                .start();
        span.setTag("job.name", jobName);
        span.setTag("job.id", jobId != null ? jobId.toString() : "unknown");
        span.setTag("job.env", System.getenv().getOrDefault("DD_ENV", "local"));
        String runDate = jobExecution.getJobParameters().getString("run.date");
        if (runDate != null) { span.setTag("job.run_date", runDate); }
        String statementPeriod = jobExecution.getJobParameters().getString("statement.period");
        if (statementPeriod != null) { span.setTag("job.statement_period", statementPeriod); }

        // Activate the span so child spans (batch.step, db.query, ...) created
        // during job execution on this thread attach underneath it.
        Scope scope = tracer.scopeManager().activate(span);
        activeJobSpan.set(span);
        activeJobScope.set(scope);
    }

    // ── AFTER JOB ─────────────────────────────────────────────────────────────

    @Override
    public void afterJob(JobExecution jobExecution) {
        String jobName = jobExecution.getJobInstance().getJobName();
        String status = jobExecution.getStatus().toString();

        // Sum write counts across all steps to get total records processed.
        // This mirrors what Data Jobs Monitoring surfaces as "records_processed".
        long totalRecordsProcessed = jobExecution.getStepExecutions().stream()
                .mapToLong(StepExecution::getWriteCount)
                .sum();

        long totalReadCount = jobExecution.getStepExecutions().stream()
                .mapToLong(StepExecution::getReadCount)
                .sum();

        long totalSkipCount = jobExecution.getStepExecutions().stream()
                .mapToLong(step -> step.getReadSkipCount()
                        + step.getProcessSkipCount()
                        + step.getWriteSkipCount())
                .sum();

        // ── Active: structured log at job completion (always enabled) ─────────
        log.info("Batch job completed job.name={} job.status={} records.read={} records.written={} records.skipped={}",
                jobName,
                status,
                totalReadCount,
                totalRecordsProcessed,
                totalSkipCount);

        if (jobExecution.getStatus().isUnsuccessful()) {
            jobExecution.getAllFailureExceptions().forEach(ex ->
                    log.error("Batch job failure job.name={} error={}",
                            jobName, ex.getMessage(), ex));
        }

        // ── Finance-domain outcome tags on the batch.job span ──────────────────
        // These power:
        //   - Data Jobs Monitoring alerts (e.g. alert when job.status = FAILED)
        //   - Monitors on job.records_processed < threshold (partial run detection)
        //   - Deployment Tracking: correlate failed runs with DD_VERSION
        Span span = activeJobSpan.get();
        if (span != null) {
            span.setTag("job.status", status);
            span.setTag("job.records_processed", totalRecordsProcessed);
            span.setTag("job.read_count", totalReadCount);
            span.setTag("job.skip_count", totalSkipCount);

            // Mark the span as an error if the job failed — surfaces in APM error tracking
            if (jobExecution.getStatus().isUnsuccessful()) {
                span.setTag("error", true);
                jobExecution.getAllFailureExceptions().stream().findFirst().ifPresent(ex -> {
                    span.setTag("error.type", ex.getClass().getName());
                    span.setTag("error.message", ex.getMessage());
                });
            }

            span.finish();
            activeJobSpan.remove();
        }

        Scope scope = activeJobScope.get();
        if (scope != null) {
            scope.close();
            activeJobScope.remove();
        }

        // ── CUSTOM METRIC: batch records processed ────────────────────────────
        // Note: finance.batch.records_processed metrics are generated in Datadog
        // from APM spans via Metrics from Spans (see deploy/terraform/datadog/main.tf).
        // No DogStatsD client needed in this service.
    }
}
