# Swagbot

Demo e-commerce assistant (**Swagstore**) with Datadog **LLM Observability** (`ddtrace`). Supports **Google Vertex AI (Gemini)** or **OpenAI**, Flask web UI, and optional **LLM Experiments** to compare models on a dataset.

## What you get

- Categorized replies (`Help-Customer-Service`, `Product-Information`, `Promotion`, `Feedback`, `Other`, `Final`) using a strict `category":"reply":"reason` line format (see `src/resources/gemini-system-prompt.txt`).
- APM and LLM Observability traces via the **Datadog Agent** (default in Compose).
- Optional **replay** scripts and CSV exports for building evaluation datasets.
- **`swagbot_experiment_utils.py`** — pull/create datasets and run multi-model Vertex experiments in Datadog.

## Prerequisites

- Docker and Docker Compose
- Datadog **API key**; for Experiments you also need an **Application key** (`DD_APP_KEY`)
- For Gemini: GCP project with Vertex AI, service account JSON (e.g. `gcp_json_key.json` → mounted as `key.json` in the container)
- For OpenAI: `OPENAI_API_KEY` and `LLM_TYPE=OPENAI`

## Quick start (Docker)

```bash
cd AIOps_LLM/swagbot
export DD_API_KEY="your-datadog-api-key"
# Recommended for LLM Experiments:
export DD_APP_KEY="your-datadog-application-key"

docker compose up -d
```

- **UI:** http://127.0.0.1:3000 (port from `FLASK_PORT`, mapped in Compose)
- **Compose** runs `swagbot` + **`agent`**; LLM Observability is intended to use the Agent (`DD_AGENT_HOST=agent`), not agentless mode.

To build the app image from this repo (includes `experiments/`), uncomment the `build:` section for `swagbot` in `docker-compose.yml` (pointing at `./src`) and run:

```bash
docker compose build swagbot
```

The sample Compose file may use a prebuilt image; if `experiments/` is missing in the container, mount it:

```yaml
# Under swagbot.volumes, add for local dev:
- ./src/experiments:/usr/src/server/experiments
```

## Configuration

### Always required for the running app

| Variable | Notes |
|----------|--------|
| `DD_API_KEY` | Datadog API key |

### Required for LLM Experiments (`swagbot_experiment_utils.py`)

| Variable | Notes |
|----------|--------|
| `DD_API_KEY` | Same as above |
| `DD_APP_KEY` | Datadog **Application** key (Organization Settings → API Keys → Application Keys) |

### Gemini (default: `LLM_TYPE=GEMINI`)

| Variable | Default (see `config.py` / Compose) |
|----------|--------------------------------------|
| `GCP_PROJECT_ID` | `datadog-partner-network` |
| `GCP_LLM_LOCATION` | `us-central1` |
| `GOOGLE_APPLICATION_CREDENTIALS` | In Compose: `/usr/src/server/resources/key.json` (from `./gcp_json_key.json`) |
| `MODEL_ID` | `gemini-2.5-pro` |
| `CATEGORIZATION_MODEL_ID` | If unset, falls back to `MODEL_ID` (Compose often sets e.g. `gemini-2.5-flash-lite`) |
| `MODEL_SYS_INSTRUCTIONS` | Path to system prompt file; Compose example: `/usr/src/server/resources/gemini-system-prompt.txt` |

In `config.py`, `MODEL_SYS_INSTRUCTIONS` is read from env `GCP_SYS_INSTRUCTIONS` if set, otherwise defaults to `resources/gemini-system-prompt.txt`.

### OpenAI

```bash
export LLM_TYPE=OPENAI
export OPENAI_API_KEY=...
export MODEL_ID=gpt-4o
```

### LLM Observability Experiments (env)

| Variable | Default | Description |
|----------|---------|-------------|
| `DD_LLMOBS_PROJECT_NAME` | `swagbot_model_optimization` | Project name in LLM Observability |
| `DD_LLMOBS_DATASET_NAME` | `swagbot_dataset` | Dataset to pull for runs |
| `DD_LLMOBS_EXPERIMENT_MAX_RECORDS` | `12` | First *N* rows per experiment (`sample_size`) |
| `DD_SWAGBOT_RESPONSE_EVAL_MODEL` | `gemini-2.5-flash` | Vertex model for the Gemini-based evaluator |
| `DD_SITE` | `datadoghq.com` | Datadog site |

### Optional

- `DD_APPLICATION_ID`, `DD_CLIENT_TOKEN`, `DD_ENV` — RUM / tagging
- `PRODUCTS_JSON`, `REPLAY_PATH` — data paths
- `FLASK_HOST`, `FLASK_PORT`

## LLM Observability experiments

Script: **`src/experiments/swagbot_experiment_utils.py`** (in the container: `/usr/src/server/experiments/swagbot_experiment_utils.py`).

Run inside the `swagbot` container with the same env as the app (keys, GCP, prompt file). The script:

1. Ensures the LLM Observability **project** exists (creates it if missing).
2. Can **list** projects/datasets, **create** a dataset from a CSV export, or **run** experiments over `MODELS_TO_RUN` (Vertex Gemini IDs in the script).

### Examples

```bash
# List projects and datasets (names must match Datadog exactly)
docker compose exec swagbot \
  python /usr/src/server/experiments/swagbot_experiment_utils.py --list-datasets

# Create a dataset from a CSV (default file: bundled export next to the script)
docker compose exec swagbot \
  python /usr/src/server/experiments/swagbot_experiment_utils.py \
    --create-dataset-from-csv \
    --new-dataset-name swagbot_dataset \
    --project YOUR_PROJECT_NAME

# Run model comparison experiments (uses DD_LLMOBS_PROJECT_NAME / DD_LLMOBS_DATASET_NAME)
docker compose exec swagbot \
  python /usr/src/server/experiments/swagbot_experiment_utils.py

# Override project/dataset for one run
docker compose exec swagbot \
  python /usr/src/server/experiments/swagbot_experiment_utils.py \
    --project swagbot_model_optimization \
    --dataset swagbot_dataset
```

Docs: [LLM Observability Experiments](https://docs.datadoghq.com/llm_observability/experiments)

### Evaluators (per dataset row)

High level:

1. **Format and category** — Output is a valid `category":"reply":"reason` line and the category is one of the six allowed names in the system prompt.
2. **Category matches expected** — Parsed category matches the reference from the dataset’s `expected_output` when a reference exists; otherwise skipped (pass).
3. **Response anchors match expected** (name kept for Datadog) — A **Vertex Gemini** judge scores the user-visible (middle) segment: align with the reference when present; otherwise a stricter check against unsupported claims vs. the user message.

Optional OpenAI-based judges are added only if `OPENAI_API_KEY` is set and the ddtrace LLM judge helpers are available.

### Dataset CSV format (for `--create-dataset-from-csv`)

Expects columns including **`input`**, **`expected_output`**, and optional metadata columns (`id`, `metadata`, `tags`, etc.) as produced by Datadog project export. The experiment task uses the **last user message** from `input` when it is a JSON chat transcript.

## Project structure

```
AIOps_LLM/swagbot/
├── docker-compose.yml       # swagbot + datadog agent
├── gcp_json_key.json        # Service account JSON (Gemini); gitignored in real use
├── src/
│   ├── app.py               # Flask app
│   ├── config.py            # Environment-based config
│   ├── replay.py            # Replay helpers (if used)
│   ├── experiments/
│   │   ├── swagbot_experiment_utils.py   # Experiments CLI
│   │   └── *.csv            # Example exports (optional)
│   ├── resources/           # Prompts, products.json, etc.
│   ├── scripts/             # Shell helpers for interactions / replay
│   └── Dockerfile
└── README.md
```

## Datadog integration

With Agent + `ddtrace-run`:

- **APM** — Requests and workflows
- **LLM Observability** — LLM spans, evaluations when configured
- **Experiments** — Compare models on a dataset (requires `DD_APP_KEY`)

## Agentless (optional)

Not the default for this Compose stack. For a local agentless trial you must set the flags your org documents (e.g. `DD_LLMOBS_AGENTLESS_ENABLED`) and run `ddtrace-run python app.py` with `DD_API_KEY` set. Prefer Agent mode for parity with production experiments.

## Troubleshooting

| Issue | What to check |
|-------|----------------|
| Port in use | Change host mapping or `FLASK_PORT` |
| Vertex / GCP errors | Service account roles (Vertex AI), `GCP_PROJECT_ID`, region, `key.json` mount |
| No Datadog data | `DD_API_KEY`, Agent running, `DD_AGENT_HOST` |
| Experiments fail to pull dataset | `DD_APP_KEY`, exact `--project` / `--dataset` names (`--list-datasets`) |
| Experiments script missing | Mount `./src/experiments` or build image from `src/` |

## Logs

```bash
docker compose logs -f swagbot
docker compose logs -f agent
```

## Cleanup

```bash
docker compose down
docker compose down -v   # remove volumes if any
```

## Development tips

- **Models:** Set `MODEL_ID` / `CATEGORIZATION_MODEL_ID` in Compose or env; restart `swagbot`.
- **System prompt:** Edit `src/resources/gemini-system-prompt.txt` or point `MODEL_SYS_INSTRUCTIONS` / `GCP_SYS_INSTRUCTIONS` at another file.
- **Experiments model list:** Edit `MODELS_TO_RUN` in `swagbot_experiment_utils.py`.
