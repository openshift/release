#!/bin/bash

oc adm policy add-role-to-group system:image-puller system:authenticated --namespace "${NAMESPACE}"
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
