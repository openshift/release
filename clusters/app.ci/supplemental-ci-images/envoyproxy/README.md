# Envoyproxy
The `envoyproxy` image is used in the `gangway` deployment to translate HTTP requests to gRPC requests that `gangway` is using.

We need to keep our own version of the `gangway_api_descriptor.pb` file that uses:
    
    post: "/v1/executions/{job_name}"

instead of 

    custom: {
        kind: "POST",
        path: "/v1/executions",
      }

in the .proto file, becasue upstrem they are using the second option, added by this [PR](https://github.com/kubernetes/test-infra/commit/2f37155f3842a0f5b3ecca02f28b3e14759f023a), and that approach does not work in our infrastructure.

To update the `gangway_api_descriptor.pb` file, in the Prow repo, you need to change every `POST` field in the `gangway.proto` [file](https://github.com/kubernetes-sigs/prow/blob/main/pkg/gangway/gangway.proto) as described above, and then run `make update-codegen` to generate the new `gangway_api_descriptor.pb`.