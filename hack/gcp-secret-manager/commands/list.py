import json

import click
import requests
import yaml
from google.api_core.exceptions import PermissionDenied
from google.cloud import secretmanager
from util import CONFIG_PATH, PROJECT_ID, ensure_authentication, validate_collection


@click.command("list")
@click.option(
    "-o",
    "--output",
    type=click.Choice(["json", "text"], case_sensitive=False),
    default="text",
    help="Output format, defaults to plain text but can be set to 'json'. Only applicable when a collection is specified.",
)
@click.option("-c", "--collection", default="", help="Name of the secret collection")
def list_secrets(output, collection):
    """
    List secrets from the specified collection.
    If no collection is provided, lists all secret collections.
    """

    if collection == "":
        list_collections(output)
    else:
        validate_collection(collection)
        ensure_authentication()
        list_secrets_for_collection(collection, output)


def list_collections(output):
    try:
        response = requests.get(CONFIG_PATH)
        data = yaml.safe_load(response.text)
    except Exception as e:
        raise click.ClickException(f"Failed to list collections: {e}")

    collections = set()

    for group in data.get("groups", {}).values():
        if "secret_collections" in group:
            for c in group["secret_collections"]:
                collections.add(c)

    collections = sorted(collections)

    if output == "json":
        click.echo(json.dumps(sorted(list(collections)), indent=2))
    else:
        for c in collections:
            click.echo(c)


def list_secrets_for_collection(collection: str, output: str):
    client = secretmanager.SecretManagerServiceClient()
    try:
        response = client.list_secrets(
            request=secretmanager.ListSecretsRequest(
                {"parent": f"projects/{PROJECT_ID}", "filter": f"name:{collection}__"}
            )
        )
    except PermissionDenied:
        raise click.UsageError(
            f"Access denied: You do not have permission to list secrets in collection '{collection}'."
        )
    except Exception as e:
        raise click.ClickException(
            f"Failed to list secrets for collection '{collection}': {e}"
        )

    secrets = []
    for secret in response:
        s = secret.name.split("/")[-1]
        if s.startswith(f"{collection}__"):
            secrets.append(s.partition("__")[2])

    if output == "json":
        click.echo(json.dumps(secrets, indent=2))
    else:
        click.echo("\n".join(secrets))
