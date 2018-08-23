package steps

import (
	"io"

	"k8s.io/client-go/rest"

	buildapi "github.com/openshift/api/build/v1"
	"github.com/openshift/client-go/build/clientset/versioned/scheme"
	buildclientset "github.com/openshift/client-go/build/clientset/versioned/typed/build/v1"
)

type BuildClient interface {
	buildclientset.BuildsGetter
	Logs(namespace, name string, options *buildapi.BuildLogOptions) (io.ReadCloser, error)
}

type buildClient struct {
	buildclientset.BuildsGetter

	client rest.Interface
}

func NewBuildClient(client buildclientset.BuildsGetter, restClient rest.Interface) BuildClient {
	return &buildClient{
		BuildsGetter: client,
		client:       restClient,
	}
}

func (c *buildClient) Logs(namespace, name string, options *buildapi.BuildLogOptions) (io.ReadCloser, error) {
	return c.client.Get().
		Namespace(namespace).
		Name(name).
		Resource("builds").
		SubResource("log").
		VersionedParams(options, scheme.ParameterCodec).
		Stream()
}
