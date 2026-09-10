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
(require 'cmacs-clawtilla-alerts)
(require 'cmacs-clawtilla-fleet)
(require 'cmacs-clawtilla-agent)
(require 'cmacs-clawtilla-chat)
(require 'cmacs-clawtilla-computer)
(require 'cmacs-clawtilla-section)
(require 'cmacs-clawtilla-settings)
(require 'cmacs-clawtilla-teach)

;;;###autoload
(transient-define-prefix cmacs-clawtilla-menu ()
  "Everything the clawtilla client can open."
  ["Fleet"
   [("f" "the fleet" cmacs-clawtilla-fleet)
    ("!" "alerts" cmacs-clawtilla-alerts)]
   [("w" "work: tasks, decisions, flow" cmacs-clawtilla-work)
    ("u" "automation: routines, triggers" cmacs-clawtilla-automation)
    ("l" "library: skills, memory" cmacs-clawtilla-library)]
   [("y" "recordings" cmacs-clawtilla-teach)
    ("," "settings" cmacs-clawtilla-settings)]]
  ["Connection"
   [("c" "connect" cmacs-clawtilla-connect)
    ("d" "disconnect" cmacs-clawtilla-disconnect)]
   [("S" "start a daemon here" cmacs-clawtilla-start-daemon)]])

;;;###autoload
(defun cmacs-clawtilla ()
  "Open the clawtilla client, connecting first if need be."
  (interactive)
  (if (null cmacs-clawtilla-connections)
      (call-interactively #'cmacs-clawtilla-connect)
    (cmacs-clawtilla-fleet (cmacs-clawtilla-current))))

(provide 'cmacs-clawtilla-init)

;;; cmacs-clawtilla-init.el ends here
