"""
OpenShift requester for python
"""

from jenkinsapi.utils.requester import Requester
from subprocess import check_output


class OpenShiftRequester(Requester):

    """
    Adds OpenShift bearer tokens to Jenkins requests on OpenShift
    """

    def __init__(self, baseurl=None, ssl_verify=None):
        args = {}
        if ssl_verify:
            args["ssl_verify"] = ssl_verify
        if baseurl:
            args["baseurl"] = baseurl
        super(OpenShiftRequester, self).__init__(**args)
        self.token = check_output(["oc", "whoami", "-t"]).strip()


    def get_request_dict(self, params=None, data=None, files=None, headers=None, **kwargs):
        req_dict = super(OpenShiftRequester, self).get_request_dict(params=params, data=data, files=files, headers=headers)
        auth_header = "Bearer {}".format(self.token)
        if 'headers' in req_dict:
            req_dict['headers']['Authorization'] = auth_header
        else:
            req_dict['headers'] = { "Authorization": auth_header }
        return req_dict
