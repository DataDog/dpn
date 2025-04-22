# Swagbot Chatbot

The purpose of this code is to demonstrate LLM Observability with simple integration to OpenAI or Gemini. 

> Disclaimer: Gemini VertexAi is fully supported, OpenAI require some additional prompt engineering to work at 100%. 

The chatbot is fully auto-instrumented with Datadog and dependant only on ```python``` the ```datadog-agent``` and ```ddtrace```

# How to Run

## General Variable
Set the following local variables:
- `DD_API_KEY`: Found on the Datadog platform.

## VertexAI:
1. Set the following on your machine `env` variables:
    - LLM_TYPE: Need to be set to `GEMINI`, otherwise will default to `OPENAI`
    - LLM_MODEL_ID: Optional will default to gemini-1.5-pro-002
    - GCP_PROJECT_ID: The PROJECT_ID where you enabled Vertex-AI API 
    - GCP_LLM_LOCATION: The default location to use when making API calls. Will default to `us-central1`.

2. Set the Sevice Account Key:
    - Go to the Google Cloud Console.
    - Navigate to IAM & Admin > Service Accounts.
    - Click Create Service Account and follow the instructions to create a new service account. (Assign "Vertex AI Custom Code Service Agent" role)
    - After creating the service account, go to Manage Keys and create a new JSON key. This will download a key.json file to your machine.
    - Update the content of the **src/gcp_json_key.json** file in with the new key generated

3. Run docker-compose up -d

## **OpenAI**
1. Set the following on your machine `env` variables:
    - Set ```OPENAI_API_KEY``` with the right value in your ```env``` variable or set this up for the docker container.
    - You also need to set the model with ```MODEL``` env var. Default to `gpt-4o`.

2. Run docker-compose up -d

# Other instructions

## Optional Environment variable
You can specify ```HOST``` and ```PORT``` for the Swagbot interface URL, otherwise it will default to `http://127.0.0.1:3000`.

