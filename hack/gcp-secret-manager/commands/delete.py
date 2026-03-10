# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from google.api_core.exceptions import NotFound
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    ensure_authentication,
    get_secret_name,
    get_secrets_from_index,
    update_index_secret,
    validate_collection,
    validate_path,
)


@click.command("delete")
@click.option(
    "-c",
    "--collection",
    required=True,
    help="The collection the secret belongs to.",
    type=str,
    callback=validate_collection,
)
@click.argument("secret_path", required=True, callback=validate_path, metavar="SECRET_PATH")
def delete(collection: str, secret_path: str):
    """Delete a secret from the specified collection.

    The SECRET_PATH should be in the format 'group/field' (e.g., 'aws/password').
    """

    ensure_authentication()
    client = secretmanager.SecretManagerServiceClient()

    index_secrets = get_secrets_from_index(client, collection)
    secret_id_normalized = secret_path.replace("/", "__")
    if secret_id_normalized in index_secrets:
        index_secrets.remove(secret_id_normalized)
        update_index_secret(client, collection, index_secrets)

    try:
        click.echo(f"Deleting secret '{secret_path}'...")
        client.delete_secret(
            name=client.secret_path(PROJECT_ID, get_secret_name(collection, secret_path))
        )
    except NotFound:
        raise click.ClickException(
            f"Secret '{secret_path}' does not exist within the collection."
        )
    except Exception as e:
        raise click.ClickException(
            f"Failed to delete secret '{secret_path}': {e}. Please retry the delete operation."
        )

    click.echo(f"Secret '{secret_path}' successfully deleted.")
