/* cmacs-libregnum-lrgeditor.h --- host libregnum's lrgeditor shell in a view.
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * libregnum's editor application (`lrgeditor': menu bar, toolbar, docked
 * hierarchy / inspector / assets / console panels, scene viewport, play
 * session, IPC server) is an LrgEditorApp drawn on an LrgCanvas.  The
 * standalone program runs its own window loop; this host drives the same
 * object frame by frame instead -- input in, lrg_editor_app_process_frame(),
 * lrg_canvas_render() into the view's framebuffer -- so the whole editor
 * lives inside an Emacs window.
 *
 * TU split (same rule as the rest of cmacs/libregnum):
 *   - cmacs-libregnum-lrgeditor.c sees <libregnum.h> and never lisp.h;
 *   - cmacs-libregnum-lrgeditor-defuns.c sees lisp.h and never libregnum;
 *   - this header is plain C + GLib so both can include it.
 * The host is owned by the view's render context (render.c), which calls
 * _frame() and _draw() from its render_to_bgra path. */

#ifndef CMACS_LIBREGNUM_LRGEDITOR_H
#define CMACS_LIBREGNUM_LRGEDITOR_H

#include <glib.h>

G_BEGIN_DECLS

typedef struct CmacsLrgeditorHost CmacsLrgeditorHost;

/* Key phases for cmacs_lrgeditor_host_key(). */
#define CMACS_LRGEDITOR_KEY_PRESS   (0)
#define CMACS_LRGEDITOR_KEY_REPEAT  (1)
#define CMACS_LRGEDITOR_KEY_RELEASE (2)

/* Modifier bits, numerically identical to LrgInputModifiers. */
#define CMACS_LRGEDITOR_MOD_SHIFT (1u << 0)
#define CMACS_LRGEDITOR_MOD_CTRL  (1u << 1)
#define CMACS_LRGEDITOR_MOD_ALT   (1u << 2)
#define CMACS_LRGEDITOR_MOD_SUPER (1u << 3)

/* Mouse buttons, numerically identical to GrlMouseButton. */
#define CMACS_LRGEDITOR_BUTTON_LEFT   (0)
#define CMACS_LRGEDITOR_BUTTON_RIGHT  (1)
#define CMACS_LRGEDITOR_BUTTON_MIDDLE (2)

/* Lifetime.  _new needs a current GL context (the canvas loads fonts), so
 * it is called once the view's render context exists.  SETTINGS_PATH NULL
 * shares the standalone editor's $XDG_CONFIG_HOME/libregnum/editor.yaml. */
extern CmacsLrgeditorHost *cmacs_lrgeditor_host_new (const char *settings_path,
                                                     char **error_msg);
extern void cmacs_lrgeditor_host_free (CmacsLrgeditorHost *self);

/* The LrgEditor the shell edits (an LrgEditor *, typed as a pointer so
 * this header stays libregnum-free).  Borrowed. */
extern gpointer cmacs_lrgeditor_host_get_editor (CmacsLrgeditorHost *self);

/* Documents.  _open takes a project directory (or its project.ryaml), a
 * level or prefab, a sequence, or any file a data editor handles (.rsong,
 * .rmat, .rbt, ...), routed as the shell's assets panel routes a double
 * click; a file inside another project opens that project first.
 * _can_open answers whether a FILE has such an editor (no host needed:
 * the answer comes from the file's format). */
extern gboolean cmacs_lrgeditor_host_open (CmacsLrgeditorHost *self,
                                           const char *path,
                                           char **error_msg);
extern gboolean cmacs_lrgeditor_host_can_open (const char *path);
extern gboolean cmacs_lrgeditor_host_new_project (CmacsLrgeditorHost *self,
                                                  const char *dir,
                                                  const char *name,
                                                  char **error_msg);

/* IPC: start libregnum's LrgEditorServer on this editor, so lrgeditorctl,
 * its MCP verbs and libregnum.el drive the embedded shell.  SOCKET_PATH
 * NULL lets the editor settings / libregnum pick one. */
extern gboolean cmacs_lrgeditor_host_start_server (CmacsLrgeditorHost *self,
                                                   const char *socket_path,
                                                   char **error_msg);
extern const char *cmacs_lrgeditor_host_socket_path (CmacsLrgeditorHost *self);

/* Input, in view (framebuffer) pixels.  Everything accumulates into the
 * next frame's LrgCanvasInput, so a press and release faster than a frame
 * are both seen. */
extern void cmacs_lrgeditor_host_pointer (CmacsLrgeditorHost *self,
                                          double x, double y);
extern void cmacs_lrgeditor_host_button (CmacsLrgeditorHost *self,
                                         int button, gboolean press,
                                         double x, double y);
extern void cmacs_lrgeditor_host_wheel (CmacsLrgeditorHost *self,
                                        double dx, double dy);
extern void cmacs_lrgeditor_host_key (CmacsLrgeditorHost *self,
                                      int grl_key, int phase, guint mods);
extern void cmacs_lrgeditor_host_text (CmacsLrgeditorHost *self,
                                       const char *utf8);
extern void cmacs_lrgeditor_host_set_modifiers (CmacsLrgeditorHost *self,
                                                guint mods);
extern void cmacs_lrgeditor_host_release_all (CmacsLrgeditorHost *self);

/* Called by the render context: _frame outside any texture bracket (the
 * viewport renders into its own target during it), _draw inside the
 * view FBO's BeginTextureMode bracket. */
extern void cmacs_lrgeditor_host_frame (CmacsLrgeditorHost *self,
                                        int width, int height);
extern void cmacs_lrgeditor_host_draw (CmacsLrgeditorHost *self);

/* TRUE once since the last call if the edited level changed or was
 * replaced -- the render context then refreshes the node map the older
 * cmacs-libregnum-editor-* DEFUNs address nodes through. */
extern gboolean cmacs_lrgeditor_host_take_level_changed (CmacsLrgeditorHost *self);

/* State and actions. */
extern gboolean cmacs_lrgeditor_host_is_playing (CmacsLrgeditorHost *self);
extern gboolean cmacs_lrgeditor_host_should_quit (CmacsLrgeditorHost *self);
extern gint64 cmacs_lrgeditor_host_last_input_us (CmacsLrgeditorHost *self);
extern const char *cmacs_lrgeditor_host_status (CmacsLrgeditorHost *self);
extern gboolean cmacs_lrgeditor_host_activate_action (CmacsLrgeditorHost *self,
                                                      const char *id);
/* NULL-terminated, (transfer full) list of the editor's action ids. */
extern char **cmacs_lrgeditor_host_list_actions (CmacsLrgeditorHost *self);

G_END_DECLS

#endif /* CMACS_LIBREGNUM_LRGEDITOR_H */
