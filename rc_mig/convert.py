#!/usr/bin/env python3
import json
import logging
import sys

logging.basicConfig(level=logging.DEBUG)

if len(sys.argv)!=3:
    logging.critical('need 2 args, got %d', len(sys.argv))

input_file=sys.argv[1]
output_file=sys.argv[2]

with open(input_file) as raw:
    stream = json.load(raw)

stream["metadata"].pop("creationTimestamp")
stream["metadata"].pop("generation")
stream["metadata"].pop("resourceVersion")
stream["metadata"].pop("selfLink")
stream["metadata"].pop("uid")
status=stream.pop("status")
spec_tags=stream['spec']['tags']

tags=[]
for tag in status['tags']:
    name=tag['tag']
    dIR=tag['items'][0]['dockerImageReference']
    dIR=dIR.replace('docker-registry.default.svc:5000', 'registry.svc.ci.openshift.org')
    logging.debug("%s: %s", name, dIR)
    fromImage={'kind':'DockerImage','name':dIR}
    found=False
    for spec_tag in spec_tags:
        if spec_tag['name']==name:
            found=True
            new_tag=spec_tag
            break
    if not found:
        logging.debug("Failed to find spec.tag for name: %s", name)
        new_tag={'name':name,'from':fromImage}
    new_tag['from']=fromImage
    tags.append(new_tag)

stream['spec']['tags']=tags

with open(output_file, "w") as raw:
	json.dump(stream, raw)
