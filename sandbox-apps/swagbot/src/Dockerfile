FROM python:3.11

# Setting up LLMObs Env Var
ENV DD_LLMBOS_ENABLED=1 
ENV DD_LLMOBS_ML_APP=swagbot

# Install curl and required packages for Google Cloud SDK
RUN apt-get update && apt-get install -y curl apt-transport-https ca-certificates gnupg

# Add Google Cloud SDK public key
RUN curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor | tee /usr/share/keyrings/cloud.google.gpg > /dev/null

# Add Google Cloud SDK repository
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list

# Install Google Cloud SDK
RUN apt-get update && apt-get install -y google-cloud-sdk

# Create the application directory
RUN mkdir -p /usr/src/server
WORKDIR /usr/src/server

# Copy application files
COPY ./ /usr/src/server

# Install Python dependencies
COPY ./requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 3000
CMD ["ddtrace-run", "python", "app.py"]
