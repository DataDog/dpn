FROM python:3.11-slim

# Install minimal Google Cloud CLI only (not full SDK)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    && curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-cloud-cli \
    # Clean up apt cache (saves ~100MB)
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create the application directory
WORKDIR /usr/src/server

# Copy and install Python dependencies first (better layer caching)
COPY ./requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY ./ /usr/src/server

EXPOSE 3000

