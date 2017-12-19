#!/bin/bash

# mkdir /tmp/reader && each.sh /bin/bash -c 'oc sa get-token prometheus-reader $1 $2 > /tmp/reader/cluster-$2' ' '

arr=( $( oc config view --template '{{ range .contexts }}{{ .name }}{{ "\n" }}{{ end }}' -o go-template ) )
for i in ${arr[@]}; do
  "$@" --context "$i"
done
