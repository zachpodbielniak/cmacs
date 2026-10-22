/* Camera capture for CMacs -- the GStreamer pipeline.

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

SPDX-License-Identifier: AGPL-3.0-or-later

See cmacs-camera.h.  Threads: open/close and the bus watch run on the
main thread (the bus GSource is on the CMacs GMainContext); frames run
on GStreamer's streaming thread.  The two meet only under `cam.lock'
(latest frame, consumers) and in atomics (counts).  */

#include <config.h>

#ifdef HAVE_CMACS_CAMERA

#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>

#include "cmacs-glib-loop.h"
#include "cmacs-camera.h"

typedef struct
{
  guint id;
  CmacsCameraFrameFunc fn;
  gpointer data;
} Consumer;

static struct
{
  bool inited;
  GstElement *pipeline;
  GSource *bus_watch;
  char *desc;                    /* what was opened, for status */
  char *error;                   /* last error, kept after a close */
  int width, height, fps;

  /* Portal open in flight (sandboxed).  */
  bool pending;
  GDBusConnection *bus;
  guint portal_sub;
  char *portal_request;

  GMutex lock;                   /* everything below */
  GArray *consumers;             /* of Consumer */
  guint next_consumer;
  guint64 frames;                /* frames delivered since the open */
  guint8 *latest;                /* packed RGB, width * 3 per row */
  int latest_w, latest_h;
} cam;

static void set_error (const char *fmt, ...) G_GNUC_PRINTF (1, 2);

static void
set_error (const char *fmt, ...)
{
  va_list ap;

  g_free (cam.error);
  va_start (ap, fmt);
  cam.error = g_strdup_vprintf (fmt, ap);
  va_end (ap);
}

bool
cmacs_camera_init (char **err)
{
  GError *gerr = NULL;

  if (cam.inited)
    return true;
  if (!gst_init_check (NULL, NULL, &gerr))
    {
      if (err != NULL)
        *err = g_strdup (gerr != NULL ? gerr->message : "gst_init failed");
      g_clear_error (&gerr);
      return false;
    }
  g_mutex_init (&cam.lock);
  cam.consumers = g_array_new (FALSE, FALSE, sizeof (Consumer));
  cam.inited = true;
  return true;
}

bool
cmacs_camera_sandboxed (void)
{
  return g_file_test ("/.flatpak-info", G_FILE_TEST_EXISTS);
}

/* --------------------------------------------------------------- frames -- */

static GstFlowReturn
on_new_sample (GstAppSink *sink, gpointer data)
{
  GstSample *sample = gst_app_sink_pull_sample (sink);
  GstVideoInfo info;
  GstMapInfo map;
  GstBuffer *buf;
  guint i;
  int w, h, stride, y;

  (void) data;
  if (sample == NULL)
    return GST_FLOW_OK;
  buf = gst_sample_get_buffer (sample);
  if (buf == NULL || !gst_video_info_from_caps (&info, gst_sample_get_caps (sample))
      || !gst_buffer_map (buf, &map, GST_MAP_READ))
    {
      gst_sample_unref (sample);
      return GST_FLOW_OK;
    }
  w = GST_VIDEO_INFO_WIDTH (&info);
  h = GST_VIDEO_INFO_HEIGHT (&info);
  stride = GST_VIDEO_INFO_PLANE_STRIDE (&info, 0);
  if (w > 0 && h > 0 && map.size >= (gsize) stride * (gsize) h)
    {
      gint64 pts = GST_BUFFER_PTS_IS_VALID (buf)
                   ? (gint64) (GST_BUFFER_PTS (buf) / 1000) : g_get_monotonic_time ();

      g_mutex_lock (&cam.lock);
      /* The latest frame, kept for the preview -- in memory only.  */
      if (cam.latest == NULL || cam.latest_w != w || cam.latest_h != h)
        {
          g_free (cam.latest);
          cam.latest = g_malloc ((gsize) w * (gsize) h * 3);
          cam.latest_w = w;
          cam.latest_h = h;
        }
      for (y = 0; y < h; y++)
        memcpy (cam.latest + (gsize) y * (gsize) w * 3,
                map.data + (gsize) y * (gsize) stride, (gsize) w * 3);
      for (i = 0; i < cam.consumers->len; i++)
        {
          Consumer *c = &g_array_index (cam.consumers, Consumer, i);
          c->fn (map.data, w, h, stride, pts, c->data);
        }
      cam.frames++;
      g_mutex_unlock (&cam.lock);
    }
  gst_buffer_unmap (buf, &map);
  gst_sample_unref (sample);
  return GST_FLOW_OK;
}

guint
cmacs_camera_add_consumer (CmacsCameraFrameFunc fn, gpointer data)
{
  Consumer c;

  g_return_val_if_fail (cam.inited, 0);
  g_mutex_lock (&cam.lock);
  c.id = ++cam.next_consumer;
  c.fn = fn;
  c.data = data;
  g_array_append_val (cam.consumers, c);
  g_mutex_unlock (&cam.lock);
  return c.id;
}

void
cmacs_camera_remove_consumer (guint id)
{
  guint i;

  if (!cam.inited)
    return;
  /* Under the lock the streaming thread calls consumers with, so once
     this returns the consumer is never called again.  */
  g_mutex_lock (&cam.lock);
  for (i = 0; i < cam.consumers->len; i++)
    if (g_array_index (cam.consumers, Consumer, i).id == id)
      {
        g_array_remove_index (cam.consumers, i);
        break;
      }
  g_mutex_unlock (&cam.lock);
}

guint8 *
cmacs_camera_latest_rgb (int max_width, int *width, int *height)
{
  guint8 *out = NULL;
  int w, h, ow, oh, x, y;

  if (!cam.inited)
    return NULL;
  g_mutex_lock (&cam.lock);
  if (cam.latest != NULL)
    {
      w = cam.latest_w;
      h = cam.latest_h;
      ow = (max_width > 0 && max_width < w) ? max_width : w;
      oh = (int) ((gint64) h * ow / w);
      if (oh < 1)
        oh = 1;
      out = g_malloc ((gsize) ow * (gsize) oh * 3);
      for (y = 0; y < oh; y++)
        {
          const guint8 *src = cam.latest + (gsize) (y * h / oh) * (gsize) w * 3;
          for (x = 0; x < ow; x++)
            memcpy (out + ((gsize) y * ow + x) * 3, src + (gsize) (x * w / ow) * 3, 3);
        }
      *width = ow;
      *height = oh;
    }
  g_mutex_unlock (&cam.lock);
  return out;
}

guint64
cmacs_camera_frame_count (void)
{
  guint64 n;

  if (!cam.inited)
    return 0;
  g_mutex_lock (&cam.lock);
  n = cam.frames;
  g_mutex_unlock (&cam.lock);
  return n;
}

void
cmacs_camera_frame_size (int *width, int *height)
{
  *width = cam.width;
  *height = cam.height;
}

/* ------------------------------------------------------------- pipeline -- */

static gboolean
on_bus (GstBus *bus, GstMessage *msg, gpointer data)
{
  (void) bus;
  (void) data;
  if (GST_MESSAGE_TYPE (msg) == GST_MESSAGE_ERROR
      || GST_MESSAGE_TYPE (msg) == GST_MESSAGE_EOS)
    {
      GError *gerr = NULL;
      gchar *dbg = NULL;

      if (GST_MESSAGE_TYPE (msg) == GST_MESSAGE_ERROR)
        {
          gst_message_parse_error (msg, &gerr, &dbg);
          set_error ("%s", gerr != NULL ? gerr->message : "camera error");
          g_clear_error (&gerr);
          g_free (dbg);
        }
      else
        set_error ("the camera stream ended");
      /* Main thread (the watch is on the CMacs context): close now, so
         a failed camera is not left half open.  Returning REMOVE
         destroys the watch; only our own reference is left to drop (the
         context holds one until this dispatch returns).  */
      {
        GSource *w = cam.bus_watch;

        cam.bus_watch = NULL;
        cmacs_camera_close ();
        if (w != NULL)
          g_source_unref (w);
      }
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

/* The source element for SPEC, or NULL with *ERR.  */
static GstElement *
make_source (const char *spec, char **err)
{
  GstElement *src = NULL;

  if (spec == NULL || *spec == '\0')
    {
      GPtrArray *devs = cmacs_camera_list_devices ();

      if (devs->len == 0)
        *err = g_strdup ("no camera found (is one connected, and is "
                         "PipeWire or a /dev/video* node available?)");
      else
        {
          CmacsCameraDevice *d = g_ptr_array_index (devs, 0);
          src = make_source (d->spec, err);
          if (src != NULL)
            {
              g_free (cam.desc);
              cam.desc = g_strdup_printf ("%s (%s)", d->name, d->api);
            }
        }
      g_ptr_array_unref (devs);
      return src;
    }
  if (g_str_has_prefix (spec, "test"))
    {
      src = gst_element_factory_make ("videotestsrc", NULL);
      if (src != NULL)
        {
          g_object_set (src, "is-live", TRUE, NULL);
          if (spec[4] == ':' && spec[5] != '\0')
            gst_util_set_object_arg (G_OBJECT (src), "pattern", spec + 5);
        }
    }
  else if (g_str_has_prefix (spec, "/dev/"))
    {
      src = gst_element_factory_make ("v4l2src", NULL);
      if (src != NULL)
        g_object_set (src, "device", spec, NULL);
    }
  else if (g_str_has_prefix (spec, "pipewire:"))
    {
      src = gst_element_factory_make ("pipewiresrc", NULL);
      if (src != NULL)
        g_object_set (src, "target-object", spec + 9, NULL);
    }
  else if (g_str_has_prefix (spec, "pipewire-fd:"))
    {
      src = gst_element_factory_make ("pipewiresrc", NULL);
      if (src != NULL)
        g_object_set (src, "fd", (gint) g_ascii_strtoll (spec + 12, NULL, 10),
                      NULL);
    }
  else
    {
      /* A device by (part of) its name.  */
      GPtrArray *devs = cmacs_camera_list_devices ();
      guint i;

      for (i = 0; i < devs->len; i++)
        {
          CmacsCameraDevice *d = g_ptr_array_index (devs, i);
          if (strstr (d->name, spec) != NULL)
            {
              src = make_source (d->spec, err);
              break;
            }
        }
      if (src == NULL && *err == NULL)
        *err = g_strdup_printf ("no camera matches \"%s\"", spec);
      g_ptr_array_unref (devs);
      return src;
    }
  if (src == NULL && *err == NULL)
    *err = g_strdup_printf ("no GStreamer element for \"%s\" (videotestsrc "
                            "is in gst-plugins-base, v4l2src in "
                            "gst-plugins-good, pipewiresrc in "
                            "pipewire-gstreamer)", spec);
  return src;
}

/* Build and start the pipeline from SRC.  Takes ownership of SRC.  */
static bool
start_pipeline (GstElement *src, char **err)
{
  GstElement *tail, *sink;
  GstBus *bus;
  GError *gerr = NULL;
  gchar *desc;

  desc = g_strdup_printf ("videoconvert ! videoscale ! videorate ! "
                          "video/x-raw,format=RGB,width=%d,height=%d,"
                          "framerate=%d/1,pixel-aspect-ratio=1/1 ! "
                          "appsink name=sink max-buffers=1 drop=true "
                          "sync=false emit-signals=true",
                          cam.width, cam.height, cam.fps);
  tail = gst_parse_bin_from_description (desc, TRUE, &gerr);
  g_free (desc);
  if (tail == NULL)
    {
      *err = g_strdup (gerr != NULL ? gerr->message : "pipeline");
      g_clear_error (&gerr);
      gst_object_unref (gst_object_ref_sink (src));
      return false;
    }
  cam.pipeline = gst_pipeline_new ("cmacs-camera");
  gst_bin_add_many (GST_BIN (cam.pipeline), src, tail, NULL);
  if (!gst_element_link (src, tail))
    {
      *err = g_strdup ("cannot link the camera source to the converter");
      cmacs_camera_close ();
      return false;
    }
  sink = gst_bin_get_by_name (GST_BIN (tail), "sink");
  g_signal_connect (sink, "new-sample", G_CALLBACK (on_new_sample), NULL);
  gst_object_unref (sink);

  bus = gst_element_get_bus (cam.pipeline);
  cam.bus_watch = gst_bus_create_watch (bus);
  g_source_set_callback (cam.bus_watch, G_SOURCE_FUNC (on_bus), NULL, NULL);
  g_source_attach (cam.bus_watch, cmacs_glib_get_context ());
  gst_object_unref (bus);

  if (gst_element_set_state (cam.pipeline, GST_STATE_PLAYING)
      == GST_STATE_CHANGE_FAILURE)
    {
      *err = g_strdup ("the camera would not start (in use by another "
                       "program, or no permission?)");
      cmacs_camera_close ();
      return false;
    }
  return true;
}

/* --------------------------------------------------------------- portal -- */

/* Inside a Flatpak the camera is reached through xdg-desktop-portal:
   AccessCamera (the user may be asked), then OpenPipeWireRemote hands
   back a PipeWire socket restricted to cameras, for pipewiresrc fd=.
   All asynchronous -- the portal's dialog must not block Emacs -- with
   the CMacs context pushed as thread-default so the replies and the
   Response signal are dispatched there, on the main thread.  */

static void
portal_fail (const char *why)
{
  set_error ("camera portal: %s", why);
  cam.pending = false;
  if (cam.portal_sub != 0 && cam.bus != NULL)
    g_dbus_connection_signal_unsubscribe (cam.bus, cam.portal_sub);
  cam.portal_sub = 0;
}

static void
portal_opened (GObject *source, GAsyncResult *res, gpointer data)
{
  GUnixFDList *fds = NULL;
  GError *gerr = NULL;
  GVariant *ret;
  char *err = NULL, spec[64];
  gint32 idx;
  int fd;

  (void) data;
  ret = g_dbus_connection_call_with_unix_fd_list_finish
    (G_DBUS_CONNECTION (source), &fds, res, &gerr);
  if (ret == NULL || !cam.pending)
    {
      if (cam.pending)
        portal_fail (gerr != NULL ? gerr->message : "OpenPipeWireRemote");
      g_clear_error (&gerr);
      if (ret != NULL)
        g_variant_unref (ret);
      g_clear_object (&fds);
      return;
    }
  g_variant_get (ret, "(h)", &idx);
  g_variant_unref (ret);
  fd = fds != NULL ? g_unix_fd_list_get (fds, idx, &gerr) : -1;
  g_clear_object (&fds);
  cam.pending = false;
  if (fd < 0)
    {
      set_error ("camera portal: no PipeWire fd");
      g_clear_error (&gerr);
      return;
    }
  g_snprintf (spec, sizeof spec, "pipewire-fd:%d", fd);
  {
    GstElement *src = make_source (spec, &err);
    if (src == NULL || !start_pipeline (src, &err))
      {
        set_error ("%s", err != NULL ? err : "camera");
        close (fd);
      }
    else
      {
        g_free (cam.desc);
        cam.desc = g_strdup ("xdg-desktop-portal Camera (pipewire)");
      }
  }
  g_free (err);
}

static void
portal_response (GDBusConnection *conn, const gchar *sender,
                 const gchar *path, const gchar *iface, const gchar *signal,
                 GVariant *params, gpointer data)
{
  guint32 response = 2;

  (void) sender; (void) path; (void) iface; (void) signal; (void) data;
  g_variant_get (params, "(u@a{sv})", &response, NULL);
  g_dbus_connection_signal_unsubscribe (conn, cam.portal_sub);
  cam.portal_sub = 0;
  if (!cam.pending)
    return;
  if (response != 0)
    {
      portal_fail (response == 1 ? "access denied" : "request cancelled");
      return;
    }
  g_main_context_push_thread_default (cmacs_glib_get_context ());
  g_dbus_connection_call_with_unix_fd_list
    (conn, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
     "org.freedesktop.portal.Camera", "OpenPipeWireRemote",
     g_variant_new ("(a{sv})", NULL), G_VARIANT_TYPE ("(h)"),
     G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, portal_opened, NULL);
  g_main_context_pop_thread_default (cmacs_glib_get_context ());
}

static void
portal_requested (GObject *source, GAsyncResult *res, gpointer data)
{
  GError *gerr = NULL;
  GVariant *ret = g_dbus_connection_call_finish (G_DBUS_CONNECTION (source),
                                                 res, &gerr);

  (void) data;
  if (ret == NULL)
    {
      portal_fail (gerr != NULL ? gerr->message : "AccessCamera");
      g_clear_error (&gerr);
      return;
    }
  g_variant_unref (ret);   /* the Response signal carries the answer */
}

static bool
portal_open (char **err)
{
  GError *gerr = NULL;
  GVariantBuilder opts;
  char *sender, *p, token[32];

  if (cam.bus == NULL)
    cam.bus = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, &gerr);
  if (cam.bus == NULL)
    {
      *err = g_strdup_printf ("camera portal: %s",
                              gerr != NULL ? gerr->message : "no session bus");
      g_clear_error (&gerr);
      return false;
    }
  /* The request path is predictable; subscribe before asking, so the
     Response cannot arrive before the subscription.  */
  g_snprintf (token, sizeof token, "cmacs%u", g_random_int ());
  sender = g_strdup (g_dbus_connection_get_unique_name (cam.bus) + 1);
  for (p = sender; *p != '\0'; p++)
    if (*p == '.')
      *p = '_';
  g_free (cam.portal_request);
  cam.portal_request = g_strdup_printf
    ("/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
  g_free (sender);

  g_main_context_push_thread_default (cmacs_glib_get_context ());
  cam.portal_sub = g_dbus_connection_signal_subscribe
    (cam.bus, "org.freedesktop.portal.Desktop",
     "org.freedesktop.portal.Request", "Response", cam.portal_request, NULL,
     G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, portal_response, NULL, NULL);
  g_variant_builder_init (&opts, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&opts, "{sv}", "handle_token",
                         g_variant_new_string (token));
  g_dbus_connection_call (cam.bus, "org.freedesktop.portal.Desktop",
                          "/org/freedesktop/portal/desktop",
                          "org.freedesktop.portal.Camera", "AccessCamera",
                          g_variant_new ("(a{sv})", &opts),
                          G_VARIANT_TYPE ("(o)"), G_DBUS_CALL_FLAGS_NONE, -1,
                          NULL, portal_requested, NULL);
  g_main_context_pop_thread_default (cmacs_glib_get_context ());
  cam.pending = true;
  g_free (cam.desc);
  cam.desc = g_strdup ("xdg-desktop-portal Camera (waiting)");
  return true;
}

/* ------------------------------------------------------------- open/close */

bool
cmacs_camera_open (const char *spec, int width, int height, int fps,
                   char **err)
{
  GstElement *src;

  *err = NULL;
  if (!cmacs_camera_init (err))
    return false;
  cmacs_camera_close ();
  g_clear_pointer (&cam.error, g_free);
  cam.width = CLAMP (width, 16, 3840);
  cam.height = CLAMP (height, 16, 2160);
  cam.fps = CLAMP (fps, 1, 120);
  g_mutex_lock (&cam.lock);
  cam.frames = 0;
  g_mutex_unlock (&cam.lock);
  g_free (cam.desc);
  cam.desc = g_strdup (spec != NULL && *spec != '\0' ? spec : "auto");

  if ((spec != NULL && strcmp (spec, "portal") == 0)
      || ((spec == NULL || *spec == '\0') && cmacs_camera_sandboxed ()))
    return portal_open (err);

  src = make_source (spec, err);
  if (src == NULL)
    return false;
  return start_pipeline (src, err);
}

void
cmacs_camera_close (void)
{
  if (!cam.inited)
    return;
  cam.pending = false;
  if (cam.portal_sub != 0 && cam.bus != NULL)
    g_dbus_connection_signal_unsubscribe (cam.bus, cam.portal_sub);
  cam.portal_sub = 0;
  if (cam.bus_watch != NULL)
    {
      g_source_destroy (cam.bus_watch);
      g_source_unref (cam.bus_watch);
      cam.bus_watch = NULL;
    }
  if (cam.pipeline != NULL)
    {
      /* NULL state joins the streaming thread and releases the device:
         the camera (and its light) is off when this returns.  */
      gst_element_set_state (cam.pipeline, GST_STATE_NULL);
      gst_object_unref (cam.pipeline);
      cam.pipeline = NULL;
    }
  g_mutex_lock (&cam.lock);
  g_clear_pointer (&cam.latest, g_free);
  cam.latest_w = cam.latest_h = 0;
  g_mutex_unlock (&cam.lock);
}

bool
cmacs_camera_is_open (void)
{
  return cam.pipeline != NULL;
}

bool
cmacs_camera_is_pending (void)
{
  return cam.pending;
}

const char *
cmacs_camera_source_desc (void)
{
  return cam.pipeline != NULL || cam.pending ? cam.desc : NULL;
}

const char *
cmacs_camera_last_error (void)
{
  return cam.error;
}

/* -------------------------------------------------------------- devices -- */

static void
device_free (gpointer p)
{
  CmacsCameraDevice *d = p;

  g_free (d->name);
  g_free (d->api);
  g_free (d->spec);
  g_free (d);
}

GPtrArray *
cmacs_camera_list_devices (void)
{
  GPtrArray *out = g_ptr_array_new_with_free_func (device_free);
  GstDeviceMonitor *mon;
  GList *devs, *l;
  int pass;

  if (!cam.inited)
    {
      char *err = NULL;
      if (!cmacs_camera_init (&err))
        {
          g_free (err);
          return out;
        }
    }
  mon = gst_device_monitor_new ();
  gst_device_monitor_add_filter (mon, "Video/Source", NULL);
  if (!gst_device_monitor_start (mon))
    {
      gst_object_unref (mon);
      return out;
    }
  devs = gst_device_monitor_get_devices (mon);
  gst_device_monitor_stop (mon);

  /* PipeWire's devices first: they are what a desktop session shares
     and arbitrates; V4L2 nodes after.  */
  for (pass = 0; pass < 2; pass++)
    for (l = devs; l != NULL; l = l->next)
      {
        GstDevice *dev = l->data;
        GstStructure *props = gst_device_get_properties (dev);
        const gchar *api = props != NULL
                           ? gst_structure_get_string (props, "device.api") : NULL;
        const gchar *path = props != NULL
                            ? gst_structure_get_string (props, "device.path")
                            : NULL;
        const gchar *serial = props != NULL
                              ? gst_structure_get_string (props, "object.serial")
                              : NULL;
        gchar *name = gst_device_get_display_name (dev);
        gboolean pw = serial != NULL || g_strcmp0 (api, "pipewire") == 0;
        CmacsCameraDevice *d;

        if ((pass == 0) != (pw != FALSE))
          {
            g_free (name);
            if (props != NULL)
              gst_structure_free (props);
            continue;
          }
        d = g_new0 (CmacsCameraDevice, 1);
        d->name = name;
        d->api = g_strdup (pw ? "pipewire" : (api != NULL ? api : "v4l2"));
        if (pw && serial != NULL)
          d->spec = g_strdup_printf ("pipewire:%s", serial);
        else if (path != NULL)
          d->spec = g_strdup (path);
        else
          d->spec = g_strdup (name);
        g_ptr_array_add (out, d);
        if (props != NULL)
          gst_structure_free (props);
      }
  g_list_free_full (devs, gst_object_unref);
  gst_object_unref (mon);
  return out;
}

#endif /* HAVE_CMACS_CAMERA */
