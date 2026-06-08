#!/bin/bash
set -euo pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; if [[ -n "$tmpDir" ]]; then rm -rf ${tmpDir}; fi' EXIT TERM

pushd ${SHARED_DIR}
USER_NAME=$(yq-go r "install-config.yaml" "metadata.name")
base_domain=$(yq-go r "install-config.yaml" "baseDomain")
PROXY_DNS="squid.${USER_NAME}.${base_domain}"
popd

echo "Generating proxy certs..."
tmpDir=$(mktemp -d)
ROOTCA="${tmpDir}/CA"
INTERMEDIATE=${ROOTCA}/INTERMEDIATE

mkdir -p ${ROOTCA}
pushd ${ROOTCA}
mkdir certs crl newcerts private
chmod 700 private
touch index.txt
echo 1000 > serial

cat > ${ROOTCA}/openssl.cnf << EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
# Directory and file locations.
dir               = ${ROOTCA}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
# The root key and root certificate.
private_key       = \$dir/private/ca.key.pem
certificate       = \$dir/certs/ca.cert.pem
# For certificate revocation lists.
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/ca.crl.pem
crl_extensions    = crl_ext
copy_extensions   = copy
default_crl_days  = 30
# SHA-1 is deprecated, so use SHA-2 instead.
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_loose
[ policy_strict ]
# The root CA should only sign intermediate certificates that match.
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ policy_loose ]
# Allow the intermediate CA to sign a more diverse range of certificates.
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ req ]
default_bits        = 2048
distinguished_name  = ca_dn
string_mask         = utf8only
# SHA-1 is deprecated, so use SHA-2 instead.
default_md          = sha256
# Extension to add when the -x509 option is used.
x509_extensions     = v3_ca
prompt              = no
[ ca_dn ]
0.domainComponent       = "io"
1.domainComponent       = "openshift"
organizationName        = "OpenShift Origin"
organizationalUnitName  = "Proxy CI Signing CA"
commonName              = "Proxy CI Signing CA"
[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
[ usr_cert ]
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection
[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[ crl_ext ]
authorityKeyIdentifier=keyid:always
[ ocsp ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, OCSPSigning
EOF

  # create root key
uuidgen | sha256sum | cut -b -32 > capassfile

openssl genrsa -aes256 -out private/ca.key.pem -passout file:capassfile 4096 2>/dev/null
chmod 400 private/ca.key.pem

# create root certificate
echo "Create root certificate..."
openssl req -config openssl.cnf \
    -key private/ca.key.pem \
    -passin file:capassfile \
    -new -x509 -days 7300 -sha256 -extensions v3_ca \
    -out certs/ca.cert.pem 2>/dev/null

chmod 444 certs/ca.cert.pem

mkdir -p ${INTERMEDIATE}
pushd ${INTERMEDIATE}

mkdir certs crl csr newcerts private
chmod 700 private
touch index.txt
echo 1000 > serial

echo 1000 > ${INTERMEDIATE}/crlnumber

cat > ${INTERMEDIATE}/openssl.cnf << EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
# Directory and file locations.
dir               = ${INTERMEDIATE}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
# The root key and root certificate.
private_key       = \$dir/private/intermediate.key.pem
certificate       = \$dir/certs/intermediate.cert.pem
# For certificate revocation lists.
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/intermediate.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
# SHA-1 is deprecated, so use SHA-2 instead.
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_loose
[ policy_strict ]
# The root CA should only sign intermediate certificates that match.
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ policy_loose ]
# Allow the intermediate CA to sign a more diverse range of certificates.
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
prompt              = no
string_mask         = utf8only
# SHA-1 is deprecated, so use SHA-2 instead.
default_md          = sha256
# Extension to add when the -x509 option is used.
x509_extensions     = v3_ca
req_extensions      = req_ext
[ req_distinguished_name ]
0.domainComponent       = "io"
1.domainComponent       = "openshift"
organizationName        = "OpenShift Origin"
organizationalUnitName  = "CI Proxy"
commonName              = "CI Proxy"
[ req_ext ]
subjectAltName          = "DNS.1:${PROXY_DNS}"
[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
[ usr_cert ]
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection
[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[ crl_ext ]
authorityKeyIdentifier=keyid:always
[ ocsp ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, OCSPSigning
EOF

popd
uuidgen | sha256sum | cut -b -32 > intpassfile

openssl genrsa -aes256 \
    -out ${INTERMEDIATE}/private/intermediate.key.pem \
    -passout file:intpassfile 4096 2>/dev/null

chmod 400 ${INTERMEDIATE}/private/intermediate.key.pem

openssl req -config ${INTERMEDIATE}/openssl.cnf -new -sha256 \
    -key ${INTERMEDIATE}/private/intermediate.key.pem \
    -passin file:intpassfile \
    -out ${INTERMEDIATE}/csr/intermediate.csr.pem 2>/dev/null

openssl ca -config openssl.cnf -extensions v3_intermediate_ca \
    -days 3650 -notext -md sha256 \
    -batch \
    -in ${INTERMEDIATE}/csr/intermediate.csr.pem \
    -passin file:capassfile \
    -out ${INTERMEDIATE}/certs/intermediate.cert.pem 2>/dev/null

chmod 444 ${INTERMEDIATE}/certs/intermediate.cert.pem

openssl verify -CAfile certs/ca.cert.pem \
    ${INTERMEDIATE}/certs/intermediate.cert.pem

cat ${INTERMEDIATE}/certs/intermediate.cert.pem \
    certs/ca.cert.pem > ${INTERMEDIATE}/certs/ca-chain.cert.pem

chmod 444 ${INTERMEDIATE}/certs/ca-chain.cert.pem
popd

# load in certs here
echo "Loading certs..."
PROXY_CERT="$(base64 -w0 ${INTERMEDIATE}/certs/intermediate.cert.pem)"
PROXY_KEY="$(base64 -w0 ${INTERMEDIATE}/private/intermediate.key.pem)"
PROXY_KEY_PASSWORD="$(cat ${ROOTCA}/intpassfile)"

CA_CHAIN="$(base64 -w0 ${INTERMEDIATE}/certs/ca-chain.cert.pem)"
# create random uname and pw
PASSWORD="$(uuidgen | sha256sum | cut -b -32)"

HTPASSWD_CONTENTS="${USER_NAME}:$(openssl passwd -apr1 ${PASSWORD})"
HTPASSWD_CONTENTS="$(echo -e ${HTPASSWD_CONTENTS} | base64 -w0)"

KEY_PASSWORD="$(base64 -w0 << EOF
#!/bin/sh
echo ${PROXY_KEY_PASSWORD}
EOF
)"

export PROXY_URL="http://${USER_NAME}:${PASSWORD}@${PROXY_DNS}:3128/"
export TLS_PROXY_URL="https://${USER_NAME}:${PASSWORD}@${PROXY_DNS}:3130/"

echo ${PROXY_URL} > ${SHARED_DIR}/http_proxy_url
echo ${TLS_PROXY_URL} > ${SHARED_DIR}/https_proxy_url

# need a squid image with at least version 4.x so that we can do a TLS 1.3 handshake.
# 4.5:egress-http-proxy image only does up to 1.2 which podman fails to do a handshake with  https://github.com/containers/image/issues/699
PROXY_IMAGE=registry.ci.openshift.org/origin/4.18:egress-http-proxy
cat >> ${SHARED_DIR}/install-config.yaml << EOF
proxy:
  httpsProxy: ${TLS_PROXY_URL}
  httpProxy: ${PROXY_URL}
additionalTrustBundle: |
$(cat ${INTERMEDIATE}/certs/ca-chain.cert.pem | awk '{print "  "$0}')
EOF

# define squid config
SQUID_CONFIG="$(base64 -w0 << EOF
http_port 3128
sslpassword_program /squid/passwd.sh
https_port 3130 cert=/squid/tls.crt key=/squid/tls.key cafile=/squid/ca-chain.pem
cache deny all
debug_options ALL,1
shutdown_lifetime 0
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /squid/passwords
auth_param basic realm proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
EOF
)"

# define squid.sh
SQUID_SH="$(base64 -w0 << EOF
#!/bin/bash
podman run --entrypoint='["bash", "/squid/proxy.sh"]' -p 3128:3128 -p 3130:3130 --net host --volume /srv/squid:/squid:Z --volume /srv/squid/log:/var/log/squid:Z ${PROXY_IMAGE}
EOF
)"

# define proxy.sh
PROXY_SH="$(base64 -w0 << EOF
#!/bin/bash
chown -R squid:squid /var/log/squid
squid -N -f /squid/squid.conf
EOF
)"

# create ignition entries for certs and script to start squid and systemd unit entry
# create the proxy stack and then get its IP
# generate proxy ignition
cat > ${SHARED_DIR}/proxy.ign << EOF
{
  "ignition": {
    "config": {},
    "security": {
      "tls": {}
    },
    "timeouts": {},
    "version": "3.0.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": []
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/srv/squid/passwords",
        "contents": {
          "source": "data:text/plain;base64,${HTPASSWD_CONTENTS}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/tls.crt",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_CERT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/tls.key",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_KEY}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/ca-chain.pem",
        "contents": {
          "source": "data:text/plain;base64,${CA_CHAIN}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/squid.conf",
        "contents": {
          "source": "data:text/plain;base64,${SQUID_CONFIG}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid.sh",
        "contents": {
          "source": "data:text/plain;base64,${SQUID_SH}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/proxy.sh",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_SH}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/passwd.sh",
        "contents": {
          "source": "data:text/plain;base64,${KEY_PASSWORD}"
        },
        "mode": 493
      }
    ],
    "directories": [
      {
        "path": "/srv/squid/log",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "[Service]\n\nExecStart=bash /srv/squid.sh\n\n[Install]\nWantedBy=multi-user.target\n",
        "enabled": true,
        "name": "squid.service"
      },
      {
        "dropins": [
          {
            "contents": "[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-journal-gatewayd \\\n  --key=/opt/openshift/tls/journal-gatewayd.key \\\n  --cert=/opt/openshift/tls/journal-gatewayd.crt \\\n  --trust=/opt/openshift/tls/root-ca.crt\n",
            "name": "certs.conf"
          }
        ],
        "name": "systemd-journal-gatewayd.service"
      },
      {
        "enabled": true,
        "name": "systemd-journal-gatewayd.socket"
      }
    ]
  }
}
EOF
# update ssh keys
tmp_keys_json=`mktemp`
tmp_file=`mktemp`
echo '[]' > "$tmp_keys_json"

ssh_pub_keys_file="${CLUSTER_PROFILE_DIR}/ssh-publickey"
readarray -t contents < "${ssh_pub_keys_file}"
for ssh_key_content in "${contents[@]}"; do
  jq --arg k "$ssh_key_content" '. += [$k]' < "${tmp_keys_json}" > "${tmp_file}"
  mv "${tmp_file}" "${tmp_keys_json}"
done

jq --argjson k "`jq '.| unique' "${tmp_keys_json}"`" '.passwd.users[0].sshAuthorizedKeys = $k' < "${SHARED_DIR}/proxy.ign" > "${tmp_file}"
mv "${tmp_file}" "${SHARED_DIR}/proxy.ign"

cat > ${SHARED_DIR}/04_cluster_proxy.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Proxy (EC2 Instance, Security Groups and IAM)

Parameters:
  InfrastructureName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Infrastructure name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, unique cluster ID used to tag cloud resources and identify items owned or used by the cluster.
    Type: String
  RhcosAmi:
    Description: Current Red Hat Enterprise Linux CoreOS AMI to use for proxy.
    Type: AWS::EC2::Image::Id
  AllowedProxyCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/([0-9]|1[0-9]|2[0-9]|3[0-2]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/0-32.
    Default: 0.0.0.0/0
    Description: CIDR block to allow access to the proxy node.
    Type: String
  PrivateHostedZoneId:
    Description: The Route53 private zone ID to register the etcd targets with, such as Z21IXYZABCZ2A4.
    Type: String
  PrivateHostedZoneName:
    Description: The Route53 zone to register the targets with, such as cluster.example.com. Omit the trailing period.
    Type: String
  ClusterName:
    Description: The cluster name used to uniquely identify the proxy load balancer
    Type: String
  PublicSubnet:
    Description: The public subnet to launch the proxy node into.
    Type: AWS::EC2::Subnet::Id
  MasterSecurityGroupId:
    Description: The master security group ID for registering temporary rules.
    Type: AWS::EC2::SecurityGroup::Id
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id
  PrivateSubnets:
    Description: The internal subnets.
    Type: List<AWS::EC2::Subnet::Id>
  ProxyIgnitionLocation:
    Default: s3://my-s3-bucket/proxy.ign
    Description: Ignition config file location.
    Type: String
  AutoRegisterDNS:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Do you want to invoke DNS etcd registration, which requires Hosted Zone information?
    Type: String
  AutoRegisterELB:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Do you want to invoke NLB registration, which requires a Lambda ARN parameter?
    Type: String
  RegisterNlbIpTargetsLambdaArn:
    Description: ARN for NLB IP target registration lambda.
    Type: String
  ExternalApiTargetGroupArn:
    Description: ARN for external API load balancer target group.
    Type: String
  InternalApiTargetGroupArn:
    Description: ARN for internal API load balancer target group.
    Type: String
  InternalServiceTargetGroupArn:
    Description: ARN for internal service load balancer target group.
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - InfrastructureName
    - Label:
        default: "Host Information"
      Parameters:
      - RhcosAmi
      - ProxyIgnitionLocation
      - MasterSecurityGroupId
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcId
      - AllowedProxyCidr
      - PublicSubnet
      - PrivateSubnets
      - ClusterName
    - Label:
        default: "DNS"
      Parameters:
      - AutoRegisterDNS
      - PrivateHostedZoneId
      - PrivateHostedZoneName
    - Label:
        default: "Load Balancer Automation"
      Parameters:
      - AutoRegisterELB
      - RegisterNlbIpTargetsLambdaArn
      - ExternalApiTargetGroupArn
      - InternalApiTargetGroupArn
      - InternalServiceTargetGroupArn
    ParameterLabels:
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      AllowedProxyCidr:
        default: "Allowed ingress Source"
      PublicSubnet:
        default: "Public Subnet"
      PrivateSubnets:
        default: "Private Subnets"
      RhcosAmi:
        default: "Red Hat Enterprise Linux CoreOS AMI ID"
      ProxyIgnitionLocation:
        default: "Bootstrap Ignition Source"
      MasterSecurityGroupId:
        default: "Master Security Group ID"
      AutoRegisterDNS:
        default: "Use Provided DNS Automation"
      AutoRegisterELB:
        default: "Use Provided ELB Automation"
      PrivateHostedZoneName:
        default: "Private Hosted Zone Name"
      PrivateHostedZoneId:
        default: "Private Hosted Zone ID"
      ClusterName:
        default: "Cluster name"

Conditions:
  DoRegistration: !Equals ["yes", !Ref AutoRegisterELB]
  DoDns: !Equals ["yes", !Ref AutoRegisterDNS]

Resources:
  ProxyIamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "ec2.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"
      Policies:
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "proxy", "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action: "ec2:Describe*"
            Resource: "*"
          - Effect: "Allow"
            Action: "s3:Get*"
            Resource: "*"
          - Effect: "Allow"
            Action: "s3:List*"
            Resource: "*"

  ProxyInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "ProxyIamRole"

  ProxySecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Cluster Proxy Security Group
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        ToPort: 3128
        FromPort: 3128
        CidrIp: !Ref AllowedProxyCidr
      - IpProtocol: tcp
        ToPort: 3130
        FromPort: 3130
        CidrIp: !Ref AllowedProxyCidr
      - IpProtocol: tcp
        ToPort: 19531
        FromPort: 19531
        CidrIp: !Ref AllowedProxyCidr
      VpcId: !Ref VpcId

  ProxyInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      IamInstanceProfile: !Ref ProxyInstanceProfile
      InstanceType: "i3.large"
      NetworkInterfaces:
      - AssociatePublicIpAddress: "true"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "ProxySecurityGroup"
        - !Ref "MasterSecurityGroupId"
        SubnetId: !Ref "PublicSubnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"replace":{"source":"\${IgnitionLocation}"}},"version":"3.0.0"}}'
        - {
          IgnitionLocation: !Ref ProxyIgnitionLocation
        }

  ProxyRecord:
    Condition: DoDns
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref PrivateHostedZoneId
      Name: !Join [".", ["squid", !Ref PrivateHostedZoneName]]
      ResourceRecords:
      - !GetAtt ProxyInstance.PrivateIp
      TTL: 60
      Type: A

Outputs:
  ProxyInstanceId:
    Description: The proxy node Instance ID
    Value: !Ref ProxyInstance
  ProxyPrivateIP:
    Description: The proxy node private IP address
    Value: !GetAtt ProxyInstance.PrivateIp
  ProxyPublicIp:
    Description: The proxy node public IP address.
    Value: !GetAtt ProxyInstance.PublicIp
EOF
