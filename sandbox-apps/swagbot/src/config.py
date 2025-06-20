import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    # Datadog Configs:
    DD_SITE = os.environ.get("DD_SITE", "datadoghq.com")
    DD_API_KEY = os.environ.get("DD_API_KEY")
    DD_LLMOBS_AGENTLESS_ENABLED = os.environ.get("DD_LLMOBS_AGENTLESS_ENABLED", False)
    
    # Datadog RUM Configs:
    DD_APPLICATION_ID = os.environ.get("DD_APPLICATION_ID")
    DD_CLIENT_TOKEN = os.environ.get("DD_CLIENT_TOKEN")
    DD_ENV = os.environ.get("DD_ENV", "development")
   
    # LLM Configs:
    LLM_TYPE = os.environ.get("LLM_TYPE", "GEMINI")
    OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
    MODEL_ID = os.environ.get("MODEL_ID", "gemini-1.5-pro-002") # openAi model id: gpt-4o
    CATEGORIZATION_MODEL_ID = os.environ.get("CATEGORIZATION_MODEL_ID")  # If not set, will use default MODEL_ID
    MODEL_SYS_INSTRUCTIONS = os.environ.get("GCP_SYS_INSTRUCTIONS", "resources/gemini-system-prompt.txt") # openAi system prompt location: resources/openai-system-prompt.txt

    GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "datadog-partner-network")
    GCP_LLM_LOCATION = os.environ.get("GCP_LLM_LOCATION", "us-central1")

    FLASK_HOST = os.environ.get("FLASK_HOST", "127.0.0.1")
    FLASK_PORT = int(os.environ.get("FLASK_PORT", 3000))
    REPLAY_PATH = os.environ.get("REPLAY_PATH","resources/replay_data")

    # Lab Configs
    PRODUCTS_JSON = os.environ.get("PRODUCTS_JSON", "resources/products.json")