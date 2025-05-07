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
@click.option(
    "-c",
    "--collection",
    default="",
    help="Name of the secret collection",
    callback=validate_collection,
)
@click.option(
    "-g",
    "--group",
    default="",
    help="Use this option to list all collections for a group",
)
def list_secrets(output, collection, group):
    """
    List secrets from the specified collection.
    If no collection is provided, lists all secret collections.
    """

    if collection == "":
        list_collections(group, output)
    else:
        ensure_authentication()
        list_secrets_for_collection(collection, output)


def list_collections(group: str, output: str):
    try:
        response = requests.get(CONFIG_PATH)
        data = yaml.safe_load(response.text)
    except Exception as e:
        raise click.ClickException(f"Failed to list collections: {e}")

    result = {}

    for group_name, group_data in data.get("groups", {}).items():
        collections = group_data.get("secret_collections", [])
        if collections:
            if group and group != group_name:
                continue
            result[group_name] = sorted(collections)

    if group and group not in result:
        click.echo(f"Group '{group}' has no secret collection")
        return

    if output == "json":
        click.echo(json.dumps(result, indent=2))
    else:
        for group_name, collections in result.items():
            click.echo(f"{group_name}:")
            for c in collections:
                click.echo(f"- {c}")


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
