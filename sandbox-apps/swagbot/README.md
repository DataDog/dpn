# Swagbot Chatbot

A demonstration chatbot for **LLM Observability** with Datadog integration, supporting both OpenAI and Google Gemini models.

## 🎯 **Purpose**

This chatbot provides:
- Simple integration with OpenAI or Gemini APIs
- Web UI that can be embedded via iFrame
- Automatic Datadog instrumentation using `ddtrace`
- LLM observability metrics and traces

## 📋 **Prerequisites**

- Docker and Docker Compose
- Datadog account and API key
- Either OpenAI API key OR Google Cloud Platform account with Vertex AI enabled

## 🚀 **Quick Start**

1. **Clone and navigate to the directory:**
   ```bash
   cd AIOps_LLM/swagbot
   ```

2. **Set up your environment variables** (see configuration sections below)

3. **Run the application:**
   ```bash
   docker-compose build
   docker-compose up -d
   ```

4. **Access the UI:**
   - Default: http://127.0.0.1:3000
   - Or use your custom `HOST:PORT` if configured

## 🚀 **Alternative: Showcasing Agentless Setup**

You can run Swagbot without the Datadog agent container using the agentless mode:

```bash
cd AIOps_LLM/swagbot/src
export DD_API_KEY="your-datadog-api-key"
export GCP_PROJECT_ID="your-project-id"  # If using Gemini

# Run agentless (no Docker needed)
DD_LLMOBS_ENABLED=1 DD_LLMOBS_ML_APP="swagbot" DD_API_KEY=<YOUR_DATADOG_API_KEY> DD_LOGS_INJECTION=true DD_ENV=dev DD_SERVICE=swagbot DD_VERSION=v0.6 DD_LLMOBS_AGENTLESS_ENABLED=1 ddtrace-run python app.py
```

## ⚙️ **Configuration**

### **Required Environment Variables**

**Only these variables need to be exported** (everything else has defaults in `docker-compose.yml`):

```bash
# REQUIRED: Datadog API key
export DD_API_KEY="your-datadog-api-key"
```

### **For OpenAI (if you want to use OpenAI instead of Gemini):**
```bash
export LLM_TYPE="OPENAI"                    # Override default (GEMINI)
export OPENAI_API_KEY="your-openai-key"    # Required for OpenAI
export MODEL_ID="gpt-4o"                    # Override default model
```

### **For Google Gemini (default setup):**

1. **GCP Project (if different from default):**
   ```bash
   export GCP_PROJECT_ID="your-project-id"  # Override default: datadog-partner-network
   export CATEGORIZATION_MODEL_ID="gemini-2.0-flash-lite-001" # (Optional) - Recommended to have different models used.
   ```

2. **Configure Service Account:**
   - Go to the [Google Cloud Console](https://console.cloud.google.com/)
   - Navigate to **IAM & Admin > Service Accounts**
   - Click **Create Service Account** and follow the instructions to create a new service account
   - Assign the **"Vertex AI Custom Code Service Agent"** role
   - After creating the service account, go to **Manage Keys** and create a new JSON key
   - This will download a `key.json` file to your machine
   - Copy the JSON content to `./gcp_json_key.json` in the Swagbot directory

## 🔧 **Optional Overrides**

**Only export these if you want to change the defaults:**

```bash
# Model Selection (defaults in docker-compose.yml)
export MODEL_ID="gemini-model-id" # Default: gemini-1.5-pro-002 
export CATEGORIZATION_MODEL_ID="gemini-model-id" # Default: If not set, will use MODEL_ID

# Datadog RUM (optional)
export DD_APPLICATION_ID="your-app-id"
export DD_CLIENT_TOKEN="your-client-token"

# Server settings (already set in docker-compose)
export FLASK_HOST="127.0.0.1"                         # Default: 0.0.0.0
export FLASK_PORT="8080"                               # Default: 3000
```

## 📋 **What's Already Configured**

These are **already set** in `docker-compose.yml` with sensible defaults:

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `LLM_TYPE` | `GEMINI` | Using Gemini by default |
| `MODEL_ID` | `gemini-1.5-pro-002` | Primary model |
| `FLASK_HOST` | `0.0.0.0` | Accept connections from any IP |
| `FLASK_PORT` | `3000` | Default port |
| `GCP_LLM_LOCATION` | `us-central1` | GCP region |
| `GCP_PROJECT_ID` | `datadog-partner-network` | Default project |

## 📁 **Project Structure**
```
AIOps_LLM/swagbot/
├── docker-compose.yml
├── gcp_json_key.json      # GCP service account key (if using Gemini)
├── src/                   # Application source code
│   ├── app.py            # Main Flask application
│   ├── config.py         # Configuration management
│   └── resources/        # System prompts and data files
└── README.md
```

## 🛠️ **Troubleshooting**

### **Common Issues**
- **Port already in use**: Change the `FLASK_PORT` environment variable
- **GCP authentication**: Ensure your service account has the correct permissions
- **Datadog not connected**: Verify your `DD_API_KEY` is correct
- **Model not found**: Check if your `MODEL_ID` is supported in your GCP region

### **Environment Variable Reference**
Based on the actual source code, here are ALL the supported variables:

| Variable | Required | Default | Description |
|---------|----------|---------|-------------|
| `DD_API_KEY` | ✅ | - | Datadog API key |
| `LLM_TYPE` | ❌ | `GEMINI` | `OPENAI` or `GEMINI` |
| `MODEL_ID` | ❌ | `gemini-1.5-pro-002` | Primary model ID |
| `CATEGORIZATION_MODEL_ID` | ❌ | Uses `MODEL_ID` | Separate model for categorization |
| `OPENAI_API_KEY` | ✅* | - | Required if `LLM_TYPE=OPENAI` |
| `GCP_PROJECT_ID` | ✅* | `datadog-sandbox` | Required if `LLM_TYPE=GEMINI` |
| `GCP_LLM_LOCATION` | ❌ | `us-central1` | GCP region |
| `FLASK_HOST` | ❌ | `127.0.0.1` | Server host |
| `FLASK_PORT` | ❌ | `3000` | Server port |

### **Logs**
```bash
# View application logs
docker-compose logs -f

# View specific service logs
docker-compose logs -f swagbot

# Follow logs in real-time
docker-compose logs -f --tail=100 swagbot
```

### **Testing Configuration**
```bash
# Test your configuration
docker-compose config

# Check if containers are running
docker-compose ps

# Restart if needed
docker-compose restart swagbot
```

## 🧹 **Cleanup**
```bash
# Stop and remove containers
docker-compose down

# Remove volumes (optional)
docker-compose down -v

# Remove all unused Docker resources
docker system prune -a
```

## 📊 **Datadog Integration**

Once running, you can view:
- **APM Traces**: Application performance and LLM calls
- **Logs**: Application and error logs  
- **Metrics**: Custom LLM observability metrics
- **RUM**: Real User Monitoring (if configured)

Access your Datadog dashboard to see the instrumentation in action.

## 🔬 **Development Tips**

### **Testing Different Models**
```bash
# Test with different Gemini models
export MODEL_ID="gemini-2.0-flash-lite-001"
docker-compose restart swagbot

# Use separate models for different workflows
export CATEGORIZATION_MODEL_ID="gemini-2.0-flash-lite-001"  # Fast for categorization
export MODEL_ID="gemini-1.5-pro-002"                        # Comprehensive for main chat
```

### **Custom System Prompts**
```bash
# Create custom prompts
export MODEL_SYS_INSTRUCTIONS="resources/my-custom-prompt.txt"
```