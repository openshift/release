# Why are we using Secrets?

To avoid leaking of internal resources, we create secrets to `vault.ci.openshift.org` under `/kv/selfservice/trigger/token`. The docs to describe that process are [here](https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/).

# How do I generate a token dpu operator key in Jenkins?

In order to generate it, look at the `dpu-key` in the vault. For the corresponding job, click configure. Select `trigger builds remotely`. From there enter the matching `dpu-key` as the authentication. Apply and save.

# How does this Jenkins integration work?

This Jenkins integration works by using build remote triggers in Jenkins to fire off curl requests from the PROW Pod to the NHE internal server lab. The Jenkins job passes in an authentication token and pull number into the request which allows the job to access data. In order to specify the curl_request, go to the server configuration settings click on this project is parameterized and add a string parameter called `pullnumber`. If multiple PR's are pending, this also creates a basic queue system in order to make sure that multiple requests are not fired at the same time. After the job is done running, the script will evaluate the last build's API to check whether the test passed/fail?

# Where is PULL_NUMBER defined?

`PULL_NUMBER` is part of the env variables on the PROW pod. It is described [here](https://docs.prow.k8s.io/docs/overview/).

# What does the telco-runner image look like?

You can find the telco-runner image configuration [here](https://github.com/openshift/release/blob/master/clusters/app.ci/supplemental-ci-images/telco-runner.yaml).
