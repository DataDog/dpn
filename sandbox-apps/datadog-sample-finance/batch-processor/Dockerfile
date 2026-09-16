# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM gradle:8-jdk17 AS builder

WORKDIR /app

COPY build.gradle settings.gradle* ./
RUN gradle dependencies --no-daemon 2>/dev/null || true

COPY src ./src
RUN gradle bootJar --no-daemon -x test

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre

ARG APP_VERSION=0.0.1-SNAPSHOT

WORKDIR /app

COPY --from=builder /app/build/libs/*.jar app.jar

ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -Xss512k"

EXPOSE 8080

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
