# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM gradle:8-jdk17 AS builder

WORKDIR /app

# Copy Gradle build files first for layer caching — dependencies are re-downloaded
# only when build.gradle changes, not on every source change.
COPY build.gradle settings.gradle* ./
RUN gradle dependencies --no-daemon 2>/dev/null || true

COPY src ./src
RUN gradle bootJar --no-daemon -x test

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre-jammy

LABEL maintainer="finance-platform-team"
LABEL service="account-service"

WORKDIR /app

COPY --from=builder /app/build/libs/app.jar app.jar

RUN addgroup --system finance && adduser --system --ingroup finance finance
USER finance

EXPOSE 8081

CMD ["java", "-jar", "app.jar"]
