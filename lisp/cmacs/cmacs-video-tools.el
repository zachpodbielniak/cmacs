;;; cmacs-video-tools.el --- The video overlay as a registered capability  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `video_list' of cmacs/mcp/cmacs-mcp-tools-shell.c, moved onto the
;; capability table (doc_org/cmacs/cmacs-capability.org has the recipe).
;;
;; `video_snapshot' is NOT here and stays in C: its result is a PNG as
;; MCP image content, and a registry tool returns text.
;;
;; The result is what the C sent: `cmacs_dispatch_eval' printed the
;; printed list, so the handles reach the client as the `prin1' form of
;; a string.  A client may be parsing exactly that.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-video-list "cmacs-video-defuns.c" ())

(cmacs-brigade-deftool video-list
  "List all live cmacs-video stream handles."
    ()
  :group 'video
  :example "emacsctl tool video list"
  (prin1-to-string (prin1-to-string (cmacs-video-list))))

(provide 'cmacs-video-tools)

;;; cmacs-video-tools.el ends here
