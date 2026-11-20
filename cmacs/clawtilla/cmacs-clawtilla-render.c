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

  /* An MCP app the tool call came with: a page the connector serves
     for what it just did.  cmacs draws no HTML in a transcript, so --
     like the GTK client -- it links out; the words on the link are the
     library's.  */
  if (clawt_turn_step_get_app_id (step) != NULL)
    {
      g_autofree gchar *label
        = clawt_mcp_app_link_label (clawt_turn_step_get_app_title (step));

      json_builder_set_member_name (builder, "app_id");
      json_builder_add_string_value (builder,
                                     clawt_turn_step_get_app_id (step));
      json_builder_set_member_name (builder, "app_label");
      json_builder_add_string_value (builder, label != NULL ? label : "");
    }

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

/* ------------------------------------------------------------------
   Asking the library, by name.

   Clawtilla 0.52 words a great deal more than 0.11 did: the bell's
   count, a device's "seen" text, what a ledger row says under its
   name, the question asked before a Grok job is removed.  Each is one
   clawt_* helper the GTK client calls, and each needs exactly the same
   thing from this side -- some values in, a string out.

   A DEFUN apiece would be forty near-identical wrappers and forty
   prototypes, so there is one door: `cmacs_clawt_ask' takes the name of
   a question and its arguments as a JSON object, and answers text (or
   JSON text, for an answer with more than one part).  The table below
   IS the list of what this client asks libclawt rather than deciding
   itself; adding a question is one small function and one row.

   Arguments arrive as JSON because the values being asked about mostly
   are JSON -- a reply the daemon sent, an entry out of one -- and must
   reach the library as sent (see `cmacs-clawtilla-member-json' for
   what a re-encoding does to a null).  The elisp side passes those as
   raw text spliced into the arguments object.
   ------------------------------------------------------------------ */

static const gchar *
ask_str (JsonObject *args, const char *key)
{
  JsonNode *node = args != NULL ? json_object_get_member (args, key) : NULL;

  if (node == NULL || !JSON_NODE_HOLDS_VALUE (node)
      || json_node_get_value_type (node) != G_TYPE_STRING)
    return NULL;

  return json_node_get_string (node);
}

static gint64
ask_int (JsonObject *args, const char *key)
{
  JsonNode *node = args != NULL ? json_object_get_member (args, key) : NULL;

  if (node == NULL || !JSON_NODE_HOLDS_VALUE (node))
    return 0;

  /* Lisp sends a float for anything past a fixnum's JSON range, and a
     timestamp in microseconds is the one value here that might be.  */
  if (json_node_get_value_type (node) == G_TYPE_DOUBLE)
    return (gint64) json_node_get_double (node);

  if (json_node_get_value_type (node) != G_TYPE_INT64)
    return 0;

  return json_node_get_int (node);
}

static gboolean
ask_bool (JsonObject *args, const char *key)
{
  JsonNode *node = args != NULL ? json_object_get_member (args, key) : NULL;

  if (node == NULL || !JSON_NODE_HOLDS_VALUE (node)
      || json_node_get_value_type (node) != G_TYPE_BOOLEAN)
    return FALSE;

  return json_node_get_boolean (node);
}

static JsonObject *
ask_obj (JsonObject *args, const char *key)
{
  JsonNode *node = args != NULL ? json_object_get_member (args, key) : NULL;

  return (node != NULL && JSON_NODE_HOLDS_OBJECT (node))
         ? json_node_get_object (node) : NULL;
}

static JsonArray *
ask_arr (JsonObject *args, const char *key)
{
  JsonNode *node = args != NULL ? json_object_get_member (args, key) : NULL;

  return (node != NULL && JSON_NODE_HOLDS_ARRAY (node))
         ? json_node_get_array (node) : NULL;
}

static gint64
ask_now_seconds (JsonObject *args)
{
  gint64 now = ask_int (args, "now");

  return now > 0 ? now : g_get_real_time () / G_USEC_PER_SEC;
}

static char *
ask_number (gint64 value)
{
  return g_strdup_printf ("%" G_GINT64_FORMAT, value);
}

static char *
ask_finish (JsonBuilder *builder)
{
  g_autoptr (JsonNode) root = json_builder_get_root (builder);

  return cmacs_clawt_render_node_to_json (root);
}

static void
ask_put (JsonBuilder *builder, const char *name, const gchar *value)
{
  json_builder_set_member_name (builder, name);

  if (value != NULL)
    json_builder_add_string_value (builder, value);
  else
    json_builder_add_null_value (builder);
}

static void
ask_put_bool (JsonBuilder *builder, const char *name, gboolean value)
{
  json_builder_set_member_name (builder, name);
  json_builder_add_boolean_value (builder, value);
}

/* A JSON array of strings as the set the unread helpers take.  The
   keys borrow from the array, which the caller keeps alive.  */
static GHashTable *
ask_string_set (JsonArray *array)
{
  GHashTable *set = g_hash_table_new (g_str_hash, g_str_equal);
  guint i;

  for (i = 0; array != NULL && i < json_array_get_length (array); i++)
    {
      JsonNode *node = json_array_get_element (array, i);

      if (node != NULL && JSON_NODE_HOLDS_VALUE (node)
          && json_node_get_value_type (node) == G_TYPE_STRING)
        g_hash_table_add (set, (gpointer) json_node_get_string (node));
    }

  return set;
}

/* -- Notices, mutes and unread counts (clawt-notice-store.h,
      clawt-message.h).  -- */

static char *
ask_notice_badge (JsonObject *args)
{
  return ask_number (clawt_notice_list_badge (ask_obj (args, "reply")));
}

static char *
ask_notice_mutes (JsonObject *args)
{
  g_autoptr (GHashTable) muted
    = clawt_notice_list_mutes (ask_obj (args, "reply"));
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  GHashTableIter iter;
  gpointer key;

  json_builder_begin_array (builder);
  g_hash_table_iter_init (&iter, muted);

  while (g_hash_table_iter_next (&iter, &key, NULL))
    json_builder_add_string_value (builder, key);

  json_builder_end_array (builder);
  return ask_finish (builder);
}

/* The daemon's counts taken into a client's table.  NULL -- nil in
   Lisp -- when the listing carried no `unread' at all: a daemon too old
   to hold read marks, and the client goes on counting from events.  */
static char *
ask_unread_seed (JsonObject *args)
{
  g_autoptr (GHashTable) unread
    = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  g_autoptr (GHashTable) rows = ask_string_set (ask_arr (args, "rows"));
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  GHashTableIter iter;
  gpointer key;
  gpointer value;

  if (!clawt_unread_seed (unread, ask_arr (args, "rooms"), rows,
                          ask_str (args, "viewing")))
    return NULL;

  json_builder_begin_object (builder);
  g_hash_table_iter_init (&iter, unread);

  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      json_builder_set_member_name (builder, key);
      json_builder_add_int_value (builder, GPOINTER_TO_UINT (value));
    }

  json_builder_end_object (builder);
  return ask_finish (builder);
}

/* Every pill added up, less the muted agents' conversations.  */
static char *
ask_unread_total (JsonObject *args)
{
  g_autoptr (GHashTable) unread
    = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  g_autoptr (GHashTable) muted = ask_string_set (ask_arr (args, "muted"));
  JsonObject *counts = ask_obj (args, "unread");
  JsonObjectIter iter;
  const gchar *room;
  JsonNode *node;

  if (counts != NULL)
    {
      json_object_iter_init (&iter, counts);

      while (json_object_iter_next (&iter, &room, &node))
        if (JSON_NODE_HOLDS_VALUE (node))
          g_hash_table_insert (unread, g_strdup (room),
                               GUINT_TO_POINTER (
                                 (guint) json_node_get_int (node)));
    }

  return ask_number (clawt_unread_total (unread, muted));
}

static char *
ask_unread_rule_index (JsonObject *args)
{
  /* An absent `read_upto' is NULL on purpose: a daemon that did not
     say gets no rule, where "" is a room never read.  */
  return ask_number (clawt_unread_rule_index (ask_arr (args, "messages"),
                                              ask_str (args, "read_upto")));
}

static char *
ask_unread_room_agent (JsonObject *args)
{
  return clawt_unread_room_agent (ask_str (args, "room"));
}

static char *
ask_menu_read_label (JsonObject *args)
{
  return clawt_agent_menu_read_label ((guint) ask_int (args, "unread"));
}

static char *
ask_menu_mute_label (JsonObject *args)
{
  return clawt_agent_menu_mute_label (ask_bool (args, "muted"));
}

/* AT and NOW in microseconds, as the library takes them.  */
static char *
ask_time_ago (JsonObject *args)
{
  gint64 now = ask_int (args, "now");

  return clawt_time_ago_label (ask_int (args, "at"),
                               now > 0 ? now : g_get_real_time ());
}

static char *
ask_tree_alert (JsonObject *args)
{
  return clawt_loop_guard_tree_alert_text (ask_str (args, "tree"),
                                           (guint) ask_int (args, "count"),
                                           (guint) ask_int (args, "limit"));
}

/* -- Tasks (clawt-task.h).  -- */

static char *
ask_task_caption (JsonObject *args)
{
  return clawt_task_list_caption (ask_int (args, "since"),
                                  ask_bool (args, "kept"),
                                  ask_int (args, "retention_days"),
                                  ask_now_seconds (args));
}

/* What a task state means for its row: the badge's tone and which of
   Cancel and Retry are offered.  Asked per state so the elisp never
   holds a list of which states are which.  */
static char *
ask_task_state (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  const gchar *nick = ask_str (args, "state");
  const gchar *tone = "neutral";
  gboolean retryable = FALSE;
  gint value = 0;

  if (nick != NULL && clawt_enum_from_nick (CLAWT_TYPE_TASK_STATE, nick,
                                            &value))
    {
      tone = clawt_task_state_tone ((ClawtTaskState) value);
      retryable = clawt_task_state_is_retryable ((ClawtTaskState) value);
    }

  json_builder_begin_object (builder);
  ask_put (builder, "tone", tone);
  ask_put_bool (builder, "retryable", retryable);
  ask_put_bool (builder, "cancellable",
                nick != NULL && clawt_task_state_nick_is_cancellable (nick));
  json_builder_end_object (builder);
  return ask_finish (builder);
}

static char *
ask_task_waiting (JsonObject *args)
{
  JsonArray *waiting = ask_arr (args, "waiting_on");

  return waiting != NULL ? clawt_task_waiting_caption (waiting) : NULL;
}

static char *
ask_task_thread (JsonObject *args)
{
  return clawt_task_thread_summary (ask_str (args, "room"));
}

/* -- The spending ledger (clawt-usage-ledger.h).  -- */

static char *
ask_period_since (JsonObject *args)
{
  return ask_number (clawt_usage_period_since ((guint) ask_int (args,
                                                                "index"),
                                               ask_now_seconds (args)));
}

static char *
ask_ledger_payload (JsonObject *args)
{
  g_autoptr (JsonNode) payload
    = clawt_usage_ledger_payload (ask_int (args, "since"),
                                  ask_str (args, "by"),
                                  ask_str (args, "agent"));

  return payload != NULL ? cmacs_clawt_render_node_to_json (payload) : NULL;
}

/* Everything the Spending page draws from a usage.ledger reply: each
   group's subtitle and cost in the reply's own order, the total's cost,
   the line about turns no price was known for, and the name a CSV of
   it should be saved under.  */
static char *
ask_ledger_view (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  JsonObject *reply = ask_obj (args, "reply");
  JsonArray *groups = ask_arr (reply, "groups");
  JsonObject *total = ask_obj (reply, "total");
  guint i;

  if (reply == NULL)
    return NULL;

  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "groups");
  json_builder_begin_array (builder);

  for (i = 0; groups != NULL && i < json_array_get_length (groups); i++)
    {
      JsonNode *node = json_array_get_element (groups, i);
      JsonObject *group = JSON_NODE_HOLDS_OBJECT (node)
                          ? json_node_get_object (node) : NULL;
      g_autofree gchar *subtitle
        = group != NULL ? clawt_usage_ledger_row_subtitle (group) : NULL;
      g_autofree gchar *cost
        = group != NULL ? clawt_usage_ledger_cost_label (group) : NULL;

      json_builder_begin_object (builder);
      ask_put (builder, "subtitle", subtitle);
      ask_put (builder, "cost", cost);
      json_builder_end_object (builder);
    }

  json_builder_end_array (builder);

  {
    g_autofree gchar *cost
      = total != NULL ? clawt_usage_ledger_cost_label (total) : NULL;
    g_autofree gchar *unpriced = clawt_usage_ledger_unpriced_line (reply);
    g_autofree gchar *name
      = clawt_usage_ledger_csv_name (reply, ask_now_seconds (args));

    ask_put (builder, "total_cost", cost);
    ask_put (builder, "unpriced", unpriced);
    ask_put (builder, "csv_name", name);
  }

  json_builder_end_object (builder);
  return ask_finish (builder);
}

static char *
ask_ledger_csv (JsonObject *args)
{
  JsonObject *reply = ask_obj (args, "reply");

  return reply != NULL ? clawt_usage_ledger_csv (reply) : NULL;
}

/* -- Paired devices (clawt-device-store.h).  -- */

static char *
ask_device_countdown (JsonObject *args)
{
  return clawt_device_countdown_text (ask_int (args, "left"));
}

static char *
ask_device_code (JsonObject *args)
{
  return clawt_device_code_display (ask_str (args, "code") != NULL
                                    ? ask_str (args, "code") : "");
}

static char *
ask_device_code_normalize (JsonObject *args)
{
  return clawt_device_code_normalize (ask_str (args, "text"));
}

static char *
ask_device_seen (JsonObject *args)
{
  return clawt_device_seen_text (ask_int (args, "last_seen"),
                                 ask_bool (args, "connected"),
                                 ask_now_seconds (args));
}

/* The words on a device row's button, or NULL for a row that offers
   none: only the owner revokes somebody else, anybody signs out
   themselves.  */
static char *
ask_device_action (JsonObject *args)
{
  return g_strdup (clawt_device_row_action_label (
    clawt_device_row_action (ask_bool (args, "owner"),
                             ask_bool (args, "current"))));
}

/* -- Memory review, sentinel, rescue, waits, vault.  -- */

static char *
ask_journal_labels (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  const gchar *action = ask_str (args, "action") != NULL
                        ? ask_str (args, "action") : "";

  json_builder_begin_object (builder);
  ask_put (builder, "action", clawt_memory_journal_action_label (action));
  ask_put (builder, "undo", clawt_memory_journal_undo_label (action));
  json_builder_end_object (builder);
  return ask_finish (builder);
}

static char *
ask_ack_model_label (JsonObject *args)
{
  return clawt_ack_check_model_label (ask_str (args, "value"));
}

static char *
ask_sentinel_age (JsonObject *args)
{
  return clawt_sentinel_age_text (ask_int (args, "scanned_at"),
                                  ask_now_seconds (args));
}

static char *
ask_sentinel_kind (JsonObject *args)
{
  return g_strdup (clawt_sentinel_kind_label (ask_str (args, "kind")));
}

static char *
ask_rescue_offer (JsonObject *args)
{
  return clawt_rescue_offer_text (ask_str (args, "agent"),
                                  ask_int (args, "seconds"));
}

static char *
ask_rescue_switch (JsonObject *args)
{
  return clawt_rescue_switch_label (ask_str (args, "model"));
}

/* All four times in microseconds except NOW, which the library also
   takes in microseconds here (clawt_wait_schedule_label).  */
static char *
ask_wait_schedule (JsonObject *args)
{
  gint64 now = ask_int (args, "now");

  return clawt_wait_schedule_label (ask_int (args, "last_check_at"),
                                    ask_int (args, "next_check_at"),
                                    ask_int (args, "expires_at"),
                                    now > 0 ? now : g_get_real_time ());
}

static char *
ask_vault_entry (JsonObject *args)
{
  JsonObject *entry = ask_obj (args, "entry");

  return entry != NULL ? clawt_vault_entry_label (entry) : NULL;
}

/* What `browser.secrets' becomes when the vault entry NAME is granted
   to, or taken from, the agent VAULT is a `vault.list' reply for: the
   whole setting, written by the library, so a client flipping one grant
   cannot drop another.  */
static char *
ask_vault_grants (JsonObject *args)
{
  JsonObject *vault = ask_obj (args, "vault");

  if (vault == NULL || ask_str (args, "name") == NULL)
    return NULL;

  return clawt_vault_grants_with (vault, ask_str (args, "name"),
                                  ask_bool (args, "granted"));
}

/* -- The integration broker (clawt-enums.h).  -- */

/* The broker row: its state's label and which of Start, Stop and
   Restart the state allows.  The same three tests the GTK client makes
   on the enum, made here so the elisp never names a state.  */
static char *
ask_broker_state (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  const gchar *nick = ask_str (args, "state");
  gboolean enabled = ask_bool (args, "enabled");
  gint state = CLAWT_BROKER_STATE_DISABLED;

  if (nick != NULL)
    clawt_enum_from_nick (CLAWT_TYPE_BROKER_STATE, nick, &state);

  json_builder_begin_object (builder);
  ask_put (builder, "label",
           clawt_broker_state_label ((ClawtBrokerState) state));
  ask_put_bool (builder, "running", state == CLAWT_BROKER_STATE_RUNNING);
  ask_put_bool (builder, "start",
                enabled && (state == CLAWT_BROKER_STATE_STOPPED
                            || state == CLAWT_BROKER_STATE_ERROR));
  ask_put_bool (builder, "stop",
                state == CLAWT_BROKER_STATE_STARTING
                || state == CLAWT_BROKER_STATE_RUNNING
                || state == CLAWT_BROKER_STATE_ERROR);
  ask_put_bool (builder, "restart",
                enabled && (state == CLAWT_BROKER_STATE_RUNNING
                            || state == CLAWT_BROKER_STATE_ERROR));
  json_builder_end_object (builder);
  return ask_finish (builder);
}

/* What removing a Grok job is called for its state ("Cancel" for an
   open one, "Remove" for a settled one) and the question asked first:
   an open job has an agent waiting on it.  */
static char *
ask_grok_remove (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  const gchar *nick = ask_str (args, "state");
  gint state = 0;

  if (nick == NULL
      || !clawt_enum_from_nick (CLAWT_TYPE_GROK_JOB_STATE, nick, &state))
    return NULL;

  json_builder_begin_object (builder);
  ask_put (builder, "label",
           clawt_grok_job_remove_label ((ClawtGrokJobState) state));
  ask_put (builder, "question",
           clawt_grok_job_remove_question ((ClawtGrokJobState) state));
  ask_put_bool (builder, "settled",
                clawt_grok_job_state_is_settled ((ClawtGrokJobState) state));
  json_builder_end_object (builder);
  return ask_finish (builder);
}

/* -- The screen, failover, and what a transcript marks.  -- */

static char *
ask_display_status (JsonObject *args)
{
  JsonObject *screen = ask_obj (args, "screen");

  return screen != NULL ? clawt_display_status_line (screen) : NULL;
}

static char *
ask_failover (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  JsonObject *failover = ask_obj (args, "failover");
  g_autofree gchar *badge = NULL;
  g_autofree gchar *sidebar = NULL;

  if (failover == NULL)
    return NULL;

  badge = clawt_failover_badge (failover);
  sidebar = clawt_failover_sidebar_badge (failover);

  json_builder_begin_object (builder);
  ask_put (builder, "badge", badge);
  ask_put (builder, "sidebar", sidebar);
  json_builder_end_object (builder);
  return ask_finish (builder);
}

/* The transcript's fixed words, in one answer: they take no argument
   and a transcript wants all of them.  */
static char *
ask_message_labels (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();

  (void) args;

  json_builder_begin_object (builder);
  ask_put (builder, "steered", clawt_message_steered_label ());
  ask_put (builder, "interrupted", clawt_message_interrupted_label ());
  ask_put (builder, "interrupted_tooltip",
           clawt_message_interrupted_tooltip ());
  ask_put (builder, "ack", clawt_message_ack_label ());
  ask_put (builder, "ack_tooltip", clawt_message_ack_tooltip ());
  ask_put (builder, "waiting_tooltip", clawt_message_waiting_tooltip ());
  ask_put (builder, "consult_tooltip", clawt_message_consult_tooltip ());
  ask_put (builder, "task_consult", clawt_task_consult_label ());
  ask_put (builder, "round_skip_tooltip", clawt_round_skip_tooltip ());
  ask_put (builder, "fold_less", clawt_chat_fold_show_less_label ());
  ask_put (builder, "fold_exchange",
           clawt_chat_fold_view_exchange_label ());
  ask_put (builder, "crosstalk", clawt_crosstalk_mark_label ());
  ask_put (builder, "crosstalk_tooltip", clawt_crosstalk_mark_tooltip ());
  ask_put (builder, "routine_failures_hint",
           clawt_routine_start_failures_hint ());
  /* How an answer given from a transcript is recorded.  */
  ask_put (builder, "decision_via_chat", CLAWT_DECISION_VIA_CHAT);
  ask_put (builder, "egress_allowlist", clawt_egress_allowlist_label ());
  ask_put (builder, "egress_allowlist_explanation",
           clawt_egress_allowlist_explanation ());
  json_builder_end_object (builder);
  return ask_finish (builder);
}

static char *
ask_message_waiting (JsonObject *args)
{
  return clawt_message_waiting_note (ask_str (args, "waiting_on"));
}

static char *
ask_message_answer (JsonObject *args)
{
  return clawt_message_answer_label (ask_str (args, "answer_from"));
}

static char *
ask_message_consult (JsonObject *args)
{
  return g_strdup (clawt_message_consult_label ((gint) ask_int (args,
                                                                 "role")));
}

static char *
ask_steered_tooltip (JsonObject *args)
{
  return g_strdup (clawt_message_steered_tooltip (ask_str (args,
                                                            "outcome")));
}

static char *
ask_round_label (JsonObject *args)
{
  return clawt_round_label ((guint) ask_int (args, "round"));
}

static char *
ask_round_skip (JsonObject *args)
{
  return clawt_round_skip_note (ask_str (args, "skipped"),
                                ask_str (args, "reason"));
}

static char *
ask_routine_turned_off (JsonObject *args)
{
  return clawt_routine_turned_off_note ((guint) ask_int (args, "failures"),
                                        ask_str (args, "error"));
}

/* Whether a message folds, and what stands in for it folded.  An
   agent-to-agent exchange in your own conversation with one of them is
   long and not addressed to you; the rule for which is the library's.  */
static char *
ask_chat_fold (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  const gchar *body = ask_str (args, "body");
  gboolean fold = clawt_chat_should_fold (ask_str (args, "sender"),
                                          ask_str (args, "viewer"), body);
  g_autofree gchar *preview = fold ? clawt_chat_fold_preview (body) : NULL;

  json_builder_begin_object (builder);
  ask_put_bool (builder, "fold", fold);
  ask_put (builder, "preview", preview);
  json_builder_end_object (builder);
  return ask_finish (builder);
}

static char *
ask_exchange_title (JsonObject *args)
{
  return clawt_chat_exchange_title (ask_str (args, "agent"),
                                    ask_str (args, "peer"));
}

static char *
ask_crosstalk_flow (JsonObject *args)
{
  return clawt_crosstalk_flow_label ((guint) ask_int (args, "index"),
                                     (guint) ask_int (args, "total"));
}

static char *
ask_room_subtitle (JsonObject *args)
{
  return clawt_room_sidebar_subtitle (ask_str (args, "room"),
                                      (guint) ask_int (args, "members"),
                                      ask_bool (args, "require_mention"));
}

static char *
ask_app_link_label (JsonObject *args)
{
  return clawt_mcp_app_link_label (ask_str (args, "title"));
}

static char *
ask_hold_label (JsonObject *args)
{
  return clawt_hold_label (ask_bool (args, "held"),
                           ask_bool (args, "draining"));
}

static char *
ask_egress_status (JsonObject *args)
{
  return clawt_egress_status_line (ask_str (args, "network"),
                                   (guint) ask_int (args, "refused"));
}

/* -- Decisions (clawt-decision.h).  -- */

static char *
ask_decision_question (JsonObject *args)
{
  return clawt_decision_question_text (ask_str (args, "question"),
                                       ask_str (args, "loses"));
}

/* What the library says about one decision from `decision.list': how
   it ended, where it was routed and what happens if nobody answers.  */
static char *
ask_decision_view (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  JsonObject *object = ask_obj (args, "decision");
  g_autoptr (ClawtDecision) decision = NULL;
  g_autofree gchar *outcome = NULL;
  g_autofree gchar *routed = NULL;
  g_autofree gchar *fallback = NULL;

  if (object == NULL)
    return NULL;

  decision = clawt_decision_new_from_object (object);

  if (decision == NULL)
    return NULL;

  outcome = clawt_decision_outcome_text (decision);
  routed = clawt_decision_routed_text (decision);
  fallback = clawt_decision_default_text (decision, NULL);

  json_builder_begin_object (builder);
  ask_put (builder, "outcome", outcome);
  ask_put (builder, "routed", routed);
  ask_put (builder, "default", fallback);
  json_builder_end_object (builder);
  return ask_finish (builder);
}

static char *
ask_skill_proposal_p (JsonObject *args)
{
  return clawt_skill_proposal_id_is_valid (ask_str (args, "id"))
         ? g_strdup ("t") : NULL;
}

/* -- Files sent with a message (clawt-attachment.h).  -- */

/* The body of a message with files, in the one spelling every client
   previews from and `attachment.list' finds.  ITEMS are what
   `attachment.put' answered for each file -- `name', `host_path',
   `path' and `id' -- or just a `name' with `unsaved' true for one the
   daemon refused: listed rather than dropped, because an agent told
   nothing about a file it was meant to have answers as if it had been
   sent nothing.  */
static char *
ask_attachment_block (JsonObject *args)
{
  JsonArray *items = ask_arr (args, "items");
  GString *block = clawt_attachment_block_new (ask_str (args, "body") != NULL
                                               ? ask_str (args, "body") : "");
  guint i;

  for (i = 0; items != NULL && i < json_array_get_length (items); i++)
    {
      JsonNode *node = json_array_get_element (items, i);
      JsonObject *item = JSON_NODE_HOLDS_OBJECT (node)
                         ? json_node_get_object (node) : NULL;
      const gchar *name = ask_str (item, "name");

      if (name == NULL)
        continue;

      if (ask_bool (item, "unsaved"))
        clawt_attachment_block_add_unsaved (block, name);
      else
        clawt_attachment_block_add (block, name,
                                    ask_str (item, "host_path") != NULL
                                    ? ask_str (item, "host_path") : "",
                                    ask_str (item, "path") != NULL
                                    ? ask_str (item, "path") : "",
                                    ask_str (item, "id"));
    }

  return g_string_free (block, FALSE);
}

/* -- Deep links (clawt-open-target.h).  -- */

/* Where a link such as `clawtilla://scout', or the bare name somebody
   typed, leads: an agent's conversation, the exchange between an agent
   and a peer, or a room.  AGENTS and ROOMS are `agent.list' and
   `room.list' as the daemon sent them.  An object with `agent', `peer'
   and `room' (each a string or null), or with `error' -- the library's
   own sentence for a target that names nothing in this fleet.  */
static char *
ask_open_target (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (GError) error = NULL;
  g_autofree gchar *target = NULL;
  g_autofree gchar *agent = NULL;
  g_autofree gchar *peer = NULL;
  g_autofree gchar *room = NULL;

  json_builder_begin_object (builder);

  target = clawt_open_target_normalize (ask_str (args, "text"), &error);

  if (target == NULL
      || !clawt_open_target_resolve (target, ask_arr (args, "agents"),
                                     ask_arr (args, "rooms"), &agent, &peer,
                                     &room, &error))
    ask_put (builder, "error",
             error != NULL ? error->message : "that names nothing here");
  else
    {
      ask_put (builder, "agent", agent);
      ask_put (builder, "peer", peer);
      ask_put (builder, "room", room);
    }

  json_builder_end_object (builder);
  return ask_finish (builder);
}

/* -- QR codes (clawt-qr.h).  -- */

/* A pairing link as a QR code: `size' modules a side and `rows', one
   string of 0 and 1 per row, dark being 1.  The drawing is the
   caller's -- an SVG where Emacs has one, half blocks where it has not.
   NULL when libclawt was built without libqrencode or the text does not
   fit, and the caller shows the link itself instead.  */
static char *
ask_qr (JsonObject *args)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (GBytes) modules = NULL;
  const guint8 *data;
  gsize length = 0;
  guint size = 0;
  guint row;
  guint column;

  if (ask_str (args, "text") == NULL)
    return NULL;

  modules = clawt_qr_encode (ask_str (args, "text"), &size, NULL);

  if (modules == NULL || size == 0)
    return NULL;

  data = g_bytes_get_data (modules, &length);

  if (length < (gsize) size * size)
    return NULL;

  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "size");
  json_builder_add_int_value (builder, size);
  json_builder_set_member_name (builder, "rows");
  json_builder_begin_array (builder);

  for (row = 0; row < size; row++)
    {
      g_autofree gchar *line = g_malloc (size + 1);

      for (column = 0; column < size; column++)
        line[column] = data[(gsize) row * size + column] ? '1' : '0';

      line[size] = '\0';
      json_builder_add_string_value (builder, line);
    }

  json_builder_end_array (builder);
  json_builder_end_object (builder);
  return ask_finish (builder);
}

/* The same code as text, for a frame that draws no images.  */
static char *
ask_qr_terminal (JsonObject *args)
{
  if (ask_str (args, "text") == NULL)
    return NULL;

  return clawt_qr_render_terminal (ask_str (args, "text"),
                                   ask_bool (args, "light"), NULL);
}

typedef char *(*CmacsClawtAskFn) (JsonObject *args);

static const struct
{
  const char      *name;
  CmacsClawtAskFn  answer;
} cmacs_clawt_questions[] = {
  { "notice-badge",          ask_notice_badge },
  { "notice-mutes",          ask_notice_mutes },
  { "unread-seed",           ask_unread_seed },
  { "unread-total",          ask_unread_total },
  { "unread-rule-index",     ask_unread_rule_index },
  { "unread-room-agent",     ask_unread_room_agent },
  { "menu-read-label",       ask_menu_read_label },
  { "menu-mute-label",       ask_menu_mute_label },
  { "time-ago",              ask_time_ago },
  { "tree-alert",            ask_tree_alert },
  { "task-caption",          ask_task_caption },
  { "task-state",            ask_task_state },
  { "task-waiting",          ask_task_waiting },
  { "task-thread",           ask_task_thread },
  { "period-since",          ask_period_since },
  { "ledger-payload",        ask_ledger_payload },
  { "ledger-view",           ask_ledger_view },
  { "ledger-csv",            ask_ledger_csv },
  { "device-countdown",      ask_device_countdown },
  { "device-code",           ask_device_code },
  { "device-code-normalize", ask_device_code_normalize },
  { "device-seen",           ask_device_seen },
  { "device-action",         ask_device_action },
  { "journal-labels",        ask_journal_labels },
  { "ack-model-label",       ask_ack_model_label },
  { "sentinel-age",          ask_sentinel_age },
  { "sentinel-kind",         ask_sentinel_kind },
  { "rescue-offer",          ask_rescue_offer },
  { "rescue-switch",         ask_rescue_switch },
  { "wait-schedule",         ask_wait_schedule },
  { "vault-entry",           ask_vault_entry },
  { "vault-grants",          ask_vault_grants },
  { "broker-state",          ask_broker_state },
  { "grok-remove",           ask_grok_remove },
  { "display-status",        ask_display_status },
  { "failover",              ask_failover },
  { "message-labels",        ask_message_labels },
  { "message-waiting",       ask_message_waiting },
  { "message-answer",        ask_message_answer },
  { "message-consult",       ask_message_consult },
  { "steered-tooltip",       ask_steered_tooltip },
  { "round-label",           ask_round_label },
  { "round-skip",            ask_round_skip },
  { "routine-turned-off",    ask_routine_turned_off },
  { "chat-fold",             ask_chat_fold },
  { "exchange-title",        ask_exchange_title },
  { "crosstalk-flow",        ask_crosstalk_flow },
  { "room-subtitle",         ask_room_subtitle },
  { "app-link-label",        ask_app_link_label },
  { "hold-label",            ask_hold_label },
  { "egress-status",         ask_egress_status },
  { "decision-question",     ask_decision_question },
  { "decision-view",         ask_decision_view },
  { "skill-proposal-p",      ask_skill_proposal_p },
  { "attachment-block",      ask_attachment_block },
  { "open-target",           ask_open_target },
  { "qr",                    ask_qr },
  { "qr-terminal",           ask_qr_terminal },
};

char *
cmacs_clawt_ask (const char *what, const char *args_json)
{
  g_autoptr (JsonNode) node = cmacs_clawt_render_parse (args_json);
  JsonObject *args = (node != NULL && JSON_NODE_HOLDS_OBJECT (node))
                     ? json_node_get_object (node) : NULL;
  gsize i;

  if (what == NULL)
    return NULL;

  for (i = 0; i < G_N_ELEMENTS (cmacs_clawt_questions); i++)
    if (g_str_equal (cmacs_clawt_questions[i].name, what))
      return cmacs_clawt_questions[i].answer (args);

  return NULL;
}

/* The questions `cmacs_clawt_ask' answers, as a JSON array of names --
   so a test can hold the elisp to the table instead of to a copy.  */
char *
cmacs_clawt_ask_names (void)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  gsize i;

  json_builder_begin_array (builder);

  for (i = 0; i < G_N_ELEMENTS (cmacs_clawt_questions); i++)
    json_builder_add_string_value (builder, cmacs_clawt_questions[i].name);

  json_builder_end_array (builder);
  return ask_finish (builder);
}

#endif /* HAVE_CMACS_CLAWTILLA */
