package com.example.finance.account;

// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
// APM for Java is agent-based — there is NO code import required.
// Instrumentation is injected at JVM startup via the -javaagent flag.
//
// Step 3 — Enable APM tracing:
//   Add the following JVM flag when launching this service:
//
//   -javaagent:/dd-java-agent.jar
//
//   In Docker / docker-compose, set JAVA_TOOL_OPTIONS in the environment:
//     JAVA_TOOL_OPTIONS: "-javaagent:/dd-java-agent.jar -Ddd.service=account-service -Ddd.env=staging -Ddd.version=1.0.0"
//
//   The agent auto-instruments:
//     - Spring MVC (HTTP spans)
//     - JDBC / PostgreSQL (db.query spans)
//     - Spring JMS / ActiveMQ Artemis (jms.produce / jms.consume spans)
//     - Logback MDC injection (dd.trace_id, dd.span_id in every log line)
//
//   Required env vars: DD_API_KEY (Agent side), DD_ENV, DD_SERVICE, DD_VERSION
//   Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/java/
// ─────────────────────────────────────────────────────────────────────

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class AccountServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(AccountServiceApplication.class, args);
    }
}
