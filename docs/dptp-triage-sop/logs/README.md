# AWS CloudWatch Logs

The @dptp-triage should run this script once a day to review the errors our services are throwing. For *every single line* returned in the error query, one of the following should occur:

 - an issue to document the error
 - a fix for the issue (this could also be removing bad logging that spams non-actionable things)
 - an exclusion rule if there's no possible fix

Run the script like:

```
$ docs/dptp-triage-sop/logs/fetch.sh errors
# or
$ docs/dptp-triage-sop/logs/fetch.sh warnings
```

## Dependencies

You'll need the AWS CLI, Python 3 and the `tabulate` Python module. On Fedora:

```
$ sudo dnf install awscli python3 python3-tabulate
```

There is a [named profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html) `openshift-ci-audit` for AWS CLI:

```
$ aws configure list-profiles
openshift-ci-audit
```
