import click

from config import ensure_authentication


@click.command()
@click.option(
    "-c", "--collection", required=True, help="Name of the secret ßcollection"
)
@click.option("-f", "--from-file", default="", help="Path to secret file")
@click.option("--from-literal", default="", help="Secret string")
@click.option("--name", required=True, help="Path to secret file")
def create(collection, from_file, from_literal):
    """Create a new secret in the specified collection."""

    ensure_authentication()

    pass
