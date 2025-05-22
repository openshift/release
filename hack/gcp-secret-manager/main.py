#!/usr/bin/env python3

# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from commands.create import create
from commands.delete import delete
from commands.get_service_account import get_service_account
from commands.list import list_secrets
from commands.login import login
from commands.update import update


@click.group()
def cli():
    """CLI tool to manage Openshift CI secrets."""


cli.add_command(login)
cli.add_command(list_secrets)
cli.add_command(create)
cli.add_command(update)
cli.add_command(delete)
cli.add_command(get_service_account)


if __name__ == "__main__":
    cli()
