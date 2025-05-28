# Ignore dynamic imports
# pylint: disable=E0401, C0413

import json
from typing import Dict, List

import click
from google.api_core.exceptions import PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    ensure_authentication,
    get_group_collections,
    validate_collection,
)


@click.command("list")
@click.option(
    "-o",
    "--output",
    type=click.Choice(["json", "text"], case_sensitive=False),
    default="text",
    help="Output format, defaults to plain text but can be set to 'json'. Only applicable when a collection or a group is specified.",
)
@click.option(
    "-c",
    "--collection",
    default="",
    help="Name of the secret collection. Use this option to list all secrets belonging to a specific collection.",
    callback=validate_collection,
)
@click.option(
    "-g",
    "--group",
    default="",
    help="Use this option to list all secret collections for a group.",
)
def list_secrets(output: str, collection: str, group: str):
    """
    List secrets from the specified collection.
    If no collection is provided, lists all secret collections.
    """
    if collection != "" and group != "":
        raise click.UsageError(
            "--collection and --group cannot both be set at the same time"
        )

    if collection != "":
        ensure_authentication()
        list_secrets_for_collection(collection, output)
        return

    collections_dict = get_group_collections()
    if group != "":
        list_collections_for_group(collections_dict, group, output)
    else:
        list_all_collections(collections_dict, output)


def list_all_collections(collections_dict: Dict, output: str):
    if output == "json":
        click.echo(json.dumps(collections_dict, indent=2))
    else:
        for group_name, collections in collections_dict.items():
            click.echo(f"{group_name}:")
            for c in collections:
                click.echo(f"- {c}")


def list_collections_for_group(
    collections_dict: Dict[str, List[str]], group: str, output: str
):
    if group and group not in collections_dict:
        click.echo(f"Group '{group}' has no secret collections")
        return

    if output == "json":
        click.echo(json.dumps(collections_dict[group], indent=2))
    else:
        for c in collections_dict[group]:
            click.echo(f"{c}")


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
