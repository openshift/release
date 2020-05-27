#!/bin/env python3
"""This script query the Prometheus instance
prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com
to get the workload of Prow Job in the past 7 days and save it as a json file"""


import argparse
import json
import logging
import os
import requests


logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s:%(levelname)s:%(message)s"
    )

def main():
    """main function."""
    parser = argparse.ArgumentParser(description='Ensure prow jobs\' cluster.')
    parser.add_argument('-c', '--cookie', required=True,
                        help="the cookie which can be copied from browser")
    parser.add_argument('-o', '--output', default='',
                        help="the cookie which can be copied from browser")
    args = parser.parse_args()
    url = "https://prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/api/v1/query"
    params = {'query':'sum(increase(prowjob_state_transitions{state="pending"}[7d])) by (job_name)'}
    headers = {'Cookie': args.cookie}
    response = requests.get(url=url, params=params, headers=headers)
    logging.debug('status code is %d', response.status_code)
    path = args.output
    if path == '':
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
                            'core-services', 'sanitize-prow-jobs', 'job_volume.json')
    logging.debug('output data to %s', path)
    j = response.json()
    result = {}
    for element in j.get('data', {}).get('result', []):
        job_name = element.get('metric', {}).get('job_name', '')
        volume = int(round(float(element.get('value')[1])))
        result[job_name] = volume
    with open(path, 'w+') as out:
        out.write(json.dumps(result, indent=4, sort_keys=True))

if __name__ == '__main__':
    main()
