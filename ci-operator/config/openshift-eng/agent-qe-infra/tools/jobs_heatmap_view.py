#!/usr/bin/env python3

from datetime import datetime
import glob
import sys
import yaml
import plotly.graph_objects as go
from cron_converter import Cron

class ConfigReader():
    def __init__(self, version):
        self.raise_if_eol(version)
        self.files = glob.glob(f'../openshift-openshift-tests-private-release-{version}__[am]*')
        self.jobs = self.get_all_jobs()

    def raise_if_eol(self, version):
        versions = ['4.14', '4.13', '4.12', '4.11', '4.10']
        if version not in versions:
            raise ValueError(f'Version "{version}" is EOL')

    def get_all_jobs(self):
        jobs = []
        for file in self.files:
            jobs_this_file = self.get_jobs_from_file(file)
            jobs += jobs_this_file
        return jobs

    def get_jobs_from_file(self, file):
        data = self.read_file(file)
        return data['tests']

    def read_file(self, file):
        with open(file, encoding="utf-8") as content:
            data = yaml.safe_load(content)
        return data

    def populate_heatmap_data(self):
        data = self.init_heatmap_data()
        for job in self.jobs:
            cron_instance = Cron(job['cron'])
            cron_instance_list = cron_instance.to_list()

            hours = cron_instance_list[1]
            days = cron_instance_list[2]
            months = cron_instance_list[3]

            this_month = datetime.today().month
            if this_month not in months:
                continue

            # print(f'{job["as"]}, {job["cron"]}') # uncomment to display job/cron to console
            for hour in hours:
                for day in days:
                    data[hour][day] += 1
        return data

    def init_heatmap_data(self):
        days = 32
        hours = 24
        return [[0 for i in range(days)] for j in range(hours)]

def render_heatmap(version):
    config_reader = ConfigReader(version)
    heatmap_data = config_reader.populate_heatmap_data()

    fig = go.Figure(data=go.Heatmap(
            z=heatmap_data,
            text=heatmap_data,
            texttemplate="%{text}",
            x=list(range(0, 31)),
            y=list(range(0, 24)),
            colorscale='Blues'
        ))

    fig.update_layout(
            title=f'{version} jobs scheduled in this month',
            xaxis_nticks=31,
            xaxis_title='Day',
            yaxis_title='Hour',
            )

    fig.show()

def usage():
    print(f'{sys.argv[0]} version')
    sys.exit(1)

def main():
    if len(sys.argv) != 2:
        usage()

    version = sys.argv[1]
    render_heatmap(version)

if __name__ == '__main__':
    main()
