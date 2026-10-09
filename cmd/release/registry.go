/*
Copyright The Platform Mesh Authors.

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

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// The component registry is ocm/components.yaml at the repository root; it is
// the single source of truth for CI, the release workflows and this tool. See
// the comments in that file for the schema.
const registryFile = "ocm/components.yaml"

// component describes a release line: its tag prefix (the version is appended
// directly, e.g. prefix "apis/v" + "0.0.1" = "apis/v0.0.1"), whether it is a
// go-gettable library (tagged only, nothing built) and a one-line summary of
// what cutting the tag sets in motion — shown in the plan so a dry-run makes
// the downstream effect obvious.
type component struct {
	prefix   string
	library  bool
	triggers string
}

// componentOrder is the order `all` releases in: the order of ocm/components.yaml,
// which lists the libraries before the components that import them, so a
// library's tag exists when its consumers are bumped.
var componentOrder []string

var components = map[string]component{}

// libraryComponents are go-gettable modules other modules in the repo import.
// Tagging one only moves the tag; pointing the consumers at the new version is
// a separate, reviewable commit. After a successful release we print the exact
// `task bump-deps` invocation instead of mutating go.mod files behind the
// user's back.
var libraryComponents = map[string]bool{}

// loadRegistry reads ocm/components.yaml from the repository root.
func loadRegistry() error {
	root, err := gitOut("rev-parse", "--show-toplevel")
	if err != nil {
		return fmt.Errorf("finding repository root: %w", err)
	}
	path := filepath.Join(root, registryFile)
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}

	// Decode into a node to keep the document order of the components map.
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parsing %s: %w", path, err)
	}
	var root_ *yaml.Node
	if doc.Kind == yaml.DocumentNode && len(doc.Content) > 0 {
		root_ = doc.Content[0]
	}
	var compsNode *yaml.Node
	if root_ != nil && root_.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(root_.Content); i += 2 {
			if root_.Content[i].Value == "components" {
				compsNode = root_.Content[i+1]
			}
		}
	}
	if compsNode == nil || compsNode.Kind != yaml.MappingNode {
		return fmt.Errorf("%s: no 'components' mapping found", path)
	}

	for i := 0; i+1 < len(compsNode.Content); i += 2 {
		name := compsNode.Content[i].Value
		var spec struct {
			Library bool   `yaml:"library"`
			Image   string `yaml:"image"`
		}
		if err := compsNode.Content[i+1].Decode(&spec); err != nil {
			return fmt.Errorf("%s: component %q: %w", path, name, err)
		}
		c := component{prefix: name + "/v", library: spec.Library}
		if spec.Library {
			c.triggers = "go-gettable module tag for go.platform-mesh.io/" + name + " (no image)"
			libraryComponents[name] = true
		} else {
			c.triggers = "component-release.yml: builds + signs the image, publishes SBOM + signed OCM component github.com/platform-mesh/images/" + name
		}
		components[name] = c
		componentOrder = append(componentOrder, name)
	}
	if len(componentOrder) == 0 {
		return fmt.Errorf("%s: no components defined", path)
	}
	return nil
}
