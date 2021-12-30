import os
import json
import urllib3
from datetime import date

# configs
DD_API_KEY = 'REPLACE_ME'
DD_APP_KEY = 'REPLACE_ME'
BACKUP_PATH = 'REPLACE_ME'
BACKUP_MONITORS = True
BACKUP_ONLY_MONITORS_WITH_THESE_TAGS = []  # if [], all monitors get backed up
BACKUP_ALL_DASHBOARDS = True

def send_status_update(http_pack, update):
	http_pack['http'].request(
		'POST',
		'https://api.datadoghq.com/api/v1/events',
		headers=http_pack['headers'],
		body=json.dumps({
			'title': update['title'],
			'text': update['text'],
			'alert_type': update['status'],
			'tags': 'source:datadog-backup'
		})
	)

def main():

    http = urllib3.PoolManager()
    headers = {
    	'Content-Type': 'application/json',
    	'DD-API-KEY': DD_API_KEY,
    	'DD-APPLICATION-KEY': DD_APP_KEY
    }

    datestr = date.today().strftime("%Y-%m-%d")

    # backup montiors
    try:
        monsToBackup = []
        if BACKUP_MONITORS:
            params = {}
            if BACKUP_ONLY_MONITORS_WITH_THESE_TAGS:
                params['monitor_tags'] = BACKUP_ONLY_MONITORS_WITH_THESE_TAGS.join(',')
            url = 'https://api.datadoghq.com/api/v1/monitor'
            monsToBackup = json.loads(http.request('GET', url, fields=params, headers=headers).data)

            if not os.path.exists(os.path.join(BACKUP_PATH, 'monitors', datestr)):
                os.makedirs(os.path.join(BACKUP_PATH, 'monitors', datestr))

            for mon in monsToBackup:
                filename = '{0}_{1}.json'.format(mon['id'], mon['name'])
                with open(os.path.join(BACKUP_PATH, 'monitors', datestr, filename), 'w') as f:
                    f.write(json.dumps(mon))

        send_status_update(
    		http_pack={'http': http, 'headers': headers},
    		update={
    			'title': 'monitor backup successful',
    			'text': 'successfully backed up {0} monitors'.format(len(monsToBackup)),
    			'status': 'info'
    		}
    	)
        pass
    except Exception as e:
        error_message = (str(e)[:3500] + '..') if len(str(e)) > 3500 else str(e)
        send_status_update(
    		http_pack={'http': http, 'headers': headers},
    		update={
    			'title': 'monitor backup failed',
    			'text': '%%% \nfailed to back up monitors with error: \n```\n{0}\n```\n\n %%%'.format(str(error_message)),
    			'status': 'error'
    		}
    	)
        raise

    # backup dashbaords
    try:
        dashToBackup = []
        if BACKUP_ALL_DASHBOARDS:
            # get list of dashboards
            dashToBackup = json.loads(http.request('GET', 'https://api.datadoghq.com/api/v1/dashboard', headers=headers).data)['dashboards']
            
            if not os.path.exists(os.path.join(BACKUP_PATH, 'dashboards', datestr)):
                os.makedirs(os.path.join(BACKUP_PATH, 'dashboards', datestr))

            for dash in dashToBackup:
                filename = '{0}_{1}.json'.format(dash['id'], dash['title'])
                dash_cont = json.loads(http.request('GET', 'https://api.datadoghq.com/api/v1/dashboard/{0}'.format(dash['id']), headers=headers).data)
                with open(os.path.join(BACKUP_PATH, 'dashboards', datestr, filename), 'w') as f:
                    f.write(json.dumps(dash_cont))

        send_status_update(
            http_pack={'http': http, 'headers': headers},
            update={
                'title': 'dashboard backup successful',
                'text': 'successfully backed up {0} dashboards'.format(len(dashToBackup)),
                'status': 'info'
            }
        )
        pass
    except Exception as e:
        error_message = (str(e)[:3500] + '..') if len(str(e)) > 3500 else str(e)
        send_status_update(
            http_pack={'http': http, 'headers': headers},
            update={
                'title': 'dashboard backup failed',
                'text': '%%% \nfailed to back up dashboards with error: \n```\n{0}\n```\n\n %%%'.format(error_message),
                'status': 'error'
            }
        )
        raise


if __name__ == "__main__":
    main()
