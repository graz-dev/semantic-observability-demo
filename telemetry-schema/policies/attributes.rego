# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

package after_resolution

import rego.v1

# Attributes defined by this registry are resolved into one group per business
# domain, named registry.source.attributes.<domain> after the file they live in.
domain_prefix := "registry.source.attributes."

domain_attributes contains {"domain": domain, "group": group.id, "attr": attr} if {
	some group in input.groups
	startswith(group.id, domain_prefix)
	domain := trim_prefix(group.id, domain_prefix)
	some attr in group.attributes
}

deny contains finding("app_prefix_reserved", d) if {
	some d in domain_attributes
	startswith(d.attr.name, "app.")
}

deny contains finding("missing_demo_prefix", d) if {
	some d in domain_attributes
	not startswith(d.attr.name, "demo.")
	not startswith(d.attr.name, "app.")
}

deny contains finding("missing_owner", d) if {
	some d in domain_attributes
	not d.attr.annotations.owner
}

deny contains finding("owner_domain_mismatch", d) if {
	some d in domain_attributes
	d.attr.annotations.owner
	d.attr.annotations.owner != d.domain
}

deny contains finding("unknown_dependency", d) if {
	some d in domain_attributes
	some dependency in d.attr.annotations.depends_on
	not defined_by_any_domain(dependency)
}

deny contains finding("same_domain_dependency", d) if {
	some d in domain_attributes
	some dependency in d.attr.annotations.depends_on
	defined_by_any_domain(dependency)
	not defined_by_another_domain(dependency, d.domain)
}

defined_by_any_domain(name) if {
	some other in domain_attributes
	other.attr.name == name
}

defined_by_another_domain(name, domain) if {
	some other in domain_attributes
	other.attr.name == name
	other.domain != domain
}

finding(id, d) := {
	"id": id,
	"type": "semconv_attribute",
	"category": "attribute",
	"group": d.group,
	"attr": d.attr.name,
}
