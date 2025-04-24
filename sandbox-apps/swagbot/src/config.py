import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    # Datadog Configs:
    DD_SITE = os.environ.get("DD_SITE", "datadoghq.com")
    DD_API_KEY = os.environ.get("DD_API_KEY")
    DD_LLMOBS_AGENTLESS_ENABLED = os.environ.get("DD_LLMOBS_AGENTLESS_ENABLED", False)
   
    # LLM Configs:
    LLM_TYPE = os.environ.get("LLM_TYPE", "OPEN_AI")
    OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
    MODEL = os.environ.get("MODEL", "gpt-4o")
    OPENAI_SYS_INSTRUCTIONS = os.environ.get("OPENAI_SYS_INSTRUCTIONS", "resources/openai-system-prompt.txt")
    GCP_MODEL_ID = os.environ.get("GCP_MODEL_ID", "gemini-1.5-pro-002")
    GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "datadog-sandbox")
    GCP_LLM_LOCATION = os.environ.get("GCP_LLM_LOCATION", "us-central1")
    GCP_SYS_INSTRUCTIONS = os.environ.get("GCP_SYS_INSTRUCTIONS", "resources/gemini-system-prompt.txt")
    FLASK_HOST = os.environ.get("FLASK_HOST", "127.0.0.1")
    FLASK_PORT = int(os.environ.get("FLASK_PORT", 3000))
    REPLAY_PATH = os.environ.get("REPLAY_PATH","resources/replay_data")

    # Lab Configs
    PRODUCTS_JSON = os.environ.get("PRODUCTS_JSON", "resources/products.json")