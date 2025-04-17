import click
import re
import requests
import yaml
import json

from google.cloud import secretmanager
from config import *


@click.command()
@click.option("-o", "--output", default="json")
@click.option("-c", "--collection", default="", help="Name of the secret collection")
def list(output, collection):
    """
    Lists secrets from the specified collection, or,
    if no collection is provided, lists all secret collections.
    """

    if collection == "":
        list_collections()
    else:
        if collection_is_valid(collection) == False:
            raise click.UsageError(
                f"Collection {collection} contains forbidden characters. Only letters, numbers and dashes are allowed."
            )
        ensure_authentication()
        list_secrets(output, collection)


def collection_is_valid(collection: str) -> bool:
    return bool(re.match("^[a-z0-9-]*$", collection.lower()))


def list_collections():
    response = requests.get(CONFIG_PATH)
    data = yaml.safe_load(response.text)

    collections = set()

    for group in data.get("groups", {}).values():
        if "secret_collections" in group:
            for c in group["secret_collections"]:
                collections.add(c)

    collections = sorted(collections)

    for c in collections:
        click.echo(c)


def list_secrets(output, collection: str):
    client = secretmanager.SecretManagerServiceClient()
    parent = f"projects/{PROJECT_ID}"
    response = client.list_secrets(
        request=secretmanager.ListSecretsRequest(
            {"parent": parent, "filter": f"name:{collection}"}
        )
    )

    # TODO: exception for when a user requests secrets from a collection they don't have access for

    stripped = []
    for secret in response:
        stripped.append(secret.name.split("/")[-1])
    if output == "json":
        click.echo(json.dumps(stripped))
    else:
        click.echo(stripped)  # TODO: format output
