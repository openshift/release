import click


@click.command()
@click.option("-c", "--collection", default="", help="Name of collection")
@click.option("-f", "--file", default="", help="Path to secret file")
def create(collection, file):
    """Create new secret in the specified collection."""
    pass
