;;; cmacs-clawtilla-events.el --- What the daemon pushes, and what it moves -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Every buffer already listens for the events that are plainly its own:
;; a transcript for `message', the fleet for anything about an agent.
;; What is collected here are the pushed events that are easy to miss
;; because nothing is named after them -- a routine the daemon switched
;; off, an agent that fell back to another model, a download that moved
;; -- with, for each, the thing the GTK client redraws when it arrives.
;;
;; The table is the documentation: one row per kind, and what it moves.
;; A kind in the GTK client's handler and not in this table is an event
;; this client hears and does nothing about, which is how a page comes
;; to show yesterday's state while every other client shows today's.
;;
;; Nothing is patched from an event.  An event says what changed, not
;; what everything now is, so each of these asks again -- coalesced, so
;; a burst is one request.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-page)

(declare-function cmacs-clawtilla-section--reload-soon
                  "cmacs-clawtilla-section")
(declare-function cmacs-clawtilla-settings--load "cmacs-clawtilla-settings")
(declare-function cmacs-clawtilla-settings--draw "cmacs-clawtilla-settings")
(declare-function cmacs-clawtilla-agent--load "cmacs-clawtilla-agent")
(defvar cmacs-clawtilla-section--page)
(defvar cmacs-clawtilla-settings--panel)
(defvar cmacs-clawtilla-agent--id)

(defconst cmacs-clawtilla-events-table
  '(;; An agent's own facts changed -- its name, its avatar, its
    ;; settings: its page, and every page scoped to it.
    ("agent.changed"      :agent t)
    ;; A state change moves the Fleet page's Stop column as well as the
    ;; fleet buffer, which already listens.
    ("agent.state"        :sections ("fleet" "activity") :agent t)
    ;; The daemon stopped an agent for sitting idle: Fleet's idle badge.
    ("agent.idle_stopped" :sections ("fleet") :agent t :say idle-stopped)
    ;; An agent fell back to another model, or came back off one.
    ("agent.failover"     :sections ("fleet") :agent t :say failover)
    ;; The integration broker started, stopped or failed.
    ("broker.changed"     :pages ("broker") :settings ("connectors"))
    ;; A decision was asked or deleted: the inbox, and the transcript it
    ;; was asked in (which listens for itself).
    ("decision.asked"     :sections ("decisions") :pages ("skill-proposals"))
    ("decision.deleted"   :sections ("decisions") :pages ("skill-proposals"))
    ;; A device traded its code for a token.
    ("device.paired"      :pages ("devices"))
    ;; A cloud image's download moved, or ended.
    ("image.progress"     :progress t)
    ("image.finished"     :settings ("images") :progress done)
    ;; An agent remembered, forgot or pinned something.
    ("memory.changed"     :sections ("memory") :pages ("memory-review"))
    ;; The notification list moved: the bell (which listens for itself).
    ("notice.changed")
    ;; A routine failed to start too many times and was switched off.
    ("routine.turned_off" :sections ("routines") :say routine-off)
    ;; The sentinel finished a scan.
    ("sentinel.finished"  :pages ("issues"))
    ;; A replay of saved steps ended (its page says how).
    ("steps.replayed"     :pages ("steps"))
    ;; A task tree ran out of messages (the bell says so, in libclawt's
    ;; words); Tasks shows the trees that went quiet.
    ("task.tree_budget"   :sections ("tasks"))
    ;; A turn has said nothing for a while, or a message was folded into
    ;; a running one: both are the transcript's, which listens.
    ("turn.no_reply")
    ("turn.steered"       :sections ("activity")))
  "The pushed events with no buffer named after them, and what each moves.

Each entry is (KIND . PLIST).  `:sections' names section pages to
reload, `:pages' list pages, `:settings' settings panels; `:agent' the
agent buffer of the event's subject; `:say' a sentence worth showing
once; `:progress' the cloud-image download table.  A kind with no plist
is handled by the buffer it belongs to and is listed so the table is
the whole of what the daemon pushes that this client acts on.")

(defvar cmacs-clawtilla-image-progress (make-hash-table :test 'equal)
  "Cloud-image downloads in flight: image id to (DONE . TOTAL) bytes.

Filled from `image.progress', which carries no more than that, and
emptied by `image.finished'.  The Settings images panel draws it.")

(defun cmacs-clawtilla-image-progress-label (id)
  "Return how far the download of the cloud image ID has got, or nil."
  (pcase (gethash id cmacs-clawtilla-image-progress)
    (`(,done . ,total)
     (when (and (numberp total) (> total 0))
       (format "%s of %s (%d%%)"
               (file-size-human-readable done)
               (file-size-human-readable total)
               (floor (* 100.0 done) total))))))

(defun cmacs-clawtilla-events--say (what conn data)
  "Show the sentence WHAT for the event DATA on CONN, once."
  (let ((subject (cmacs-clawtilla-event-subject data)))
    (pcase what
      ('routine-off
       ;; The words are the library's: how many starts failed and why.
       (when-let* ((note (cmacs-clawtilla-ask
                          "routine-turned-off"
                          :failures (or (cmacs-clawtilla-event-detail
                                         data 'failures)
                                        0)
                          :error (cmacs-clawtilla-event-detail data 'error))))
         (message "clawtilla: routine %s: %s" (or subject "?") note)))
      ('idle-stopped
       (message "clawtilla: %s was stopped for sitting idle" (or subject "?")))
      ('failover
       ;; What it is running on now is on its row, worded by libclawt
       ;; from the listing; the event only says which way it went.
       (message "clawtilla: %s: %s%s"
                (or subject "?")
                (or (cmacs-clawtilla-event-detail data 'state) "model changed")
                (if (cmacs-clawtilla-event-detail data 'reason)
                    (format " (%s)" (cmacs-clawtilla-event-detail data 'reason))
                  ""))))
    (ignore conn)))

(defun cmacs-clawtilla-events--on-event (conn kind data)
  "Move whatever the pushed event KIND carrying DATA moves on CONN."
  (when-let* ((entry (assoc kind cmacs-clawtilla-events-table)))
    (let* ((plan (cdr entry))
           (sections (plist-get plan :sections))
           (pages (plist-get plan :pages))
           (panels (plist-get plan :settings))
           (subject (cmacs-clawtilla-event-subject data)))
      ;; The download table first: the panel that draws it is redrawn
      ;; below, from the table, without a request per chunk.
      (pcase (plist-get plan :progress)
        ('t (when subject
              (puthash subject
                       (cons (or (cmacs-clawtilla-event-detail data 'done) 0)
                             (or (cmacs-clawtilla-event-detail data 'total) 0))
                       cmacs-clawtilla-image-progress)))
        ('done (when subject
                 (remhash subject cmacs-clawtilla-image-progress))))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (eq cmacs-clawtilla-connection conn)
            (cond
             ((and sections
                   (derived-mode-p 'cmacs-clawtilla-section-mode)
                   (member cmacs-clawtilla-section--page sections))
              (cmacs-clawtilla-section--reload-soon buffer))
             ((and (derived-mode-p 'cmacs-clawtilla-settings-mode)
                   (equal cmacs-clawtilla-settings--panel "images")
                   (eq (plist-get plan :progress) t))
              ;; Redrawn from what it holds: a download publishes
              ;; progress many times a second.
              (cmacs-clawtilla-settings--draw))
             ((and panels
                   (derived-mode-p 'cmacs-clawtilla-settings-mode)
                   (member cmacs-clawtilla-settings--panel panels))
              (cmacs-clawtilla-settings--load buffer))
             ((and (plist-get plan :agent)
                   (derived-mode-p 'cmacs-clawtilla-agent-mode)
                   (equal cmacs-clawtilla-agent--id subject))
              (cmacs-clawtilla-agent--load buffer))))))
      (dolist (name pages)
        (dolist (buffer (cmacs-clawtilla-page-buffers name conn))
          (cmacs-clawtilla-page-reload-soon buffer)))
      (when-let* ((what (plist-get plan :say)))
        (cmacs-clawtilla-events--say what conn data)))))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-events--on-event)

(provide 'cmacs-clawtilla-events)

;;; cmacs-clawtilla-events.el ends here
