#!/bin/bash

bash -c "echo > /dev/tcp/ldap.corp.redhat.com/389" && echo "LDAP OK" || echo "LDAP BAD"
