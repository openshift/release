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

// Package delete implements the `delete` command
package delete

import (
	"os"

	"github.com/golang/glog"
	"github.com/spf13/cobra"

	"k8s.io/test-infra/kind/pkg/cluster"
)

type flags struct {
	Name string
}

// NewCommand returns a new cobra.Command for cluster creation
func NewCommand() *cobra.Command {
	flags := &flags{}
	cmd := &cobra.Command{
		// TODO(bentheelder): more detailed usage
		Use:   "delete",
		Short: "Deletes a cluster",
		Long:  "Deletes a Kubernetes cluster",
		Run: func(cmd *cobra.Command, args []string) {
			run(flags, cmd, args)
		},
	}
	cmd.Flags().StringVar(&flags.Name, "name", "1", "the cluster name")
	return cmd
}

func run(flags *flags, cmd *cobra.Command, args []string) {
	// TODO(bentheelder): make this more configurable
	config := cluster.NewConfig(flags.Name)
	err := config.Validate()
	if err != nil {
		glog.Error("Invalid Configuration!")
		configErrors := err.(cluster.ConfigErrors)
		for _, problem := range configErrors.Errors() {
			glog.Error(problem)
		}
		os.Exit(-1)
	}
	ctx := cluster.NewContext(config)
	err = ctx.Delete()
	if err != nil {
		glog.Errorf("Failed to delete cluster: %v", err)
		os.Exit(-1)
	}
}
