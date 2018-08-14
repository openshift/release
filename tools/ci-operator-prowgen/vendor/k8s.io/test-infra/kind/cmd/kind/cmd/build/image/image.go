/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package image

import (
	"os"

	"github.com/spf13/cobra"

	"k8s.io/test-infra/kind/pkg/build"
)

type flags struct {
	Source string
}

func NewCommand() *cobra.Command {
	flags := &flags{}
	cmd := &cobra.Command{
		// TODO(bentheelder): more detailed usage
		Use:   "image",
		Short: "build the node image",
		Long:  "build the node image",
		Run: func(cmd *cobra.Command, args []string) {
			run(flags, cmd, args)
		},
	}
	cmd.Flags().StringVar(&flags.Source, "source", "", "path to the node image sources")
	return cmd
}

func run(flags *flags, cmd *cobra.Command, args []string) {
	// TODO(bentheelder): make this more configurable
	ctx := build.NewNodeImageBuildContext()
	ctx.SourceDir = flags.Source
	err := ctx.Build()
	if err != nil {
		os.Exit(-1)
	}
}
