package com.example.finance.batch.controller;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobParameters;
import org.springframework.batch.core.JobParametersBuilder;
import org.springframework.batch.core.launch.JobLauncher;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.Map;

/**
 * On-demand HTTP trigger for the Spring Batch jobs.
 *
 * <p>In production these jobs run on a nightly/monthly cron (see
 * {@code batch.reconciliation.cron} / {@code batch.statement.cron} in
 * application.yml, both disabled by default in this sample). For a live
 * demo — and so the traffic generator can produce a steady stream of
 * {@code batch.job} / {@code batch.step} spans for Data Jobs Monitoring
 * without waiting for a nightly cron — this controller launches a job
 * synchronously on request.
 *
 * <p>Each call uses a unique {@code run.timestamp} JobParameter so repeated
 * triggers always start a new JobInstance instead of failing with
 * {@code JobInstanceAlreadyCompleteException}.
 */
@RestController
public class BatchJobController {

    private static final Logger log = LoggerFactory.getLogger(BatchJobController.class);

    private final JobLauncher jobLauncher;
    private final Job reconciliationBatchJob;
    private final Job statementBatchJob;

    public BatchJobController(
            JobLauncher jobLauncher,
            @Qualifier("reconciliationBatchJob") Job reconciliationBatchJob,
            @Qualifier("statementBatchJob") Job statementBatchJob) {
        this.jobLauncher = jobLauncher;
        this.reconciliationBatchJob = reconciliationBatchJob;
        this.statementBatchJob = statementBatchJob;
    }

    /**
     * Triggers a reconciliation job run.
     * Mirrors ReconciliationJob#launchReconciliationJob, callable over HTTP
     * instead of waiting for the (disabled by default) nightly cron.
     */
    @PostMapping("/jobs/reconciliation")
    public ResponseEntity<Map<String, Object>> runReconciliation() {
        JobParameters params = new JobParametersBuilder()
                .addString("run.date", LocalDate.now().toString())
                .addLong("run.timestamp", System.currentTimeMillis())
                .toJobParameters();

        return launch(reconciliationBatchJob, params, "end-of-day-reconciliation");
    }

    /**
     * Triggers a statement-generation job run.
     * Mirrors StatementJob#launchStatementJob, callable over HTTP instead of
     * waiting for the (disabled by default) monthly cron.
     */
    @PostMapping("/jobs/statement")
    public ResponseEntity<Map<String, Object>> runStatement() {
        JobParameters params = new JobParametersBuilder()
                .addString("statement.period", LocalDate.now().toString())
                .addLong("run.timestamp", System.currentTimeMillis())
                .toJobParameters();

        return launch(statementBatchJob, params, "monthly-statement-generation");
    }

    private ResponseEntity<Map<String, Object>> launch(Job job, JobParameters params, String jobName) {
        try {
            log.info("event=batch.job.trigger.http job.name={}", jobName);
            JobExecution execution = jobLauncher.run(job, params);
            return ResponseEntity.accepted().body(Map.of(
                    "jobName", jobName,
                    "jobExecutionId", execution.getId(),
                    "status", execution.getStatus().toString()
            ));
        } catch (Exception e) {
            log.error("event=batch.job.trigger.http status=error job.name={} error_type={} message={}",
                    jobName, e.getClass().getSimpleName(), e.getMessage());
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                    "jobName", jobName,
                    "error", e.getClass().getSimpleName(),
                    "message", String.valueOf(e.getMessage())
            ));
        }
    }
}
