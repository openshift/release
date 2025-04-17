import click
from google.cloud import secretmanager
from config import PROJECT_ID, ensure_authentication


@click.command(name="get-sa")
@click.option(
    "-c",
    "--collection",
    required=True,
    help="Name of the secret collection",
)
def get_service_account(collection):
    """Get the service account associated with a secret collection."""

    ensure_authentication()

    secret_id = f"{collection}__updater_service_account"
    name = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"

    client = secretmanager.SecretManagerServiceClient()
    response = client.access_secret_version(request={"name": name})
    payload = response.payload.data.decode("UTF-8")

    click.echo(payload)
