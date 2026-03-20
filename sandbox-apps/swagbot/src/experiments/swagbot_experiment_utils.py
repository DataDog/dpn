#!/usr/bin/env python3
"""
Swagbot model experiments for Datadog LLM Observability.

Run this file as ``python experiments/swagbot_experiment_utils.py`` (or the path below
inside the container).

Pulls a dataset from your LLM Observability project, runs the Swagbot categorization task
once per row for each Vertex model in ``MODELS_TO_RUN``. Each model returns one line in the
same triple format as production: category, user-facing reply, and reason separated by the
string ``\":\"`` (see ``parse_swagbot_triple``). Evaluators then run on that output.

How to run
    From the Swagbot service container (paths match a typical compose mount to
    ``/usr/src/server``)::

        docker compose exec swagbot \\
          python /usr/src/server/experiments/swagbot_experiment_utils.py

    Other useful invocations::

        docker compose exec swagbot \\
          python /usr/src/server/experiments/swagbot_experiment_utils.py --list-datasets
        docker compose exec swagbot \\
          python /usr/src/server/experiments/swagbot_experiment_utils.py \\
            --project YOUR_PROJECT --dataset YOUR_DATASET

    Create a dataset from the bundled project export CSV (columns ``input``,
    ``expected_output``, plus metadata)::

        docker compose exec swagbot \\
          python /usr/src/server/experiments/swagbot_experiment_utils.py \\
            --create-dataset-from-csv \\
            --new-dataset-name swagbot_dataset

    Pass a path after ``--create-dataset-from-csv`` to use another file. Requires
    ``DD_API_KEY`` and ``DD_APP_KEY`` only (no Vertex needed for upload).

Environment
    Same as the Flask app: ``docker-compose.yml`` and ``config.Config`` (``DD_API_KEY``,
    ``DD_APP_KEY``, ``DD_LLMOBS_PROJECT_NAME``, ``DD_LLMOBS_DATASET_NAME``, ``GCP_*``,
    ``GOOGLE_APPLICATION_CREDENTIALS``, ``MODEL_SYS_INSTRUCTIONS``, etc.). The process
    should use the Datadog Agent (e.g. ``DD_AGENT_HOST=agent``), not agentless LLM Observability.

Evaluators (each dataset row)
    * ``format_and_category`` -- Output is a valid triple line and category is one of the
      six names defined in ``gemini-system-prompt.txt``.
    * ``category_matches_expected`` -- Parsed category matches the reference category from
      ``expected_output`` when the dataset provides one; otherwise pass (skipped).
    * ``response_anchors_match_expected`` -- Vertex Gemini judges the user-facing (middle)
      segment: factual alignment with the reference reply when present, otherwise a
      stricter check for unsupported concrete claims vs. the user message alone.
      Judge model: ``DD_SWAGBOT_RESPONSE_EVAL_MODEL`` (default ``gemini-2.5-flash``).

    If ``OPENAI_API_KEY`` is set and the ddtrace LLM judge helpers are available, optional
    OpenAI judges may be added (quality score, accuracy).

Experiment size
    Only the first ``DD_LLMOBS_EXPERIMENT_MAX_RECORDS`` rows are executed per run (default
    ``10``), via ``experiment.run(..., sample_size=...)``.

Project
    Before pulling a dataset or uploading from CSV, the script ensures the configured
    LLM Observability **project** exists (creates it if missing), using the same ddtrace
    API as dataset operations.

Documentation: https://docs.datadoghq.com/llm_observability/experiments
"""

# Reduce Google/gRPC log noise before importing those libraries.
import os

os.environ.setdefault("GRPC_VERBOSITY", "ERROR")
os.environ.setdefault("GLOG_minloglevel", "3")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
os.environ.setdefault("GOOGLE_CLOUD_DISABLE_GRPC_LOGS", "1")

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import requests

SCRIPT_DIR = Path(__file__).resolve().parent

# Default LLM Obs export from this folder (Datadog project export CSV).
DEFAULT_SWAGBOT_EXPORT_CSV = (
    SCRIPT_DIR / "swagbot_dataset_2026-03-19.csv"
)


def _cli_section(title: str) -> None:
    """Plain ASCII section header for terminal output."""
    print()
    print(title)
    print("-" * len(title))


def _cli_kv(label: str, value: str, width: int = 26) -> None:
    """Aligned key/value line (two leading spaces)."""
    print(f"  {label + ':':<{width}} {value}")


def resolve_swagbot_paths(script_dir: Path) -> Tuple[Path, Path]:
    """Docker app root = parent of ``experiments/`` (``/usr/src/server``). Prompt from compose."""
    server_root = script_dir.parent
    env_prompt = os.environ.get("MODEL_SYS_INSTRUCTIONS")
    if env_prompt:
        p = Path(env_prompt).expanduser()
        try:
            p = p.resolve()
        except OSError:
            p = Path(env_prompt).expanduser()
        if p.is_file():
            resources_dir = p.parent
            swag_src = (
                resources_dir.parent
                if resources_dir.name == "resources"
                else resources_dir
            )
            return swag_src, p
    prompt = server_root / "resources" / "gemini-system-prompt.txt"
    try:
        prompt = prompt.resolve()
    except OSError:
        pass
    return server_root, prompt


SWAGBOT_SRC, SYSTEM_PROMPT_PATH = resolve_swagbot_paths(SCRIPT_DIR)
if str(SWAGBOT_SRC) not in sys.path:
    sys.path.insert(0, str(SWAGBOT_SRC))

from config import Config

from ddtrace.llmobs import LLMObs, EvaluatorResult

try:
    from ddtrace.llmobs._evaluators import (
        LLMJudge,
        BooleanStructuredOutput,
        ScoreStructuredOutput,
    )
    HAS_LLM_JUDGE = True
except ImportError:
    HAS_LLM_JUDGE = False

import vertexai
from vertexai.generative_models import GenerationConfig, GenerativeModel


# Vertex model IDs to compare (must exist in your GCP region).
MODELS_TO_RUN = [
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemini-2.5-pro",
]


def ensure_llm_obs_project(project_name: str) -> None:
    """Create the LLM Observability project if it does not exist (idempotent).

    Uses the same ddtrace experiments client as ``pull_dataset`` /
    ``create_dataset`` (``project_create_or_get``). Call only after
    ``LLMObs.enable(...)``.
    """
    inst = getattr(LLMObs, "_instance", None)
    if inst is None:
        raise RuntimeError("LLMObs.enable() must be called before ensure_llm_obs_project().")
    dne = getattr(inst, "_dne_client", None)
    if dne is None:
        raise RuntimeError("LLM Observability experiments client is not available.")
    dne.project_create_or_get(project_name)


def list_projects_and_datasets(api_key: str, app_key: str, site: str) -> None:
    """Call Datadog Experiments API to list projects and their datasets (for finding exact names)."""
    base = f"https://api.{site}" if "datadoghq" in site else f"https://api.datadoghq.com"
    url = f"{base}/api/v2/llm-obs/v1/projects"
    headers = {"DD-API-KEY": api_key, "DD-APPLICATION-KEY": app_key}
    try:
        r = requests.get(url, headers=headers, params={"page[limit]": 100}, timeout=30)
        r.raise_for_status()
    except requests.RequestException as e:
        print(f"Error: could not list projects ({e}).")
        if hasattr(e, "response") and e.response is not None and hasattr(e.response, "text"):
            print("Response detail (first 500 characters):")
            print(e.response.text[:500])
        return
    data = r.json()
    projects = data.get("data") or []
    if not projects:
        print("No projects found. Create a project and dataset in Datadog LLM Experiments first.")
        return
    _cli_section("Datadog LLM Observability: projects and datasets")
    print(
        "Use the project and dataset names below with --project and --dataset, "
        "or set DD_LLMOBS_PROJECT_NAME and DD_LLMOBS_DATASET_NAME."
    )
    print()
    for proj in projects:
        pid = proj.get("id")
        attrs = proj.get("attributes") or {}
        pname = attrs.get("name", "(no name)")
        print(f"Project: {pname!r}")
        print(f"  id: {pid}")
        durl = f"{base}/api/v2/llm-obs/v1/{pid}/datasets"
        try:
            dr = requests.get(durl, headers=headers, params={"page[limit]": 100}, timeout=30)
            dr.raise_for_status()
            ddata = dr.json()
            datasets = ddata.get("data") or []
            for ds in datasets:
                dattrs = ds.get("attributes") or {}
                dname = dattrs.get("name", "(no name)")
                print(f"  Dataset: {dname!r}")
            if not datasets:
                print("  Dataset: (none)")
        except requests.RequestException as e:
            print(f"  Error listing datasets: {e}")
        print()


def load_system_prompt() -> str:
    if not SYSTEM_PROMPT_PATH.exists():
        raise FileNotFoundError(f"System prompt not found: {SYSTEM_PROMPT_PATH}")
    return SYSTEM_PROMPT_PATH.read_text()


def last_user_text_from_chat_messages(messages: Any) -> Optional[str]:
    """From an OpenAI-style ``messages`` list, return the last ``user`` turn content."""
    if not isinstance(messages, list):
        return None
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        if (msg.get("role") or "").lower() != "user":
            continue
        content = msg.get("content")
        if content is not None and str(content).strip():
            return str(content).strip()
    return None


def get_user_request(input_data: Any) -> str:
    """Extract user message from dataset record input.

    Supports Swagbot-shaped data: when the dataset is built from Swagbot traces,
    input may be a string (user message) or a dict with "value" (trace meta.input),
    "user_request", "data", "question", or "input".

    If the resolved field is a JSON array of chat messages (Datadog export / replay),
    uses the **last user** message only so the experiment matches a single-turn
    categorization call with the system prompt loaded separately.
    """
    if isinstance(input_data, str):
        raw = input_data.strip()
    elif isinstance(input_data, dict):
        raw_val = (
            input_data.get("user_request")
            or input_data.get("data")
            or input_data.get("question")
            or input_data.get("input")
            or input_data.get("value")
        )
        raw = str(raw_val).strip() if raw_val is not None else ""
    else:
        raw = str(input_data).strip()

    if raw.startswith("["):
        try:
            parsed = json.loads(raw)
            last_user = last_user_text_from_chat_messages(parsed)
            if last_user:
                return last_user
        except (json.JSONDecodeError, TypeError):
            pass
    return raw


def call_vertex_gemini(user_request: str, system_instruction: str, model_id: str) -> str:
    """Single turn call to Vertex AI Gemini. Returns response text."""
    model = GenerativeModel(model_id, system_instruction=system_instruction)
    chat = model.start_chat(history=[])
    response = chat.send_message(user_request)
    return response.text if response and response.text else ""


_RESPONSE_TRUTH_JUDGE_SYSTEM = """You are a strict evaluator for Swagbot, a merch-store assistant.
The model output format is category : user-facing reply : internal reason (you only judge the user-facing middle segment).

You must reply with a single JSON object only, no markdown fences, with keys:
  "pass" (boolean): true if the user-facing reply meets the criteria below, false otherwise.
  "reasoning" (string): one short sentence explaining why.

Evaluation mode A - REFERENCE PROVIDED (the reference user-facing text is non-empty):
- The user-facing reply must be factually aligned with the reference: same concrete facts (prices, product names, SKUs, policies, dates).
- Paraphrasing and minor wording changes are OK.
- FAIL if the reply contradicts the reference, omits a critical fact present in the reference (e.g. wrong or missing price), or adds new concrete claims that conflict with the reference.

Evaluation mode B - NO REFERENCE (reference user-facing text is empty or not provided):
- Perform hallucination / unsupported-claim detection using ONLY the user message as ground context.
- FAIL if the user-facing reply states specific facts (prices, product details, inventory, policies) that are not clearly supported by the user message (invented specifics).
- Generic helpful or clarifying replies without invented specifics PASS.

If the user-facing reply to evaluate is empty, set pass to false."""


def _parse_json_object_from_gemini(text: str) -> Optional[Dict[str, Any]]:
    """Parse {\"pass\": bool, \"reasoning\": str} from model output; tolerate fences."""
    if not text or not text.strip():
        return None
    s = text.strip()
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s, flags=re.IGNORECASE)
        s = re.sub(r"\s*```\s*$", "", s)
    try:
        obj = json.loads(s)
    except json.JSONDecodeError:
        m = re.search(r"\{[\s\S]*\}", s)
        if not m:
            return None
        try:
            obj = json.loads(m.group(0))
        except json.JSONDecodeError:
            return None
    if not isinstance(obj, dict):
        return None
    return obj


def call_vertex_gemini_judge_json(
    user_prompt: str, model_id: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """Single-turn Gemini call returning parsed JSON object with pass/reasoning."""
    mid = model_id or Config.DD_SWAGBOT_RESPONSE_EVAL_MODEL
    model = GenerativeModel(mid, system_instruction=_RESPONSE_TRUTH_JUDGE_SYSTEM)
    suffix = '\nRespond with JSON only: {"pass": <true|false>, "reasoning": "<short string>"}'

    def _from_response(response: Any) -> Optional[Dict[str, Any]]:
        raw = response.text if response and getattr(response, "text", None) else ""
        return _parse_json_object_from_gemini(raw)

    try:
        gen_cfg = GenerationConfig(
            temperature=0.0,
            response_mime_type="application/json",
        )
        response = model.generate_content(user_prompt + suffix, generation_config=gen_cfg)
        parsed = _from_response(response)
        if parsed is not None:
            return parsed
    except Exception:
        pass

    try:
        response = model.generate_content(user_prompt + suffix)
        return _from_response(response)
    except Exception:
        return None


def swagbot_task(
    input_data: Dict[str, Any], config: Optional[Dict[str, Any]] = None
) -> str:
    """One categorization call per row: system prompt + user text, returns category triple string."""
    model_id = (config or {}).get("model_id") or (
        Config.CATEGORIZATION_MODEL_ID or Config.MODEL_ID
    )
    user_request = get_user_request(input_data)
    if not user_request:
        return ""

    system_prompt = load_system_prompt()
    try:
        return call_vertex_gemini(user_request, system_prompt, model_id)
    except Exception as e:
        return f"[ERROR] {type(e).__name__}: {e}"


# Allowed categories: "Categorize user queries" in gemini-system-prompt.txt
ALLOWED_CATEGORIES = frozenset(
    {
        "Help-Customer-Service",
        "Product-Information",
        "Promotion",
        "Feedback",
        "Other",
        "Final",
    }
)

SEP = '":"'


def parse_swagbot_triple(line: str) -> Optional[Tuple[str, str, str]]:
    """Parse a single-line ``"category":"user_response":"reason"`` (middle may contain ``":"``)."""
    if not line or not isinstance(line, str):
        return None
    s = line.strip()
    if s.startswith("[ERROR]") or SEP not in s:
        return None
    chunks = s.split(SEP)
    if len(chunks) < 3:
        return None
    cat = chunks[0].strip()
    if cat.startswith('"'):
        cat = cat[1:]
    reason = chunks[-1].strip()
    if reason.endswith('"'):
        reason = reason[:-1]
    middle = SEP.join(chunks[1:-1])
    return (cat, middle, reason)


def reference_category_and_middle(expected_output: Any) -> Tuple[Optional[str], Optional[str]]:
    """Ground truth category + user-facing (middle) segment from expected_output."""
    if expected_output is None:
        return None, None
    if isinstance(expected_output, str):
        s = expected_output.strip()
        # JSON messages / objects contain many ``":"`` substrings; never parse those as a triple first.
        if s.startswith(("[", "{")):
            try:
                return reference_category_and_middle(json.loads(s))
            except (json.JSONDecodeError, TypeError):
                pass
        t = parse_swagbot_triple(s)
        if t:
            return t[0], t[1]
        try:
            return reference_category_and_middle(json.loads(s))
        except (json.JSONDecodeError, TypeError):
            return None, None
    if isinstance(expected_output, list):
        for msg in reversed(expected_output):
            if not isinstance(msg, dict):
                continue
            role = (msg.get("role") or "").lower()
            if role != "assistant":
                continue
            content = msg.get("content")
            if content is None:
                continue
            t = parse_swagbot_triple(str(content).strip())
            if t:
                return t[0], t[1]
        return None, None
    if isinstance(expected_output, dict):
        if "messages" in expected_output:
            return reference_category_and_middle(expected_output["messages"])
        for key in ("expected_output", "output", "value", "content"):
            if key in expected_output:
                return reference_category_and_middle(expected_output[key])
    return None, None


def format_and_category(
    input_data: Any, output_data: str, expected_output: Any
) -> EvaluatorResult:
    """Valid ``"a":"b":"c"`` line and category is one of the six allowed names."""
    if not output_data or output_data.startswith("[ERROR]"):
        return EvaluatorResult(
            value=False,
            reasoning="Empty or error output",
            assessment="fail",
        )
    t = parse_swagbot_triple(output_data)
    if not t:
        return EvaluatorResult(
            value=False,
            reasoning="Not a parseable category:user_response:reason line",
            assessment="fail",
        )
    cat, _, _ = t
    ok = cat in ALLOWED_CATEGORIES
    return EvaluatorResult(
        value=ok,
        reasoning=(
            f"Category {cat!r} is allowed"
            if ok
            else f"Category {cat!r} not in {sorted(ALLOWED_CATEGORIES)}"
        ),
        assessment="pass" if ok else "fail",
    )


def category_matches_expected(
    input_data: Any, output_data: str, expected_output: Any
) -> EvaluatorResult:
    """Model category must equal reference category from expected_output."""
    ref_cat, _ = reference_category_and_middle(expected_output)
    if not ref_cat:
        return EvaluatorResult(
            value=True,
            reasoning="No reference category in expected_output; skipped",
            assessment="pass",
        )
    t = parse_swagbot_triple(output_data or "")
    if not t:
        return EvaluatorResult(
            value=False,
            reasoning="Model output not parseable as triple",
            assessment="fail",
        )
    mod_cat = t[0]
    ok = mod_cat == ref_cat
    return EvaluatorResult(
        value=ok,
        reasoning=(
            f"Category {mod_cat!r} matches reference {ref_cat!r}"
            if ok
            else f"Category {mod_cat!r} != reference {ref_cat!r}"
        ),
        assessment="pass" if ok else "fail",
    )


def response_anchors_match_expected(
    input_data: Any, output_data: str, expected_output: Any
) -> EvaluatorResult:
    """Vertex Gemini judge on the user-facing (middle) segment of the triple.

    With a reference middle from ``expected_output``: require factual alignment (paraphrase
    allowed). Without a reference: flag concrete claims not supported by the user message
    alone. Model: ``Config.DD_SWAGBOT_RESPONSE_EVAL_MODEL``.
    """
    t = parse_swagbot_triple(output_data or "")
    if not t:
        return EvaluatorResult(
            value=False,
            reasoning="Model output not parseable; cannot evaluate user-facing segment",
            assessment="fail",
        )
    _, model_middle, _ = t
    if not str(model_middle).strip():
        return EvaluatorResult(
            value=False,
            reasoning="Empty user-facing (middle) segment",
            assessment="fail",
        )

    _, ref_middle = reference_category_and_middle(expected_output)
    ref_text = (ref_middle or "").strip()
    user_request = get_user_request(input_data)

    user_prompt = (
        "Evaluate ONLY the user-facing reply (middle segment) below.\n\n"
        f"USER_MESSAGE:\n{user_request}\n\n"
        f"REFERENCE_USER_FACING (may be empty; if empty, use hallucination mode B):\n{ref_text}\n\n"
        f"MODEL_USER_FACING_TO_EVALUATE:\n{model_middle}\n"
    )

    eval_model = Config.DD_SWAGBOT_RESPONSE_EVAL_MODEL
    parsed = call_vertex_gemini_judge_json(user_prompt, eval_model)

    if not parsed:
        return EvaluatorResult(
            value=False,
            reasoning="Gemini evaluator returned no parseable JSON",
            assessment="fail",
        )

    raw_pass = parsed.get("pass")
    if isinstance(raw_pass, str):
        ok = raw_pass.strip().lower() in ("true", "yes", "1", "pass")
    else:
        ok = bool(raw_pass)
    reason = str(parsed.get("reasoning") or "").strip() or (
        "pass" if ok else "fail"
    )
    mode = "reference alignment" if ref_text else "hallucination check"
    return EvaluatorResult(
        value=ok,
        reasoning=f"[{mode} via {eval_model}] {reason}",
        assessment="pass" if ok else "fail",
    )


def build_quality_judge():
    """LLM-as-judge for response quality (optional, requires OPENAI_API_KEY)."""
    if not HAS_LLM_JUDGE or not Config.OPENAI_API_KEY:
        return None
    return LLMJudge(
        provider="openai",
        model=os.environ.get("DD_LLM_JUDGE_MODEL", "gpt-4o-mini"),
        user_prompt=(
            "Rate the quality of this chatbot response (1-10). Consider: helpfulness, "
            "relevance, tone, and correctness.\n\n"
            "User input: {{input_data}}\n\n"
            "Model output: {{output_data}}\n\n"
            "Expected output (if any): {{expected_output}}"
        ),
        structured_output=ScoreStructuredOutput(
            description="Quality score 1-10",
            min_score=1,
            max_score=10,
            reasoning=True,
            min_threshold=6,
        ),
        name="quality_score",
    )


def build_accuracy_judge():
    """LLM-as-judge for accuracy (optional, requires OPENAI_API_KEY)."""
    if not HAS_LLM_JUDGE or not Config.OPENAI_API_KEY:
        return None
    return LLMJudge(
        provider="openai",
        model=os.environ.get("DD_LLM_JUDGE_MODEL", "gpt-4o-mini"),
        user_prompt=(
            "Is this response accurate and correct given the user input and (if provided) expected output?\n\n"
            "User input: {{input_data}}\n\n"
            "Model output: {{output_data}}\n\n"
            "Expected output (reference): {{expected_output}}"
        ),
        structured_output=BooleanStructuredOutput(
            description="Response is accurate",
            reasoning=True,
            pass_when=True,
        ),
        name="accuracy_judge",
    )


def create_dataset_from_project_export_csv(
    csv_path: Path,
    dataset_name: str,
    project_name: str,
    description: str,
) -> None:
    """Upload a Datadog LLM Obs project export CSV as a new dataset in ``project_name``."""
    csv_path = csv_path.expanduser().resolve()
    if not csv_path.is_file():
        _cli_section("Create dataset")
        print(f"  Error: CSV file not found: {csv_path}")
        sys.exit(1)

    _cli_section("Create dataset from CSV")
    _cli_kv("CSV file", str(csv_path))
    _cli_kv("New dataset name", dataset_name)
    _cli_kv("Datadog project", project_name)
    _cli_kv("Datadog site", Config.DD_SITE)

    os.environ.setdefault("DD_TRACE_ENABLED", "true")
    LLMObs.enable(
        api_key=Config.DD_API_KEY,
        app_key=Config.DD_APP_KEY,
        site=Config.DD_SITE,
        project_name=project_name,
        agentless_enabled=False,
    )
    try:
        ensure_llm_obs_project(project_name)
        print(f"  Ensured project {project_name!r} exists (created if it was missing).")
    except Exception as e:
        print(f"  Warning: could not ensure project ({e}). Continuing with dataset upload.")

    try:
        dataset = LLMObs.create_dataset_from_csv(
            csv_path=str(csv_path),
            dataset_name=dataset_name,
            input_data_columns=["input"],
            expected_output_columns=["expected_output"],
            metadata_columns=["id", "metadata", "tags", "created_at", "updated_at"],
            description=description,
            project_name=project_name,
        )
    except Exception as e:
        print(f"  Error: could not create dataset ({e}).")
        sys.exit(1)

    n = len(dataset)
    print(f"  Created dataset with {n} record(s).")
    url = getattr(dataset, "url", None)
    if url:
        print(f"  Open in Datadog: {url}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Compare Vertex Gemini models on a Swagbot LLM Observability dataset.",
    )
    parser.add_argument(
        "--list-datasets",
        action="store_true",
        help="List projects and datasets in Datadog (use to find exact project/dataset names).",
    )
    parser.add_argument(
        "--project",
        default=None,
        metavar="NAME",
        help="Project name (default: DD_LLMOBS_PROJECT_NAME or 'swagbot_model_optimization').",
    )
    parser.add_argument(
        "--dataset",
        default=None,
        metavar="NAME",
        help="Dataset name (default: DD_LLMOBS_DATASET_NAME or 'Slowest Spans').",
    )
    parser.add_argument(
        "--create-dataset-from-csv",
        nargs="?",
        const=str(DEFAULT_SWAGBOT_EXPORT_CSV),
        default=None,
        metavar="CSV_PATH",
        help=(
            "Create a new LLM Observability dataset from a project export CSV. "
            f"Default file when the flag is used with no path: {DEFAULT_SWAGBOT_EXPORT_CSV.name}. "
            "Maps columns input, expected_output, and id/metadata/tags/created_at/updated_at."
        ),
    )
    parser.add_argument(
        "--new-dataset-name",
        default="swagbot_dataset",
        metavar="NAME",
        help="Name of the dataset to create with --create-dataset-from-csv (default: swagbot_dataset).",
    )
    parser.add_argument(
        "--create-dataset-description",
        default="Swagbot scenarios imported from project export CSV (replay traces).",
        metavar="TEXT",
        help="Description stored on the new dataset (default: short Swagbot import blurb).",
    )
    args = parser.parse_args()

    api_key = Config.DD_API_KEY
    app_key = Config.DD_APP_KEY
    if not api_key or not app_key:
        _cli_section("Missing Datadog credentials")
        print("This script needs DD_API_KEY and DD_APP_KEY in the environment (for example in docker-compose).")
        print("Create an application key under:")
        print("  Datadog web UI: Organization Settings, then API Keys, then Application Keys.")
        sys.exit(1)

    project_name = args.project or Config.DD_LLMOBS_PROJECT_NAME
    dataset_name = args.dataset or Config.DD_LLMOBS_DATASET_NAME

    if args.list_datasets:
        list_projects_and_datasets(api_key, app_key, Config.DD_SITE)
        return

    if args.create_dataset_from_csv is not None:
        create_dataset_from_project_export_csv(
            csv_path=Path(args.create_dataset_from_csv),
            dataset_name=args.new_dataset_name,
            project_name=project_name,
            description=args.create_dataset_description,
        )
        return

    _cli_section("Swagbot model experiments")
    _cli_kv("Datadog project", project_name)
    _cli_kv("Dataset", dataset_name)
    _cli_kv("GCP project", Config.GCP_PROJECT_ID)
    _cli_kv("GCP location", Config.GCP_LLM_LOCATION)
    _cli_kv("Datadog site", Config.DD_SITE)
    _cli_kv(
        "Experiment max records",
        str(Config.DD_LLMOBS_EXPERIMENT_MAX_RECORDS),
    )
    if not SYSTEM_PROMPT_PATH.exists():
        print()
        print(f"Error: system prompt file not found: {SYSTEM_PROMPT_PATH}")
        print("Check MODEL_SYS_INSTRUCTIONS and volume mounts in docker-compose.yml.")
        sys.exit(1)

    # Agent-backed LLM Obs (same stack as Swagbot + DD_AGENT_HOST)
    os.environ.setdefault("DD_TRACE_ENABLED", "true")
    LLMObs.enable(
        api_key=api_key,
        app_key=app_key,
        site=Config.DD_SITE,
        project_name=project_name,
        agentless_enabled=False,
    )

    _cli_section("LLM Observability project")
    try:
        ensure_llm_obs_project(project_name)
        print(f"  Project {project_name!r} is ready (created if it was missing).")
    except Exception as e:
        print(f"  Warning: could not ensure project ({e}). Pull may still work if the project exists.")

    vertexai.init(project=Config.GCP_PROJECT_ID, location=Config.GCP_LLM_LOCATION)
    _cli_kv("Response evaluator (Gemini)", Config.DD_SWAGBOT_RESPONSE_EVAL_MODEL)

    # Pull existing dataset from Datadog (API: dataset_name, project_name, version)
    # https://docs.datadoghq.com/llm_observability/experiments/datasets#retrieving-a-dataset
    _cli_section("Loading dataset")
    print(f"  Requesting dataset {dataset_name!r} from project {project_name!r} ...")
    try:
        dataset = LLMObs.pull_dataset(
            dataset_name=dataset_name,
            project_name=project_name,
        )
    except Exception as e:
        print(f"  Error: could not pull dataset ({e}).")
        print(f"  Check that dataset {dataset_name!r} exists in project {project_name!r}.")
        print("  Tip: run this script with --list-datasets to print valid names.")
        sys.exit(1)

    try:
        n_records = len(dataset)
    except (TypeError, AttributeError):
        n_records = 0
    if n_records == 0:
        print("  Error: dataset has no records. Add records in Datadog LLM Experiments.")
        sys.exit(1)
    n_run = min(n_records, Config.DD_LLMOBS_EXPERIMENT_MAX_RECORDS)
    print(f"  Loaded {n_records} record(s) from Datadog.")
    print(
        f"  Each experiment will use the first {n_run} record(s) "
        f"(limit from DD_LLMOBS_EXPERIMENT_MAX_RECORDS, default 10)."
    )

    evaluators = [
        format_and_category,
        category_matches_expected,
        response_anchors_match_expected,
    ]
    quality_judge = build_quality_judge()
    accuracy_judge = build_accuracy_judge()
    if quality_judge:
        evaluators.append(quality_judge)
    if accuracy_judge:
        evaluators.append(accuracy_judge)

    _cli_section("Running experiments")
    n_models = len(MODELS_TO_RUN)
    experiment_urls = []
    for i, model_id in enumerate(MODELS_TO_RUN, start=1):
        name = f"swagbot-model-{model_id.replace('.', '_')}"
        print(f"  [{i}/{n_models}] {name}")
        print(f"      Model: {model_id}")
        try:
            experiment = LLMObs.experiment(
                name=name,
                task=swagbot_task,
                dataset=dataset,
                evaluators=evaluators,
                description=f"Swagbot model comparison: {model_id} (latency/cost vs quality)",
                config={"model_id": model_id},
            )
            experiment.run(
                jobs=5,
                raise_errors=False,
                sample_size=Config.DD_LLMOBS_EXPERIMENT_MAX_RECORDS,
            )
            url = getattr(experiment, "url", None)
            if url:
                experiment_urls.append((model_id, url))
                print(f"      Status: finished")
                print(f"      Open in Datadog: {url}")
            else:
                print("      Status: finished (no experiment URL returned)")
        except Exception as e:
            print(f"      Status: failed ({e})")

    _cli_section("Summary")
    if experiment_urls:
        print("Experiment links:")
        for model_id, url in experiment_urls:
            print(f"  {model_id}")
            print(f"    {url}")
    else:
        print("No experiment URLs were returned. Check Datadog LLM Observability for recent runs.")
    print()


if __name__ == "__main__":
    main()
