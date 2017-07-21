## Submit Queue turn-up

1. Create an Oauth token from the Github account that will be used for doing merges.
Make sure that this account is different from the account that will be used by prow.
Also, keep in mind that it needs to have the right permissions inside your organization
and repository in order to perform merges. Store the token as oauth_token.

https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/

The SubmitQueue can optionally listen on Github webhooks for changes in commits
in pull requests. Generate the hmac token that will be used for encrypting the webhook
payload[1] and store it as hmac_token.

At this point, you should be able to process the Submit Queue template and create
all the required resources for running the Submit Queue.

```
oc process -f submit_queue.yaml -p HMAC_TOKEN=$(cat hmac_token | base64) -p OAUTH_TOKEN=$(cat oauth_token | base64) | oc create -f -
```

1. Setup the Github webhook in the repository you want to trigger events from.
Use the address of the SubmitQueue that was exposed in the previous step plus
/webhook in the payload URL. Use the hmac token that was generated in the first
step above as the webhook secret. The content type should be application/json.
The only type of event that is needed is a Status event. Select it by clicking
on the "Let me select individual events." option.
