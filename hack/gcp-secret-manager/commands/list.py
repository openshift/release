# Ignore dynamic imports
# pylint: disable=E0401, C0413

import json
from typing import Dict, List

import click
from google.cloud import secretmanager
from util import (
    ensure_authentication,
    get_group_collections,
    get_secrets_from_index,
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
        raise click.ClickException(
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
            for collection in collections:
                click.echo(f"- {collection}")


def list_collections_for_group(
    collections_dict: Dict[str, List[str]], group: str, output: str
):
    if group and group not in collections_dict:
        click.echo(f"Group '{group}' has no secret collections")
        return

    if output == "json":
        click.echo(json.dumps(collections_dict[group], indent=2))
    else:
        for collection in collections_dict[group]:
            click.echo(f"{collection}")


def list_secrets_for_collection(collection: str, output: str):
    secret_list = get_secrets_from_index(
        secretmanager.SecretManagerServiceClient(), collection
    )
    if output == "json":
        click.echo(json.dumps(secret_list, indent=2))
    else:
        for secret in secret_list:
            click.echo(secret)
