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
                timing = duration_type(timing, span["meta"]["kind"])
                span["start_ns"] = timing["start_ns"]
                span["duration"] = timing["duration"]
                value = span["start_ns"]
                logger.debug(f"Found start nanosec {value}")
            else:
                logger.error(f"could not craft durations in json !")
        # set root span duration
        total_duration = timing["start_ns"]+timing["duration"]-ori_ns
        my_json["data"]["attributes"]["spans"][0]["duration"] = total_duration
        my_json["data"]["attributes"]["spans"][0]["start_ns"] = ori_ns
        #with open('data.json', 'w') as f:
        #    json.dump(my_json, f)
        send_trace(my_json)
    except Exception as e:
        logger.error(f"failed to process json with error {str(e)}", exc_info=True)
                
# Generate duration for llm traces
def gen_duration():
    chooser = random.randint(0,100)
    value = 0
    # 5% of cases would be very long trace 8 and 12 sec 
    if chooser < 5:
        value = random.randint(8000,12000)
    # a bit less than half time between 4 and 6 sec
    elif chooser < 50:
        value =  random.randint(4000,6000)
    # otherwise between 1 and 3
    else:
        value = random.randint(1200,3000)
    logger.info(f"generated duration {value}")
    return value

# Get duration for type will return new_start, total_duration, duration
def duration_type(timing, kind):
    # if type workflow generate random duration
    timing_task = 55*1000*1000
    result = {
        "start_ns": timing["start_ns"],
        "duration": timing["duration"],
        "duration_left": timing["duration_left"]
    }
    if (kind == "workflow"):
        result["start_ns"] = timing["start_ns"]+timing["duration"]+10
        result["duration"] = gen_duration()*1000*1000
    elif (kind == "task"):
        result["start_ns"] = timing["start_ns"]+timing["duration"]
        result["duration"] = timing_task
    elif (kind == "retrieval"):
        if result["duration_left"] > 0:
            # we are on the second retrieval span
            result["start_ns"] = timing["start_ns"]+timing["duration"]
            result["duration"] = random.randint(200,500)*1000*1000
            result["duration_left"] = timing["duration_left"]-result["duration"]
        else:
            result["start_ns"] = timing["start_ns"]
            result["duration"] = random.randint(200,500)*1000*1000
            result["duration_left"] = timing["duration"]-result["duration"]
    elif (kind == "tool"):
        if timing["duration_left"] > 0:
            result["start_ns"] = timing["start_ns"]+timing["duration"]
            result["duration"] = timing["duration_left"]-timing_task
            result["duration_left"]=0
        else:
            result["duration"] = timing["duration"]-timing_task
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
    time.sleep(90)