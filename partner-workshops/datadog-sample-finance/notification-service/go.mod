module github.com/example/notification-service

go 1.23

require github.com/go-stomp/stomp/v3 v3.0.5

// ── DATADOG INSTRUMENTATION — APM + DSM + PROFILER DEPENDENCIES ──────────────
// Uncomment the lines below when enabling Datadog observability layers.
// Run `go mod tidy` after uncommenting to resolve transitive dependencies.
//
// Docs:
//   APM tracer:          https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/go/
//   Data Streams (DSM):  https://docs.datadoghq.com/data_streams/go/
//   Continuous Profiler: https://docs.datadoghq.com/profiler/enabling/go/
//   DogStatsD client:    https://docs.datadoghq.com/developers/dogstatsd/?tab=go
//   Orchestrion (auto):  https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/go/
//
require (
	github.com/DataDog/dd-trace-go/v2 v2.0.0
	github.com/DataDog/datadog-go/v5 v5.5.0
)
//
// NOTE on Orchestrion:
//   Orchestrion instruments this service at compile time without any import changes.
//   Install it as a build tool — do NOT add it to `require` here:
//     go install github.com/DataDog/orchestrion@latest
//     orchestrion go build ./...
//   This is the preferred approach for Go services in production.
// ─────────────────────────────────────────────────────────────────────────────
