import json
import os
import ijson
import time
from datetime import datetime, timedelta, UTC, timezone
import requests
from logger import getJSONLogger

logger = getJSONLogger('loggenerator')

LOGS_DIRECTORY = os.getenv("REPLAY_LOGS_DIR", ".") # this is where we will look for the JSON log files
BATCH_SIZE = int(os.getenv("REPLAY_BATCH_SIZE", "1")) # this controls how many logs we send at once to Datadog
SLEEP_TIME = int(os.getenv("REPLAY_SLEEP_TIME", "1")) # this controls how long we sleep before reading the next message from the JSON file
logger.info(f"Config dump: batch_size={BATCH_SIZE}, sleep_time={SLEEP_TIME}, logs_dir={LOGS_DIRECTORY}")

dd_api_key = os.getenv("DD_API_KEY", None) 
dd_app_key = os.getenv("DD_APP_KEY", None)
if dd_api_key is None or dd_app_key is None: 
    logger.fatal("Could not find an API key or APP key to send data to Datadog. Quitting.")
    exit(255)

logger.info("Log Replay is starting.")

def replay(): 
    logfiles = os.listdir(path=LOGS_DIRECTORY)
    logfiles.sort()
    logger.info(f"Files found in directory: {logfiles}")
    logger.info(f"Starting replay with {len(logfiles)} logfiles")
    iteration = 1
    logs_sent = 0
    for logfile in logfiles: 
        if logfile.endswith(".json"):
            logger.info(f"Starting replay of logfile {logfile}")
            fh = open(LOGS_DIRECTORY + "/" + logfile)
            logs = ijson.items(fh, 'Records.item')
            
            # Initialize batch list for this file
            batch = []
            
            # Get the oldest event time from the file
            oldest_time = None
            for log in logs:
                event_time = datetime.strptime(log['eventTime'], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
                if oldest_time is None or event_time < oldest_time:
                    oldest_time = event_time
            
            # Reset file pointer to start
            fh.seek(0)
            logs = ijson.items(fh, 'Records.item')
            
            # Calculate time difference from oldest event to now
            current_time = datetime.now(UTC)
            time_diff = current_time - oldest_time
            
            for log in logs:
                # Calculate new timestamp preserving relative time difference
                event_time = datetime.strptime(log['eventTime'], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
                time_since_oldest = event_time - oldest_time
                new_time = current_time - time_since_oldest
                log['eventTime'] = new_time.strftime("%Y-%m-%dT%H:%M:%SZ")
                
                payload = {
                    "ddsource": "cloudtrail",
                    "service": "cloudtrail",
                    "message": log
                }
                batch.append(payload)
                logs_sent += 1
                
                if logs_sent % BATCH_SIZE == 0:
                    url = 'https://http-intake.logs.datadoghq.com/api/v2/logs?ddtags=source'
                    headers = {
                        'content-type': 'application/json', 
                        'DD-API-KEY': dd_api_key,
                        'DD-APPLICATION-KEY': dd_app_key
                    }
                    r = requests.post(url, headers=headers, json=batch)
                    logger.info(f"{logs_sent} logs published")
                    batch = []
                    time.sleep(SLEEP_TIME)
            
            # Send any remaining logs
            if batch:
                url = 'https://http-intake.logs.datadoghq.com/api/v2/logs?ddtags=source'
                headers = {
                    'content-type': 'application/json', 
                    'DD-API-KEY': dd_api_key,
                    'DD-APPLICATION-KEY': dd_app_key
                }
                r = requests.post(url, headers=headers, json=batch)
                logger.info(f"{logs_sent} logs published")
                
    iteration = iteration + 1
    logger.info(f"Finished iteration {iteration}")

if __name__ == "__main__":
    replay()
