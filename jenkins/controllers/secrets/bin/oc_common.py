import os
from jenkinsapi.jenkins import Jenkins

from oc_requester import OpenShiftRequester


def connect_to_jenkins():
    url = os.environ.get("JENKINS_SERVICE_URL", "http://jenkins")
    r = OpenShiftRequester(url)
    j = Jenkins(baseurl=url, requester=r)
    return j
