import json

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import PROJECT_ID, ensure_authentication, validate_collection
from google.oauth2 import service_account


@click.command(name="get-sa")
@click.option(
    "-c",
    "--collection",
    required=True,
    help="Name of the secret collection",
)
def get_service_account(collection):
    """Retrieve the service account associated with a secret collection."""

    validate_collection(collection)
    ensure_authentication()

    secret_id = f"{collection}__updater-service-account"
    name = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"

    client = secretmanager.SecretManagerServiceClient()

    try:
        response = client.access_secret_version(request={"name": name})
    except NotFound:
        raise click.UsageError(
            f"Secret '{secret_id}' not found in project '{PROJECT_ID}'"
        )
    except PermissionDenied as e:
        raise click.ClickException(
            f"Error while accessing '{secret_id}' secret: {e.message}"
        )
    except Exception as e:
        raise click.ClickException(
            f"Error while accessing '{secret_id}' secret: {e.message}"
        )

    payload = response.payload.data.decode("UTF-8")

    try:
        parsed = json.loads(payload)
        click.echo(json.dumps(parsed, indent=2))
    except json.JSONDecodeError:
        click.echo(payload)
