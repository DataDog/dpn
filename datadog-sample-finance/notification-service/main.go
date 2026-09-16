package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
	// Uncomment to enable APM tracing + Continuous Profiling for this
	// service (tracer.Start() / profiler.Start() below).
	// Requires: DD_ENV, DD_SERVICE, DD_VERSION, DD_AGENT_HOST env vars.
	// Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/go/
	//       https://docs.datadoghq.com/profiler/enabling/go/
	//
	// "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
	// "github.com/DataDog/dd-trace-go/v2/profiler"
	// ─────────────────────────────────────────────────────────────────────
	"github.com/go-stomp/stomp/v3"
)

const (
	alertQueue       = "/queue/alert.queue"
	defaultBrokerURL = "stomp://localhost:61613"
)

// AlertMessage represents the payload received on alert.queue.
type AlertMessage struct {
	EventType     string `json:"event_type"` // e.g. "fraud_detected", "payment_failed"
	AccountID     string `json:"account_id"`
	Channel       string `json:"channel"`        // "email" or "sms"
	CorrelationID string `json:"correlation_id"` // jms.correlation_id — business-level trace key
	// ⚠️  HIGH CARDINALITY WARNING: do NOT log or tag raw account numbers, IBANs,
	// card numbers, or transaction amounts. Tag with IDs only.
	// Ref: https://docs.datadoghq.com/tagging/assigning_tags/#defining-tags
}

// NOTE: no DogStatsD client. finance.notification.sent / .dispatch_time are
// generated from the alert.send span (span-based metrics in
// deploy/terraform/datadog), keyed off @notification.channel / @notification.event_type.

func main() {
	// ── Structured JSON logging (stdlib log/slog) ─────────────────────────────
	// All log lines are JSON so Datadog Log Management can parse them without a
	// custom pipeline processor. Unlike Java (MDC) or Python (ddtrace.contrib.logging),
	// Go's dd-trace-go does NOT hook log/slog automatically — there is no
	// framework-level log injection for Go. The "dd.trace_id" / "dd.span_id"
	// fields must be added manually to each log call from the active span's
	// context (see the log-injection block in processMessage / sendNotification,
	// enabled by 'make tags').
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
	// Uncomment to enable APM tracing for this service.
	// Requires: DD_ENV, DD_SERVICE, DD_VERSION, DD_AGENT_HOST env vars.
	// Docs: https://docs.datadoghq.com/tracing/trace_collection/dd_libraries/go/
	//
	// tracer.Start(
	// 	tracer.WithService(getEnv("DD_SERVICE", "notification-service")),
	// 	tracer.WithEnv(getEnv("DD_ENV", "local")),
	// 	tracer.WithServiceVersion(getEnv("DD_VERSION", "dev")),
	// 	tracer.WithAgentAddr(getEnv("DD_AGENT_HOST", "datadog-agent")+":8126"),
	// 	tracer.WithRuntimeMetrics(),
	// )
	// defer tracer.Stop()
	// ─────────────────────────────────────────────────────────────────────

	// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
	// Uncomment to enable Continuous Profiling for this service.
	// Docs: https://docs.datadoghq.com/profiler/enabling/go/
	//
	// if err := profiler.Start(
	// 	profiler.WithService(getEnv("DD_SERVICE", "notification-service")),
	// 	profiler.WithEnv(getEnv("DD_ENV", "staging")),
	// 	profiler.WithVersion(getEnv("DD_VERSION", "dev")),
	// 	profiler.WithProfileTypes(
	// 		profiler.CPUProfile,
	// 		profiler.HeapProfile,
	// 		profiler.GoroutineProfile,
	// 	),
	// ); err != nil {
	// 	slog.Error("profiler failed to start", "error", err)
	// }
	// defer profiler.Stop()
	// ─────────────────────────────────────────────────────────────────────

	brokerURL := getEnv("ACTIVEMQ_URL", defaultBrokerURL)

	slog.Info("notification-service starting",
		"broker_url", brokerURL,
		"queue", alertQueue,
	)

	// Graceful shutdown on SIGTERM / SIGINT (important for K8s pod lifecycle).
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// Outer reconnect loop. ActiveMQ Artemis closes idle STOMP connections
	// (AMQ229014 connection TTL). Rather than exiting on disconnect and relying
	// on a Kubernetes restart, reconnect in-process with a short backoff.
	for ctx.Err() == nil {
		conn, err := connectSTOMP(brokerURL)
		if err != nil {
			slog.Error("failed to connect to STOMP broker; retrying", "error", err, "broker_url", brokerURL)
			if sleepCtx(ctx, 3*time.Second) {
				return
			}
			continue
		}
		slog.Info("connected to STOMP broker", "broker_url", brokerURL)

		sub, err := conn.Subscribe(alertQueue, stomp.AckClient)
		if err != nil {
			slog.Error("failed to subscribe to queue; reconnecting", "queue", alertQueue, "error", err)
			_ = conn.Disconnect()
			if sleepCtx(ctx, 3*time.Second) {
				return
			}
			continue
		}
		slog.Info("subscribed to queue", "queue", alertQueue)

		// Consume until the subscription channel closes (broker disconnect) or shutdown.
		consume(ctx, conn, sub)
		_ = conn.Disconnect()

		if ctx.Err() != nil {
			return // clean shutdown
		}
		slog.Warn("STOMP connection lost; reconnecting", "queue", alertQueue)
		if sleepCtx(ctx, 3*time.Second) {
			return
		}
	}
}

// consume reads messages until the subscription channel closes or ctx is cancelled.
func consume(ctx context.Context, conn *stomp.Conn, sub *stomp.Subscription) {
	for {
		select {
		case <-ctx.Done():
			slog.Info("shutdown signal received, stopping consumer")
			return
		case msg, ok := <-sub.C:
			if !ok {
				return
			}
			processMessage(conn, msg)
		}
	}
}

// sleepCtx waits for d or until ctx is cancelled; returns true if cancelled.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return true
	case <-time.After(d):
		return false
	}
}

// processMessage deserialises the STOMP frame and dispatches to sendNotification.
func processMessage(conn *stomp.Conn, msg *stomp.Message) {
	if msg.Err != nil {
		slog.Error("received error frame from broker", "error", msg.Err)
		return
	}

	var alert AlertMessage
	if err := json.Unmarshal(msg.Body, &alert); err != nil {
		slog.Error("failed to unmarshal alert message",
			"error", err,
			"raw_body_length", len(msg.Body),
		)
		// NACK the message so the broker can redeliver or dead-letter it.
		if nackErr := conn.Nack(msg); nackErr != nil {
			slog.Error("failed to NACK message", "error", nackErr)
		}
		return
	}

	slog.Info("jms.message.process",
		"queue", alertQueue,
		"event_type", alert.EventType,
		"account_id", alert.AccountID,
		"channel", alert.Channel,
		"correlation_id", alert.CorrelationID,
		// NOTE: unlike Java (MDC) or Python (ddtrace.contrib.logging),
		// dd-trace-go does NOT inject dd.trace_id / dd.span_id into logs
		// automatically. Go requires manually reading the IDs off the
		// active span and adding them as fields — see sendNotification()
		// below, enabled via 'make instrument' + 'make tags'.
	)

	sendNotification(alert)

	if err := conn.Ack(msg); err != nil {
		slog.Error("failed to ACK message", "error", err, "correlation_id", alert.CorrelationID)
	}
}

// sendNotification stubs the email / SMS dispatch logic.
// In production this would call an SMTP relay or SMS gateway API.
func sendNotification(alert AlertMessage) {
	// ── DATADOG INSTRUMENTATION ──────────────────────────────────────────
	// Uncomment to wrap notification dispatch in a custom 'alert.send' span.
	// Finance tags below let you slice notification latency/failures by
	// channel and event type in APM.
	// Docs: https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/go/
	//
	// HIGH-CARDINALITY WARNING: account.id and jms.correlation_id are bounded
	// per-message IDs — fine on spans, do not use as metric tags.
	// See: https://docs.datadoghq.com/tagging/assigning_tags/
	//
	// 	span, _ := tracer.StartSpanFromContext(
	// 	context.Background(), "alert.send",
	// 	tracer.ResourceName(alert.EventType),
	// 	tracer.Tag("notification.channel", alert.Channel),
	// 	tracer.Tag("notification.event_type", alert.EventType),
	// 	tracer.Tag("account.id", alert.AccountID),
	// 	tracer.Tag("jms.correlation_id", alert.CorrelationID),
	// 	tracer.Tag("messaging.destination", "alert.queue"),
	// )
	// defer span.Finish()
	// ─────────────────────────────────────────────────────────────────────

	start := time.Now()

	switch alert.Channel {
	case "email":
		fields := []any{
			"channel", "email",
			"event_type", alert.EventType,
			"account_id", alert.AccountID,
			"correlation_id", alert.CorrelationID,
		}
		// ── Datadog Log Injection (enable via 'make tags') ──────────────
		// Uncomment to stitch this log line to the 'alert.send' span above.
		// Requires 'make instrument' to be applied first (the 'span'
		// variable above must exist). Go has no automatic MDC-style log
		// injection — dd.trace_id / dd.span_id must be added manually.
		// Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/?tab=go
		//
		// fields = append(fields, "dd.trace_id", span.Context().TraceID(), "dd.span_id", span.Context().SpanID())
		// ─────────────────────────────────────────────────────────────
		slog.Info("alert.send", fields...)
		// TODO: integrate with SMTP relay (e.g. SendGrid, SES)
	case "sms":
		fields := []any{
			"channel", "sms",
			"event_type", alert.EventType,
			"account_id", alert.AccountID,
			"correlation_id", alert.CorrelationID,
		}
		// ── Datadog Log Injection (enable via 'make tags') ──────────────
		// Uncomment to stitch this log line to the 'alert.send' span above.
		// Requires 'make instrument' to be applied first (the 'span'
		// variable above must exist). Go has no automatic MDC-style log
		// injection — dd.trace_id / dd.span_id must be added manually.
		// Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/?tab=go
		//
		// fields = append(fields, "dd.trace_id", span.Context().TraceID(), "dd.span_id", span.Context().SpanID())
		// ─────────────────────────────────────────────────────────────
		slog.Info("alert.send", fields...)
		// TODO: integrate with SMS gateway (e.g. Twilio, SNS)
	default:
		slog.Warn("alert.send.unknown_channel",
			"channel", alert.Channel,
			"event_type", alert.EventType,
			"correlation_id", alert.CorrelationID,
		)
	}

	duration := time.Since(start).Milliseconds()

	completeFields := []any{
		"channel", alert.Channel,
		"event_type", alert.EventType,
		"duration_ms", duration,
		"correlation_id", alert.CorrelationID,
	}
	// ── Datadog Log Injection (enable via 'make tags') ──────────────────
	// Uncomment to stitch this log line to the 'alert.send' span above.
	// Requires 'make instrument' to be applied first (the 'span' variable
	// above must exist). Go has no automatic MDC-style log injection —
	// dd.trace_id / dd.span_id must be added manually.
	// Docs: https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/?tab=go
	//
	// completeFields = append(completeFields, "dd.trace_id", span.Context().TraceID(), "dd.span_id", span.Context().SpanID())
	// ─────────────────────────────────────────────────────────────────────
	slog.Info("alert.send.complete", completeFields...)

	// Metrics (finance.notification.sent / .dispatch_time) are generated from
	// the alert.send span above via span-based metrics in deploy/terraform/datadog
	// — no DogStatsD emission here.
}

// connectSTOMP establishes a STOMP connection to the ActiveMQ Artemis broker.
// Retries with a fixed delay to handle broker startup ordering in Docker Compose.
func connectSTOMP(rawURL string) (*stomp.Conn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}

	host := u.Host
	var password string
	if u.User != nil {
		password, _ = u.User.Password()
	}
	user := u.User.Username()

	opts := []func(*stomp.Conn) error{
		stomp.ConnOpt.HeartBeat(10*time.Second, 10*time.Second),
	}
	if user != "" {
		opts = append(opts, stomp.ConnOpt.Login(user, password))
	}

	const maxRetries = 10
	for i := range maxRetries {
		conn, dialErr := stomp.Dial("tcp", host, opts...)
		if dialErr == nil {
			return conn, nil
		}
		slog.Warn("STOMP connection failed, retrying",
			"attempt", i+1,
			"max_attempts", maxRetries,
			"error", dialErr,
		)
		time.Sleep(3 * time.Second)
	}

	// Final attempt — return the error directly.
	return stomp.Dial("tcp", host, opts...)
}

// getEnv returns the value of an environment variable or a fallback default.
func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
