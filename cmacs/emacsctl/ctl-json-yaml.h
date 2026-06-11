/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-json-yaml.h --- JsonNode <-> YamlNode conversion. */

#ifndef CTL_JSON_YAML_H
#define CTL_JSON_YAML_H

#include <json-glib/json-glib.h>
#include <yaml-glib.h>

G_BEGIN_DECLS

/* Recursive conversion.  Caller owns the returned node. */
YamlNode *ctl_json_to_yaml (JsonNode *json);
JsonNode *ctl_yaml_to_json (YamlNode *yaml);

G_END_DECLS

#endif /* CTL_JSON_YAML_H */
