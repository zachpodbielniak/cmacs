;;; cmacs-clawtilla-init.el --- One way in -*- lexical-binding: t; -*-

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

;; `M-x cmacs-clawtilla', and the transient that reaches everything
;; else.
;;
;; One command rather than nine, because a person coming to this does
;; not know whether the thing they want is a section, a panel or a
;; buffer -- and having to know is the difference between a client and
;; a set of functions.

;;; Code:

(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-page)
(require 'cmacs-clawtilla-alerts)
(require 'cmacs-clawtilla-fleet)
(require 'cmacs-clawtilla-agent)
(require 'cmacs-clawtilla-chat)
(require 'cmacs-clawtilla-files)
(require 'cmacs-clawtilla-computer)
(require 'cmacs-clawtilla-tasks)
(require 'cmacs-clawtilla-section)
(require 'cmacs-clawtilla-devices)
(require 'cmacs-clawtilla-pages)
(require 'cmacs-clawtilla-events)
(require 'cmacs-clawtilla-settings)
(require 'cmacs-clawtilla-teach)

;;;###autoload
(transient-define-prefix cmacs-clawtilla-menu ()
  "Everything the clawtilla client can open."
  ["Fleet"
   [("f" "the fleet" cmacs-clawtilla-fleet)
    ("!" "notifications" cmacs-clawtilla-alerts)]
   [("w" "work: tasks, decisions, flow, activity, fleet" cmacs-clawtilla-work)
    ("u" "automation: routines, triggers" cmacs-clawtilla-automation)
    ("l" "library: skills, memory" cmacs-clawtilla-library)]
   [("y" "recordings" cmacs-clawtilla-teach)
    ("," "settings" cmacs-clawtilla-settings)
    ("m" "more: projects, ledger, history, devices…"
     cmacs-clawtilla-more-menu)]]
  ["Connection"
   [("c" "connect" cmacs-clawtilla-connect)
    ("r" "resume the last daemon" cmacs-clawtilla-resume)
    ("d" "disconnect" cmacs-clawtilla-disconnect)]
   [("p" "pair this machine with a code" cmacs-clawtilla-pair)
    ("L" "give up on it, use the local daemon" cmacs-clawtilla-use-local)
    ("S" "start a daemon here" cmacs-clawtilla-start-daemon)]])

;;;###autoload
(defun cmacs-clawtilla ()
  "Open the clawtilla client, connecting first if need be.

With nothing connected this resumes the daemon this client was last on
-- the rule every clawtilla client starts by -- or, with
`cmacs-clawtilla-resume-last' nil, asks which to connect to."
  (interactive)
  (cond
   (cmacs-clawtilla-connections
    (cmacs-clawtilla-fleet (cmacs-clawtilla-current)))
   ((and cmacs-clawtilla-resume-last
         (fboundp 'cmacs-clawtilla--connection-choice))
    (let ((conn (cmacs-clawtilla-resume)))
      (when conn (cmacs-clawtilla-fleet conn))))
   (t (call-interactively #'cmacs-clawtilla-connect))))

(provide 'cmacs-clawtilla-init)

;;; cmacs-clawtilla-init.el ends here
