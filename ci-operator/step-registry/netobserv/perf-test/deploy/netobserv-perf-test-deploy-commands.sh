#!/usr/bin/env bash

source scripts/netobserv.sh
deploy_lokistack
deploy_kafka
deploy_netobserv
createFlowcollector "-p KafkaConsumerReplicas=${KAFKA_CONSUMER_REPLICAS}"
