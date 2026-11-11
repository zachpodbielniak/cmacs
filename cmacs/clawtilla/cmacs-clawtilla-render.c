/* Clawtilla fleet client for CMacs -- shared presentation helpers.

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later  */

#include <config.h>

#ifdef HAVE_CMACS_CLAWTILLA

/* Sees <clawtilla.h>, never lisp.h.  See cmacs-clawtilla.h.  */
#include <clawtilla.h>
#include <glib.h>
#include <json-glib/json-glib.h>

#include "cmacs-clawtilla.h"

/* ------------------------------------------------------------------
   Why any of this is here.

   These are not conveniences.  Each one is a decision libclawt already
   makes, which every clawtilla client is required to reach for rather
   than answer itself -- and clawtilla's `make parity' compares which
   shared symbols each client touches precisely so a third one cannot
   quietly grow its own opinion.

   The failures being prevented are on record in clawtilla's own
   history: the CLI read `busy' and `peer' for as long as they existed
   and rendered neither, and the web client drew a bare "busy" badge
   that dropped `peer' on the floor.  A sentence assembled in three
   places is three sentences.

   Markdown is the same argument taken one step further.  cmacs cannot
   use `clawt_markdown_to_pango' output directly -- Emacs wants text
   properties, not Pango markup -- but it can use the same *parse*, so
   the markup is what crosses into Lisp and the elisp side turns tags
   into faces.  That is one markdown implementation for three clients
   instead of two plus a hand-rolled one.
   ------------------------------------------------------------------ */

static char *
cmacs_clawt_render_node_to_json (JsonNode *node)
{
  g_autoptr (JsonGenerator) generator = json_generator_new ();

  json_generator_set_root (generator, node);
  return json_generator_to_data (generator, NULL);
}

static JsonNode *
cmacs_clawt_render_parse (const char *json)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  JsonNode *root;

  if (json == NULL || !json_parser_load_from_data (parser, json, -1, NULL))
    return NULL;

  /* An empty document parses fine and leaves a NULL root, and
     json_node_copy() of that is a CRITICAL rather than NULL back.  */
  root = json_parser_get_root (parser);

  return root != NULL ? json_node_copy (root) : NULL;
}

char *
cmacs_clawt_activity_label (bool busy, const char *peer)
{
  return clawt_agent_activity_label (busy ? TRUE : FALSE, peer);
}

char *
cmacs_clawt_team_tally_json (const char *agents_json, const char *team_id)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (agents_json);
  guint total = 0;
  guint running = 0;
  guint busy = 0;

  if (node == NULL || !JSON_NODE_HOLDS_ARRAY (node))
    return NULL;

  /* Counted in the library, not here.  Three clients counting the same
     thing is three chances to disagree about what "active" means, and
     the daemon has already had that argument.  */
  clawt_team_tally (json_node_get_array (node),
                    (team_id != NULL && *team_id != '\0') ? team_id : NULL,
                    &total, &running, &busy);

  return g_strdup_printf ("{\"total\":%u,\"running\":%u,\"busy\":%u}",
                          total, running, busy);
}

bool
cmacs_clawt_unread_should_count (const char *room_id, const char *viewing,
                                 const char *from, int64_t event_ts,
                                 int64_t connected_at, const char *rooms_json)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (rooms_json);
  g_autoptr (GHashTable) rows = NULL;
  JsonArray *array;
  guint i;

  /* `rows' is NOT an optional dedup table, which is what the first cut
     of this wrapper assumed: the library answers FALSE outright when it
     is NULL, so passing NULL made an unread count impossible and
     nothing said so.  It is the set of rooms this client actually has a
     row for -- an event about a room with no row cannot raise a count
     on it, because there is nothing there to show the count.  */
  rows = g_hash_table_new (g_str_hash, g_str_equal);

  if (node != NULL && JSON_NODE_HOLDS_ARRAY (node))
    {
      array = json_node_get_array (node);

      for (i = 0; i < json_array_get_length (array); i++)
        {
          const gchar *id = json_array_get_string_element (array, i);

          if (id != NULL)
            g_hash_table_add (rows, (gpointer) id);
        }
    }

  return clawt_unread_should_count (room_id, viewing, from, event_ts,
                                    connected_at, rows)
         ? true : false;
}

char *
cmacs_clawt_run_is_start (const char *previous_sender,
                          const char *previous_day, const char *sender,
                          const char *day)
{
  gboolean new_day = FALSE;
  gboolean start = clawt_chat_run_is_start (previous_sender, previous_day,
                                            sender, day, &new_day);

  /* Two answers, and they are different questions: a new day always
     starts a run, but a run can start without the day changing.  A
     client that collapsed them would lose the day divider or draw one
     every message.  */
  return g_strdup_printf ("{\"start\":%s,\"new-day\":%s}",
                          start ? "true" : "false",
                          new_day ? "true" : "false");
}

char *
cmacs_clawt_chat_time_label (int64_t unix_seconds)
{
  g_autoptr (GDateTime) when =
    g_date_time_new_from_unix_local (unix_seconds);

  if (when == NULL)
    return NULL;

  return clawt_chat_time_label (when);
}

char *
cmacs_clawt_chat_day_label (int64_t unix_seconds)
{
  g_autoptr (GDateTime) when =
    g_date_time_new_from_unix_local (unix_seconds);
  g_autoptr (GDateTime) now = g_date_time_new_now_local ();

  if (when == NULL)
    return NULL;

  return clawt_chat_day_label (when, now);
}

static const char *
cmacs_clawt_tier_nick (ClawtAlertTier tier)
{
  switch (tier)
    {
    case CLAWT_ALERT_SKIP:    return "skip";
    case CLAWT_ALERT_ROUTINE: return "routine";
    case CLAWT_ALERT_NOTICE:  return "notice";
    case CLAWT_ALERT_ERROR:   return "error";
    default:                  return "routine";
    }
}

char *
cmacs_clawt_alert_tier (const char *kind, const char *subject,
                        int64_t timestamp)
{
  g_autoptr (ClawtEvent) event = clawt_event_new (kind, subject);

  if (event == NULL)
    return NULL;

  if (timestamp > 0)
    clawt_event_set_timestamp (event, timestamp);

  return g_strdup (cmacs_clawt_tier_nick (clawt_alert_tier_for_event (event)));
}

bool
cmacs_clawt_alert_arrives_read (bool surface_showing, const char *tier)
{
  ClawtAlertTier value = CLAWT_ALERT_ROUTINE;

  if (tier != NULL)
    {
      if (g_str_equal (tier, "skip"))
        value = CLAWT_ALERT_SKIP;
      else if (g_str_equal (tier, "notice"))
        value = CLAWT_ALERT_NOTICE;
      else if (g_str_equal (tier, "error"))
        value = CLAWT_ALERT_ERROR;
    }

  return clawt_alert_arrives_read (surface_showing ? TRUE : FALSE, value)
         ? true : false;
}

char *
cmacs_clawt_markdown (const char *markdown)
{
  /* Pango markup, converted to text properties on the Lisp side.  The
     point is the shared parse, not the shared output: one cmark for
     three clients rather than two plus a hand-rolled one.  */
  return clawt_markdown_to_pango (markdown);
}

/* ------------------------------------------------------------------
   Turn steps: the live "what the agent is doing" line.
   ------------------------------------------------------------------ */

static GPtrArray *
cmacs_clawt_steps_from_json (const char *steps_json, const char *agent_id)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (steps_json);
  GPtrArray *steps;
  JsonArray *array;
  guint i;

  if (node == NULL || !JSON_NODE_HOLDS_ARRAY (node))
    return NULL;

  array = json_node_get_array (node);
  steps = g_ptr_array_new_with_free_func (
    (GDestroyNotify) clawt_turn_step_free);

  for (i = 0; i < json_array_get_length (array); i++)
    {
      JsonObject *object = json_array_get_object_element (array, i);
      ClawtTurnStep *step;

      if (object == NULL)
        continue;

      step = clawt_turn_step_new_from_object (object, agent_id);

      if (step != NULL)
        g_ptr_array_add (steps, step);
    }

  return steps;
}

char *
cmacs_clawt_step_summary (const char *steps_json, const char *agent_id,
                          int from, int to)
{
  g_autoptr (GPtrArray) steps = cmacs_clawt_steps_from_json (steps_json, agent_id);

  if (steps == NULL || steps->len == 0)
    return NULL;

  if (from < 0)
    from = 0;

  if (to < 0 || (guint) to > steps->len)
    to = (int) steps->len;

  /* "Read 3 files, Changed 2 files, Ran 1 command" rather than
     labelling every operation a command.  Both graphical clients group
     consecutive tool calls through this, and a third grouping would be
     a third vocabulary.  */
  return clawt_turn_step_run_summary (steps, (guint) from, (guint) to);
}

char *
cmacs_clawt_step_tone (const char *step_json, const char *agent_id)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (step_json);
  g_autoptr (ClawtTurnStep) step = NULL;
  const gchar *tone;

  if (node == NULL || !JSON_NODE_HOLDS_OBJECT (node))
    return NULL;

  step = clawt_turn_step_new_from_object (json_node_get_object (node),
                                         agent_id);

  if (step == NULL)
    return NULL;

  tone = clawt_turn_step_tone (step);

  return tone != NULL ? g_strdup (tone) : NULL;
}

bool
cmacs_clawt_step_precedes (const char *step_json, const char *agent_id,
                           int64_t message_ts)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (step_json);
  g_autoptr (ClawtTurnStep) step = NULL;

  if (node == NULL || !JSON_NODE_HOLDS_OBJECT (node))
    return false;

  step = clawt_turn_step_new_from_object (json_node_get_object (node),
                                         agent_id);

  if (step == NULL)
    return false;

  /* Whether a step belongs before a message in the transcript, which is
     how live steps merge into history instead of piling up after it.  */
  return clawt_turn_step_precedes (step, message_ts) ? true : false;
}

static void
cmacs_clawt_step_to_json (JsonBuilder *builder, ClawtTurnStep *step)
{
  const gchar *tone = clawt_turn_step_tone (step);
  const gchar *tool = clawt_turn_step_get_tool_name (step);
  const gchar *text = clawt_turn_step_get_text (step);
  const gchar *detail = clawt_turn_step_get_detail (step);

  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "tone");
  json_builder_add_string_value (builder, tone != NULL ? tone : "");
  json_builder_set_member_name (builder, "tool");
  json_builder_add_string_value (builder, tool != NULL ? tool : "");
  json_builder_set_member_name (builder, "text");
  json_builder_add_string_value (builder, text != NULL ? text : "");
  json_builder_set_member_name (builder, "detail");
  json_builder_add_string_value (builder, detail != NULL ? detail : "");
  json_builder_set_member_name (builder, "call");
  json_builder_add_boolean_value (builder, clawt_turn_step_is_call (step));
  json_builder_set_member_name (builder, "failed");
  json_builder_add_boolean_value (builder, clawt_turn_step_get_failed (step));
  json_builder_set_member_name (builder, "timestamp");
  json_builder_add_int_value (builder, clawt_turn_step_get_timestamp (step));
  json_builder_end_object (builder);
}

char *
cmacs_clawt_steps_split (const char *steps_json, const char *agent_id,
                         int64_t message_ts)
{
  g_autoptr (GPtrArray) steps = cmacs_clawt_steps_from_json (steps_json,
                                                             agent_id);
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (JsonNode) root = NULL;
  guint i;

  if (steps == NULL)
    return NULL;

  /* Two arrays out of one, split by clawt_turn_step_precedes().
     Everything happens here rather than in Lisp because a step has to
     travel as the JSON the daemon SENT: re-encoding a parsed step turns
     a null `failed' into an empty object, and the library reads that
     member with json_object_get_boolean_member() behind a has_member()
     check that a null passes -- one GLib CRITICAL per step, per redraw.

     `history' is the half a message has already overtaken.  Those are
     not finished with: they belong in the transcript above that
     message, which is how a turn's tool calls stay readable after the
     answer arrives instead of vanishing with the activity line.  */
  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "history");
  json_builder_begin_array (builder);

  for (i = 0; i < steps->len; i++)
    {
      ClawtTurnStep *step = g_ptr_array_index (steps, i);

      if (message_ts > 0 && clawt_turn_step_precedes (step, message_ts))
        cmacs_clawt_step_to_json (builder, step);
    }

  json_builder_end_array (builder);
  json_builder_set_member_name (builder, "live");
  json_builder_begin_array (builder);

  for (i = 0; i < steps->len; i++)
    {
      ClawtTurnStep *step = g_ptr_array_index (steps, i);

      if (!(message_ts > 0 && clawt_turn_step_precedes (step, message_ts)))
        cmacs_clawt_step_to_json (builder, step);
    }

  json_builder_end_array (builder);

  /* The summary of the live half, built HERE from the step objects.
     Handing the normalised array back to Lisp and letting it re-encode
     that for the summary is the same corruption one layer up: a
     `failed: false' becomes nil on the way in and an empty object on
     the way out, and the library reads it as a boolean.  Nothing
     re-encodes a step now -- the raw JSON goes in, and text comes
     out.  */
  {
    guint first_live = steps->len;

    for (i = 0; i < steps->len; i++)
      {
        ClawtTurnStep *step = g_ptr_array_index (steps, i);

        if (!(message_ts > 0 && clawt_turn_step_precedes (step, message_ts)))
          {
            first_live = i;
            break;
          }
      }

    json_builder_set_member_name (builder, "summary");

    if (first_live < steps->len)
      {
        g_autofree gchar *summary =
          clawt_turn_step_run_summary (steps, first_live, steps->len);

        json_builder_add_string_value (builder,
                                       summary != NULL ? summary : "");
      }
    else
      json_builder_add_string_value (builder, "");
  }

  json_builder_end_object (builder);
  root = json_builder_get_root (builder);

  return cmacs_clawt_render_node_to_json (root);
}

/* ------------------------------------------------------------------
   The Activity page, the Fleet page and the browser line.

   Each of these is a sentence or a figure libclawt already writes for
   the GTK, web and lrg clients (clawt-activity.h, clawt-usage.h,
   clawt-browser.h).  A fourth client composing "running 3m 12s" or
   "$3.20 across 41 turns" itself would be a fourth wording, and the
   first place they would disagree is a clock edge nobody tests.
   ------------------------------------------------------------------ */

char *
cmacs_clawt_activity_elapsed (int64_t started_us, int64_t now_us)
{
  /* Both in the daemon's clock: `started' from the turn, `now' from the
     same activity.list reply, so this machine's clock skew never shows
     up as an age.  */
  return clawt_activity_elapsed_label (started_us, now_us);
}

char *
cmacs_clawt_activity_stop_prompt (const char *agent_id, unsigned running)
{
  /* Stop is agent.interrupt, which ends EVERY turn the agent has, not
     the row it was pressed on -- the question says so.  */
  return clawt_activity_stop_prompt (agent_id != NULL ? agent_id : "",
                                     running);
}

char *
cmacs_clawt_usage_sparkline (const int64_t *values, unsigned count)
{
  g_autofree gint64 *copy = NULL;
  guint i;

  if (count == 0)
    return g_strdup ("");

  /* int64_t and gint64 are the same width but not, to the compiler,
     the same type; a copy is cheaper than an argument about it.  */
  copy = g_new (gint64, count);

  for (i = 0; i < count; i++)
    copy[i] = values[i];

  return clawt_usage_sparkline (copy, count);
}

char *
cmacs_clawt_usage_format_cost (int64_t cost_micros)
{
  return clawt_usage_format_cost (cost_micros);
}

char *
cmacs_clawt_usage_fleet_payload (int period, int days)
{
  g_autoptr (JsonNode) payload = NULL;
  gint64 now = g_get_real_time () / G_USEC_PER_SEC;

  if (period < 0 || (guint) period >= clawt_usage_period_count ())
    period = CLAWT_USAGE_PERIOD_DEFAULT;

  if (days < 0)
    days = 0;

  /* The request the Fleet page sends in every client: the period's
     `since', the days of daily figures, and `sort: cost'.  */
  payload = clawt_usage_fleet_payload (
    clawt_usage_period_since ((guint) period, now), (guint) days);

  return payload != NULL ? cmacs_clawt_render_node_to_json (payload) : NULL;
}

/* The daily costs of one agent, as clawt_usage_sparkline() draws them.
   The library draws the FLEET's strip itself (clawt_usage_fleet_strip);
   a per-agent strip is the same function over that agent's `daily'.  */
static gchar *
cmacs_clawt_agent_strip (JsonObject *agent)
{
  JsonArray *daily;
  g_autofree gint64 *values = NULL;
  guint count;
  guint i;

  if (!json_object_has_member (agent, "daily"))
    return g_strdup ("");

  daily = json_object_get_array_member (agent, "daily");

  if (daily == NULL || (count = json_array_get_length (daily)) == 0)
    return g_strdup ("");

  values = g_new0 (gint64, count);

  for (i = 0; i < count; i++)
    values[i] = json_array_get_int_element (daily, i);

  return clawt_usage_sparkline (values, count);
}

char *
cmacs_clawt_usage_fleet_json (const char *reply_json, int64_t now)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (reply_json);
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (JsonNode) root = NULL;
  JsonObject *reply;
  JsonObject *total;
  JsonArray *agents = NULL;
  gint64 total_cost = 0;
  guint i;

  if (node == NULL || !JSON_NODE_HOLDS_OBJECT (node))
    return NULL;

  reply = json_node_get_object (node);

  if (now <= 0)
    now = g_get_real_time () / G_USEC_PER_SEC;

  /* The daemon's clock when it gave one, for the ages.  */
  if (json_object_has_member (reply, "now"))
    now = json_object_get_int_member (reply, "now");

  if (json_object_has_member (reply, "total")
      && (total = json_object_get_object_member (reply, "total")) != NULL
      && json_object_has_member (total, "cost_micros"))
    total_cost = json_object_get_int_member (total, "cost_micros");

  json_builder_begin_object (builder);

  {
    g_autofree gchar *summary = clawt_usage_fleet_summary (reply);
    g_autofree gchar *budget = clawt_usage_fleet_budget_line (reply);
    g_autofree gchar *strip = clawt_usage_fleet_strip (reply);

    json_builder_set_member_name (builder, "summary");
    json_builder_add_string_value (builder, summary != NULL ? summary : "");
    /* nullable in the library: no cap set, or no days asked for.  */
    json_builder_set_member_name (builder, "budget");
    if (budget != NULL)
      json_builder_add_string_value (builder, budget);
    else
      json_builder_add_null_value (builder);
    json_builder_set_member_name (builder, "strip");
    json_builder_add_string_value (builder, strip != NULL ? strip : "");
    json_builder_set_member_name (builder, "stoppable");
    json_builder_add_int_value (builder,
                                clawt_usage_fleet_stoppable_count (reply));
  }

  if (json_object_has_member (reply, "agents"))
    agents = json_object_get_array_member (reply, "agents");

  json_builder_set_member_name (builder, "agents");
  json_builder_begin_array (builder);

  for (i = 0; agents != NULL && i < json_array_get_length (agents); i++)
    {
      JsonObject *agent = json_array_get_object_element (agents, i);
      gint64 cost;
      g_autofree gchar *subtitle = NULL;
      g_autofree gchar *money = NULL;
      g_autofree gchar *share = NULL;
      g_autofree gchar *strip = NULL;

      if (agent == NULL)
        continue;

      cost = json_object_has_member (agent, "cost_micros")
             ? json_object_get_int_member (agent, "cost_micros") : 0;
      subtitle = clawt_usage_fleet_row_subtitle (agent, now);
      money = clawt_usage_format_cost (cost);
      share = clawt_usage_share_label (cost, total_cost);
      strip = cmacs_clawt_agent_strip (agent);

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "id");
      json_builder_add_string_value (
        builder, json_object_get_string_member_with_default (agent, "id", ""));
      json_builder_set_member_name (builder, "subtitle");
      json_builder_add_string_value (builder, subtitle != NULL ? subtitle : "");
      json_builder_set_member_name (builder, "cost");
      json_builder_add_string_value (builder, money != NULL ? money : "");
      json_builder_set_member_name (builder, "share");
      json_builder_add_string_value (builder, share != NULL ? share : "");
      json_builder_set_member_name (builder, "strip");
      json_builder_add_string_value (builder, strip != NULL ? strip : "");
      json_builder_set_member_name (builder, "stoppable");
      json_builder_add_boolean_value (builder,
                                      clawt_usage_fleet_row_stoppable (agent));
      json_builder_end_object (builder);
    }

  json_builder_end_array (builder);
  json_builder_end_object (builder);
  root = json_builder_get_root (builder);

  return cmacs_clawt_render_node_to_json (root);
}

char *
cmacs_clawt_browser_session_line (const char *session_json)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (session_json);

  /* nullable in the library too: no session is a sentence of its own
     ("not running; starts on the first browser call").  */
  return clawt_browser_session_line (
    (node != NULL && JSON_NODE_HOLDS_OBJECT (node))
    ? json_node_get_object (node) : NULL);
}

#endif /* HAVE_CMACS_CLAWTILLA */
