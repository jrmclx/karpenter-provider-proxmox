/*
Copyright 2025 The Kubernetes Authors.

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

package options

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"

	coreoptions "sigs.k8s.io/karpenter/pkg/operator/options"
	"sigs.k8s.io/karpenter/pkg/utils/env"
)

const (
	cloudConfigEnvVarName = "CLOUD_CONFIG"
	cloudConfigFlagName   = "cloud-config"

	instanceTypesFileEnvVarName = "INSTANCE_TYPES_FILE"
	instanceTypesFileFlagName   = "instance-types-file"

	nodeSettingFileEnvVarName = "NODE_SETTING_FILE"
	nodeSettingFileFlagName   = "node-setting-file"

	nodePolicyEnvVarName = "NODE_POLICY"
	nodePolicyFlagName   = "node-policy"

	proxmoxVMIDEnvVarName = "PROXMOX_VMID"
	proxmoxVMIDFlagName   = "proxmox-vmid"

	//Added
	cpuOvercommitEnvVarName = "CPU_OVERCOMMIT_FACTOR"
	cpuOvercommitFlagName   = "cpu-overcommit"
	//Added
	memOvercommitEnvVarName = "MEM_OVERCOMMIT_FACTOR"
	memOvercommitFlagName   = "mem-overcommit"
)

func init() {
	coreoptions.Injectables = append(coreoptions.Injectables, &Options{})
}

type optionsKey struct{}

type Options struct {
	CloudConfigPath       string
	InstanceTypesFilePath string
	NodeSettingFilePath   string
	NodePolicy            string
	ProxmoxVMID           int
	//Added
	CPUOvercommitFactor   float64
    MemOvercommitFactor   float64
}

// parseOvercommitFactor parses a string overcommit factor, returning 1.0 on invalid input.
func parseOvercommitFactor(s string) float64 {
    f, err := strconv.ParseFloat(s, 64)
    if err != nil || f < 1.0 {
        return 1.0
    }
    return f
}

func (o *Options) AddFlags(fs *coreoptions.FlagSet) {
	fs.StringVar(&o.CloudConfigPath, cloudConfigFlagName, env.WithDefaultString(cloudConfigEnvVarName, ""), "Path to the cloud config file.")
	fs.StringVar(&o.InstanceTypesFilePath, instanceTypesFileFlagName, env.WithDefaultString(instanceTypesFileEnvVarName, ""), "Path to a custom instance-types file.")
	fs.StringVar(&o.NodeSettingFilePath, nodeSettingFileFlagName, env.WithDefaultString(nodeSettingFileEnvVarName, ""), "Path to the node setting file.")
	fs.StringVar(&o.NodePolicy, nodePolicyFlagName, env.WithDefaultString(nodePolicyEnvVarName, "simple"), "Node CPU policy to use.")
	fs.IntVar(&o.ProxmoxVMID, proxmoxVMIDFlagName, env.WithDefaultInt(proxmoxVMIDEnvVarName, 20000), "This value is used as the minimum ID when creating a VM.")
	fs.Float64Var(&o.CPUOvercommitFactor, cpuOvercommitFlagName, parseOvercommitFactor(env.WithDefaultString(cpuOvercommitEnvVarName, "1.0")), "CPU overcommit factor (e.g. 2.0 doubles visible CPUs, default 1.0 = no overcommit).")
	fs.Float64Var(&o.MemOvercommitFactor, memOvercommitFlagName, parseOvercommitFactor(env.WithDefaultString(memOvercommitEnvVarName, "1.0")), "Memory overcommit factor (default 1.0 = no overcommit).")
}

func (o *Options) Parse(fs *coreoptions.FlagSet, args ...string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			os.Exit(0)
		}

		return fmt.Errorf("parsing flags, %w", err)
	}

	if err := o.Validate(); err != nil {
		return fmt.Errorf("validating options, %w", err)
	}

	return nil
}

func (o *Options) ToContext(ctx context.Context) context.Context {
	return ToContext(ctx, o)
}

func ToContext(ctx context.Context, opts *Options) context.Context {
	return context.WithValue(ctx, optionsKey{}, opts)
}

func FromContext(ctx context.Context) *Options {
	retval := ctx.Value(optionsKey{})
	if retval == nil {
		return nil
	}

	return retval.(*Options)
}
