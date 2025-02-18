#!/bin/bash

cat "/secret/perf-dept-creds"  > /tmp/creds.sh
chmod 755 /tmp/creds.sh
source /tmp/creds.sh
es_host="$(cat /secret/es_host)"
export es_host
es_port="$(cat /secret/es_port)"
export es_port

 python3 -c "
from cloud_governance.common.ldap.ldap_search import LdapSearch

ldap = LdapSearch(ldap_host_name='ldap.corp.redhat.com')
print(ldap.get_user_details(user_name='athiruma'))
"

python3 /usr/local/cloud_governance/main.py
