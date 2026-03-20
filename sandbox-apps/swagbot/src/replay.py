# import libraries
import uuid
import json
import re
import time
import requests
import random
from os import walk
from config import Config
from logger import setup_logger

# Setup logger
logger = setup_logger('llm-replay')

# global variable
uuids = {}

# generate span and traces uuid
def gen_uuid(name):
    global uuids
    logger.debug(f"Gathering UUID for {name}")
    # do nothing if trace name is undefined
    if name == "undefined":
        logger.debug("uuid is undefined")
        return name
    # if trace start with uuid generate one for the index
    elif re.search('^uuid', name):
        temp_uuid = uuid.uuid4()
        uuids[name] = uuids.get(name, str(temp_uuid))
        logger.debug(f"Found uuid {uuids.get(name, 'error')}")
        return uuids[name]
    else:
        return name

# List all json file to send replays
def process_replays(wait = 1):
    try:
        for (dirpath, dirnames, filenames) in walk(Config.REPLAY_PATH):
            filenames = sorted(filenames)
            for file in filenames:
                logger.info(f"Processing file {dirpath}/{file}")
                process_json(json.load(open(f'{dirpath}/{file}', 'r')))
                time.sleep(wait)
    except Exception as e:
        logger.error(f"failed to read json file {str(e)}", exc_info=True)

# Write proper json data
def process_json(my_json):
    global uuids
    # Empty UUIDS for new file
    uuids = {}
    try:
        logger.debug(f"working on json {my_json}")
        ori_ns = time.time_ns() 
        #ori_ns = 0
        timing = {
            "start_ns": ori_ns,
            "duration": 0,
            "duration_left": 0
        }
        # Loop through all spans
        for span in my_json["data"]["attributes"]["spans"]:
            logger.debug(f"working on span")
            # check if span has parent, trace and span id
            if (span["parent_id"] and span["trace_id"] and span["span_id"]):
                logger.debug("Found parent, trace and span id")
                span["parent_id"] = gen_uuid(span["parent_id"])
                span["trace_id"] = gen_uuid(span["trace_id"])
                span["span_id"] = gen_uuid(span["span_id"])
            # check if start nanosecond is set in json
            else:
                logger.error(f"Could not find parent trace and span id !")
            if (span["start_ns"] >=0 and span["meta"]["kind"] and span["duration"] >=0):
                timing = duration_type(timing, span)
                # Check if this is a task with special timing fields
                if "span_start_ns" in timing and "span_duration" in timing:
                    # Use the special fields for the span itself
                    span["start_ns"] = timing["span_start_ns"]
                    span["duration"] = timing["span_duration"]
                    # But keep the timing state for the next span (already in timing object)
                else:
                    # Normal case - use timing directly
                    span["start_ns"] = timing["start_ns"]
                    span["duration"] = timing["duration"]
                value = span["start_ns"]
                logger.debug(f"Found start nanosec {value}")
            else:
                logger.error(f"could not craft durations in json !")
        
        # Second pass: Calculate parent span durations based on children
        # Process in dependency order: tools first, then workflows
        spans = my_json["data"]["attributes"]["spans"]
        
        # First resize tools
        for span in spans:
            if span["meta"]["kind"] == "tool":
                # Find all direct children of this span
                children = [s for s in spans if s["parent_id"] == span["span_id"]]
                if children:
                    # Calculate the span to encompass all children
                    min_start = min(child["start_ns"] for child in children)
                    max_end = max(child["start_ns"] + child["duration"] for child in children)
                    
                    # Update parent span
                    span["start_ns"] = min_start
                    span["duration"] = max_end - min_start
                    logger.debug(f"Resized {span['name']} ({span['meta']['kind']}) to encompass children: {span['duration']/1000000:.0f}ms")
        
        # Then resize workflows (which depend on tools)
        for span in spans:
            if span["meta"]["kind"] == "workflow":
                # Find all direct children of this span
                children = [s for s in spans if s["parent_id"] == span["span_id"]]
                if children:
                    # Calculate the span to encompass all children
                    min_start = min(child["start_ns"] for child in children)
                    max_end = max(child["start_ns"] + child["duration"] for child in children)
                    
                    # Update parent span
                    span["start_ns"] = min_start
                    span["duration"] = max_end - min_start
                    logger.debug(f"Resized {span['name']} ({span['meta']['kind']}) to encompass children: {span['duration']/1000000:.0f}ms")
        
        # Update timing state for next workflow after resizing
        workflows = [s for s in spans if s["meta"]["kind"] == "workflow"]
        if workflows:
            last_workflow = workflows[-1]
            last_workflow_end = last_workflow["start_ns"] + last_workflow["duration"]
            timing["start_ns"] = last_workflow_end
            timing["duration"] = 0
        
        # Set root span duration to encompass all children
        if len(spans) > 1:
            all_children = spans[1:]  # All spans except root
            max_end = max(child["start_ns"] + child["duration"] for child in all_children)
            total_duration = max_end - ori_ns
        else:
            total_duration = 0
        my_json["data"]["attributes"]["spans"][0]["duration"] = total_duration
        my_json["data"]["attributes"]["spans"][0]["start_ns"] = ori_ns
        #with open('data.json', 'w') as f:
        #    json.dump(my_json, f)
        send_trace(my_json)
    except Exception as e:
        logger.error(f"failed to process json with error {str(e)}", exc_info=True)
                
# Generate duration for llm traces - model-aware with workflow context
def gen_duration(model_name=None, workflow_name=None):
    chooser = random.randint(0,100)
    value = 0
    
    # Check if this is the new fast model
    if model_name == "gemini-2.5-flash-lite":
        # Fast model performance: avg ~0.95s, P90 ~1.1s
        if chooser < 10:
            value = random.randint(1100,1200)  # 10% of cases: 1.1-1.2 sec
        elif chooser < 40:
            value = random.randint(1000,1100)  # 30% of cases: 1.0-1.1 sec
        else:
            value = random.randint(800,1000)   # 60% of cases: 0.8-1.0 sec (faster)
    else:
        # Slower model performance (gemini-1.5-pro-002 or others)
        # Original slower model performance for other workflows
        if chooser < 5:
            value = random.randint(5000,12000)  # 5% of cases: 8-12 sec 
        elif chooser < 50:
            value = random.randint(4000,5000)   # 45% of cases: 4-6 sec
        else:
            value = random.randint(1200,3000)   # 50% of cases: 1.2-3 sec
    
    logger.info(f"generated duration {value}ms for model: {model_name}, workflow: {workflow_name}")
    return value

# Get duration for type will return new_start, total_duration, duration
def duration_type(timing, span):
    # if type workflow generate random duration
    timing_task = 55*1000*1000
    kind = span["meta"]["kind"]
    
    # Extract model name if this is an LLM span
    model_name = None
    if (kind == "llm" and "metadata" in span["meta"] and "model_name" in span["meta"]["metadata"]):
        model_name = span["meta"]["metadata"]["model_name"]
    
    # Extract workflow name for context-aware duration generation
    workflow_name = None
    if kind == "workflow":
        workflow_name = span["name"]
    
    result = {
        "start_ns": timing["start_ns"],
        "duration": timing["duration"],
        "duration_left": timing["duration_left"]
    }
    
    if (kind == "workflow"):
        # Workflows run sequentially - start after previous workflow finishes
        result["start_ns"] = timing["start_ns"] + timing["duration"] + 10
        # Workflow duration will be calculated later based on children
        # For now, just store the start position
        result["duration"] = 0  # Will be updated after processing children
        result["workflow_start"] = result["start_ns"]
        result["workflow_needs_sizing"] = True
        
    elif (kind == "retrieval"):
        # Retrieval spans start at workflow start (they run first)
        result["start_ns"] = timing.get("workflow_start", timing["start_ns"])
        result["duration"] = random.randint(200,500)*1000*1000
        # Store retrieval context for tool siblings
        result["retrieval_end"] = result["start_ns"] + result["duration"]
        # Preserve other context
        result["workflow_start"] = timing.get("workflow_start", timing["start_ns"])
        result["workflow_needs_sizing"] = timing.get("workflow_needs_sizing", False)
        
    elif (kind == "tool"):
        # Tools start after any retrieval siblings complete, or at workflow start if no retrieval
        if timing.get("retrieval_end") is not None:
            result["start_ns"] = timing.get("retrieval_end") + 5*1000*1000  # Small gap after retrieval
        else:
            result["start_ns"] = timing.get("workflow_start", timing["start_ns"])
        
        # Tool duration will be calculated based on its children
        result["duration"] = 0  # Will be updated after processing children
        result["tool_start"] = result["start_ns"]
        result["tool_needs_sizing"] = True
        # Preserve context
        result["workflow_start"] = timing.get("workflow_start", timing["start_ns"])
        result["workflow_needs_sizing"] = timing.get("workflow_needs_sizing", False)
        result["retrieval_end"] = timing.get("retrieval_end")
        
    elif (kind == "llm"):
        # LLM spans start at the same time as their parent tool and get model-aware durations
        result["start_ns"] = timing.get("tool_start", timing["start_ns"])
        result["duration"] = gen_duration(model_name, None)*1000*1000
        # Preserve context
        result["tool_start"] = timing.get("tool_start", timing["start_ns"])
        result["tool_needs_sizing"] = timing.get("tool_needs_sizing", False)
        result["workflow_start"] = timing.get("workflow_start", timing["start_ns"])
        result["workflow_needs_sizing"] = timing.get("workflow_needs_sizing", False)
        result["retrieval_end"] = timing.get("retrieval_end")
        
    elif (kind == "task"):
        # Tasks start after the LLM in the same tool completes
        # We need to calculate based on the previous LLM span
        if timing.get("tool_start") is not None:
            # There was an LLM span before this task
            llm_end = timing.get("tool_start", timing["start_ns"]) + timing.get("last_llm_duration", 0)
            result["start_ns"] = llm_end + 10*1000*1000  # Small gap after LLM
        else:
            # No LLM span, start at workflow start
            result["start_ns"] = timing.get("workflow_start", timing["start_ns"])
        
        result["duration"] = timing_task
        
        # After processing this task, advance timing to end of current workflow
        # (This will be set properly when we size the workflow)
        result["workflow_start"] = timing.get("workflow_start", timing["start_ns"])
        result["workflow_needs_sizing"] = timing.get("workflow_needs_sizing", False)
        result["task_end_ns"] = result["start_ns"] + result["duration"]
    
    # Store LLM duration for task positioning
    if kind == "llm":
        result["last_llm_duration"] = result["duration"]
    else:
        result["last_llm_duration"] = timing.get("last_llm_duration", 0)
    
    return result


 
# Send trace to datadog traces API
def send_trace(data):
    logger.debug(f"Sending trace {data} to Datadog")
    headers = {
        'Content-type': 'application/json',
        'DD-API-KEY': Config.DD_API_KEY
    }
    # @TODO make it dynamic for site and endpoint
    url = 'https://api.datadoghq.com/api/intake/llm-obs/v1/trace/spans'
    response = requests.post(url, data=json.dumps(data), headers=headers, timeout=5)
    logger.debug(f"Sent with status_code {response.status_code}")
    if 200 <= response.status_code < 300:
        logger.info(f"Sent traces successfully {response.text}")
    else:
        logger.error(f"Failed to send trace to DD {response.text}")
        return 


# process_replays(1)

while 1:
    process_replays(1)
    time.sleep(60)