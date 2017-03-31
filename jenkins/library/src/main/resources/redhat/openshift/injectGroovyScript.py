#!/usr/bin/env python

import sys

from yaml import load, dump

template_path = sys.argv[1]
script_path = sys.argv[2]
generated_template_path = sys.argv[3]

with open(template_path) as template_file:
	template = load(template_file)

	with open(script_path) as script_file:
		template[0]['job']['builders'][0]['system-groovy']['command'] = script_file.read()

with open(generated_template_path, 'w+') as generated_template_file:
	generated_template_file.write(dump(template, default_flow_style=False))