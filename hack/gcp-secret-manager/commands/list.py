import click
import re
import requests
import yaml

from google.auth.exceptions import DefaultCredentialsError
from google.cloud import secretmanager
from constants import PROJECT_ID, CONFIG_PATH


@click.command()
@click.option("-o", "--output", default="yaml")
@click.option("-c", "--collection", default="", help="xxx")
def list(output, collection):
    """List secrets from the specified collection, or, if no collection is provided, lists all secret collections."""

    if collection == "":
        list_collections()
    else:
        if not collection_is_valid(collection):
            click.echo(
                f"Collection {collection} contains forbidden characters. Only letters, numbers and dashes are allowed."
            )
            return
        list_secrets(collection)


def collection_is_valid(collection: str) -> bool:
    return bool(re.match("^[A-Za0-9-]*$", collection))


def list_collections():
    response = requests.get(CONFIG_PATH)
    data = yaml.safe_load(response.text)

    collections = set()

    for group in data.get("groups", {}).values():
        if "clusters" in group:
            for c in group["clusters"]:
                collections.add(c)

    collections = sorted(collections)

    for c in collections:
        click.echo(c)


def list_secrets(collection: str):
    try:
        client = secretmanager.SecretManagerServiceClient()

        parent = f"projects/{PROJECT_ID}"

        response = client.list_secrets(
            request=secretmanager.ListSecretsRequest(
                {"parent": parent, "filter": f"name:{collection}__"}
            )
        )
        for secret in response:
            click.echo(secret.name)  # TODO fix printing

    except DefaultCredentialsError:
        click.echo(
            "Credentials for authenticating into google cloud not found. Please run this script with the login command."
        )
