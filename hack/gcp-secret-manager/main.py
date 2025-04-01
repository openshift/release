#!/usr/bin/env python3
import click
from commands.login import login
from commands.list import list
from commands.create import create
from commands.delete import delete
from commands.get_service_account import get_service_account


@click.group()
def cli():
    """CLI tool to manage secrets in Google Secret Manager."""
    pass


cli.add_command(login)
cli.add_command(list)
cli.add_command(create)
cli.add_command(get_service_account)
cli.add_command(delete)

if __name__ == "__main__":
    cli()
