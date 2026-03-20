import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    # Datadog Configs:
    DD_SITE = os.environ.get("DD_SITE", "datadoghq.com")
    DD_API_KEY = os.environ.get("DD_API_KEY")
    DD_APP_KEY = os.environ.get("DD_APP_KEY")
    DD_LLMOBS_AGENTLESS_ENABLED = os.environ.get("DD_LLMOBS_AGENTLESS_ENABLED", False)
    DD_LLMOBS_PROJECT_NAME = os.environ.get("DD_LLMOBS_PROJECT_NAME", "swagbot_model_optimization")
    DD_LLMOBS_DATASET_NAME = os.environ.get("DD_LLMOBS_DATASET_NAME", "swagbot_dataset")
    # Max dataset records per LLM Obs experiment run (first N rows; ddtrace sample_size)
    _exp_max_raw = os.environ.get("DD_LLMOBS_EXPERIMENT_MAX_RECORDS", "12")
    try:
        DD_LLMOBS_EXPERIMENT_MAX_RECORDS = max(1, int(str(_exp_max_raw).strip()))
    except ValueError:
        DD_LLMOBS_EXPERIMENT_MAX_RECORDS = 12

    # Datadog RUM Configs:
    DD_APPLICATION_ID = os.environ.get("DD_APPLICATION_ID")
    DD_CLIENT_TOKEN = os.environ.get("DD_CLIENT_TOKEN")
    DD_ENV = os.environ.get("DD_ENV", "development")
   
    # LLM Configs:
    LLM_TYPE = os.environ.get("LLM_TYPE", "GEMINI")
    OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
    MODEL_ID = os.environ.get("MODEL_ID", "gemini-2.5-pro") # openAi model id: gpt-4o
    CATEGORIZATION_MODEL_ID = os.environ.get("CATEGORIZATION_MODEL_ID")  # If not set, will use default MODEL_ID
    # Vertex model for Swagbot experiment evaluators (user-response truth / hallucination judge)
    DD_SWAGBOT_RESPONSE_EVAL_MODEL = os.environ.get("DD_SWAGBOT_RESPONSE_EVAL_MODEL", "gemini-2.5-flash")
    MODEL_SYS_INSTRUCTIONS = os.environ.get("GCP_SYS_INSTRUCTIONS", "resources/gemini-system-prompt.txt") # openAi system prompt location: resources/openai-system-prompt.txt

    GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "datadog-partner-network")
    GCP_LLM_LOCATION = os.environ.get("GCP_LLM_LOCATION", "us-central1")

    FLASK_HOST = os.environ.get("FLASK_HOST", "127.0.0.1")
    FLASK_PORT = int(os.environ.get("FLASK_PORT", 3000))
    REPLAY_PATH = os.environ.get("REPLAY_PATH","resources/replay_data_fixed_products")

    # Lab Configs
    PRODUCTS_JSON = os.environ.get("PRODUCTS_JSON", "resources/products.json")