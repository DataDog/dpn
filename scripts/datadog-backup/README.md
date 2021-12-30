# Backup Datadogh Dashboards and Monitors

You can use the scripts in this directory to schedule a periodic backup of...

1. All or some of your Datadog monitors
2. All of your Datadog dashboards

## Setup steps

### Local Cron Job

Coming soon

### AWS Lambda

1. Create an [S3 Bucket](https://s3.console.aws.amazon.com/s3/home) to upload your backups to. Optionally create a directory to contain those backups. 
2. Create a [IAM Role](https://console.aws.amazon.com/iamv2/home?#/roles) that has (A) basic Lambda execution permissions and (B) permissions to list, read, and write on your bucket (preferably only your bucket). (An example IAM role can be found under `example_iam.json`)
3. Create a [Lambda Function](https://console.aws.amazon.com/lambda/home?#/functions) with the Python 3 runtime and paste in the code from `lambda_function.py`
4. Configure your lambda function to timeout after a sufficient amount of time. You may want to set it to 5 minutes just to be safe. The more dashboards and monitors you have, the more time it will take to run.
5. Create an [AWS EventBridge rule](https://console.aws.amazon.com/events/home?#/rules?eventbus=default) to run your new lambda function on a schedule as you like (not more frequently than once per day)

### Google Cloud

Coming Soon

### Azure Cloud

Coming Soon

## Validation

When your scheduled script runs, it will generate a success or failure event in [your Datadog event stream](https://app.datadoghq.com/event/stream?tags_execution=and&show_private=true&per_page=30&query=tags%3Asource%3Add-backup-lambda&aggregate_up=false&use_date_happened=true&display_timeline=true&priority=normal&is_zoomed=false&is_auto=false&incident=true&only_discussed=false&no_user=false&abstraction_level=1&page=0&legacy=true&live=true&status=all). If you like, you can set up an [Event Monitor](https://app.datadoghq.com/monitors#create/event) to alert you when your backups fail. 

## Recovering Monitors and Dashboards from Backups

This script captures the configurations of monitors and dashboards to a location of your choice. You can recover the monitor or dashboard by copying their JSON definitions from where they are saved, and then uploading them manually in your Datadog account. For monitors, you can paste your JSON definition [here](https://app.datadoghq.com/monitors#create/import). For dashboards, you can create a new dashboard and select the "Import Dashboard JSON" option from the settings at the top right of the page ([screenshot](https://p-qkfgo2.t2.n0.cdn.getcloudapp.com/items/nOu9p6Lp/1b111b45-006d-4667-9abd-a60e5d043238.jpg?v=b4577ada0556a84e657cb2c3be02adf3)).  

## Notes

* For organizations that have more than 10,000 dashboards and monitors, this script may not be able to complete execution within the maximum timeout you can set from a cloud provider's serverless function. The script can be refactored to better handle those use cases in the future.
