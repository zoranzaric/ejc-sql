;;; ejc-sql.el -- Uses clojure jdbc lib to eval sql scripts from emacs.

;;; Copyright © 2012, 2013 - Kostafey <kostafey@gmail.com>

;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2, or (at your option)
;;; any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program; if not, write to the Free Software Foundation,
;;; Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.  */

;;; Commentary:

;; The aim is to make access to SQL databases through emacs easy.

;;; Usage:

;; The configuration of ejs-sql might looks like this:
;;
;; ; Append ejs-sql to `load-path':
;; (defvar site-lisp-path "~/.emacs.d/")
;; (add-to-list 
;;  'load-path 
;;  (expand-file-name "ejc-sql/src/ejc_sql/" site-lisp-path))
;;
;; (require 'ejc-sql)
;;
;; ; Create your database connection configuration:
;; (setq my-db-connection (make-ejc-db-conn
;;                         :classpath (concat 
;;                                     "/home/user/lib/"
;;                                     "mysql-connector-java-3.1.13-bin.jar")
;;                         :classname "com.mysql.jdbc.Driver"
;;                         :subprotocol "mysql"
;;                         :subname "//localhost:3306/my_db_name"
;;                         :user "a_user"
;;                         :password "secret"))
;;
;; ; Some keybindings - modify this on your taste:
;; (global-set-key (kbd "C-x <up>") 'ejc-show-last-result)
;; (global-set-key (kbd "C-x C-s") 'ejc-switch-to-sql-editor-buffer)
;;
;; New keybindings added to `sql-mode-map':
;; * (kbd "C-c C-c") 'ejc-eval-user-sql-at-point
;; * (kbd "C-x t")   'ejc-toggle-popup-results-buffer
;; * (kbd "C-h t")   'ejc-describe-table
;;
;; * Using ejc-sql reqires nrepl process is running, so execution
;; `ejc-ensure-nrepl-runnig' ensures this.
;;
;; * Run to connect (ejc-connect "my-db-connection")
;; or M-x ejc-connect <RET> my-db-connection <RET>
;;
;; * `ejc-toggle-popup-results-buffer' -- Swithes between auto hidding results
;; buffer, or not.
;; 
;; * `ejc-eval-user-sql-at-point' -- Evaluate SQL bounded by the
;; `ejc-sql-separator' or/and buffer boundaries. 

(require 'cl)
(require 'sql)
(require 'nrepl)
(require 'popwin)
(require 'ejc-lib)
(require 'ejc-format)
(require 'ejc-interaction)
(require 'ejc-autocomplete)

(defvar ejc-sql-mode-keymap (make-keymap) "ejc-sql-mode keymap.")
(define-key ejc-sql-mode-keymap (kbd "C-c C-c") 'ejc-eval-user-sql-at-point)
(define-key ejc-sql-mode-keymap (kbd "C-x t") 'ejc-toggle-popup-results-buffer)
(define-key ejc-sql-mode-keymap (kbd "C-h t") 'ejc-describe-table)

(defvar ejc-sql-minor-mode-exit-hook nil
  "*Functions to be called when `ejc-sql-mode' is exited.")

(defvar ejc-sql-minor-mode-hook nil
  "*Functions to be called when `ejc-sql-mode' is entered.")

(defvar ejc-sql-mode nil)

;;;###autoload
(define-minor-mode ejc-sql-mode
  "Toggle ejc-sql mode."
  :lighter " ejc"
  :keymap ejc-sql-mode-keymap
  :group 'ejc
  :global nil
  ;; :after-hook (ejc-create-menu)
  (if ejc-sql-mode
      (progn
        (ejc-ac-setup)
        (ejc-create-menu)
        (run-hooks 'ejc-sql-minor-mode-hook))
    (progn 
      ;; (global-unset-key [menu-bar ejc-menu])     
      (run-hooks 'ejc-sql-minor-mode-exit-hook))))

;;;###autoload
(defun ejc-create-menu ()
  (define-key-after
    ejc-sql-mode-keymap
    [menu-bar ejc-menu]
    (cons "ejc-sql" (make-sparse-keymap "ejc-sql mode"))
    'tools )
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ev]
    '("Eval SQL" . ejc-eval-user-sql-at-point))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu tg]
    '("Toggle popup results" . ejc-toggle-popup-results-buffer))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu fs]
    '("Format SQL" . ejc-format-sql-at-point))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ms]
    '("Mark SQL" . ejc-mark-this-sql))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu tl]
    '("Tables list" . ejc-show-tables-list))
  (define-key
    ejc-sql-mode-keymap
    [menu-bar ejc-menu ms]
    '("Show tables list" . ejc-show-tables-list)))

(defun ejc-show-tables-list ()
  (interactive)
  (ejc-show-last-result (ejc-get-tables-list)))

(defvar ejc-results-buffer nil
  "The results buffer.")
(defvar ejc-results-buffer-name "*ejc-sql-output*"
  "The results buffer name.")

(defvar ejc-sql-editor-buffer-name "*ejc-sql-editor*"
  "The buffer for conveniently edit ad-hoc SQL scripts.")

(defvar ejc-sql-log-file-path nil
  "SQL scripts logs filepath.")
(defvar ejc-sql-log-buffer-name "sql_log.txt"
  "The buffer for view SQL scripts logs.")

(defvar clojure-src-file "connect.clj"
  "Main clojure src file name.")

(defvar ejc-popup-results-buffer t
  "Swithes between `popwin:popup-buffer' and `popwin:display-buffer'.")

(defun ejc-connect (arg)
  "Connect to selected db."  
  (interactive
   (list
    (read-from-minibuffer "DataBase connection name: "
                          (car ejc-connection-name-history) nil nil
                          'ejc-connection-name-history)))
  (let ((db (eval (intern arg))))
    (message "Connection started...")
    (if (ejc-ensure-nrepl-runnig)
        (progn
          (ejc-load-clojure-side)
          (ejc-connect-to-db db)
          (message "Connected.")))))

(defun ejc-get-word-at-point (pos)
  "Return SQL word around the point."
  (interactive "d")
  (let* ((char (char-after pos))
         (str (char-to-string char)))
    (save-excursion
      (let* ((end (if (member str '(" " ")" "<" ">" "="))
                      (point)
                    (progn
                      (forward-same-syntax 1)
                      (point))))
             (beg (progn
                    (forward-same-syntax -1)
                    (point)))
             (sql-word (buffer-substring beg end)))
        sql-word))))

(defun ejc-describe-table (table-name)
  "Describe SQL table `table-name' (default table name - word around the point)."
  (interactive
   (let ((sql-symbol (if mark-active
                         (buffer-substring (mark) (point))
                       (ejc-get-word-at-point (point))))
         (enable-recursive-minibuffers t)
         val)
     (setq val (completing-read
                (if sql-symbol
				    (format "Describe table (default %s): " sql-symbol)
				  "Describe table: ")
				obarray))
     (list (if (equal val "")
               sql-symbol
             val))))  
  (ejc-show-last-result 
   (ejc-get-nrepl-stdout 
    (concat "(get-table-meta " (ejc-add-quotes table-name) ")"))))

(defun ejc-eval-user-sql (sql)
  "Evaluate SQL by user: reload and show query results buffer, update log."
    (message "Processing SQL query...") 
    (ejc-show-last-result (ejc-eval-sql sql))
    (message "Done SQL query."))

(defun ejc-eval-user-sql-region (beg end)
  "Evaluate SQL bounded by the selection area."
  (interactive "r")
  (let ((sql (buffer-substring beg end)))
    (ejc-eval-user-sql sql)))

(defun ejc-eval-user-sql-at-point ()
  "Evaluate SQL bounded by the `ejc-sql-separator' or/and buffer boundaries."
  (interactive)  
  (ejc-eval-user-sql (ejc-get-sql-at-point)))

(defun ejc-show-tables-list (&optional owner)
  (interactive)
  (ejc-eval-user-sql (ejc--select-db-meta-script :tables owner)))

;;-----------------------------------------------------------------------------
;; results buffer
;;
(defun ejc-create-output-buffer ()
  (set-buffer (get-buffer-create ejc-results-buffer-name))
  (setq ejc-results-buffer (current-buffer))
  (setq view-read-only t)
  (rst-mode)
  ejc-results-buffer)

(defun ejc-get-buffer-or-create (buffer-or-name create-buffer-fn)
  "Return buffer passed in `buffer-or-name' parameter.
If this buffer is not exists or it was killed - create buffer via
`create-buffer-fn' function (this function must return buffer)."
  (let ((buf (if (bufferp buffer-or-name) 
                 buffer-or-name 
               (get-buffer buffer-or-name))))
    (if (and buf (buffer-live-p buf))
        buf
      (apply create-buffer-fn nil))))

(defun ejc-get-output-buffer ()
  (if (and ejc-results-buffer (buffer-live-p ejc-results-buffer))
      ejc-results-buffer
    (ejc-create-output-buffer)))

(defun ejc-toggle-popup-results-buffer ()
  (interactive)
  (setq ejc-popup-results-buffer (not ejc-popup-results-buffer))
  (if ejc-popup-results-buffer
      (message "Popup window.")
    (message "Normal window.")))

(defun ejc-show-last-result (&optional result)
  "Popup buffer with last SQL execution result output."
  (interactive)
  (let ((output-buffer (ejc-get-output-buffer)))
    (set-buffer output-buffer)
    (when result
      (toggle-read-only -1)
      (erase-buffer)
      (insert result))
    (toggle-read-only 1)
    (beginning-of-buffer)
    (if ejc-popup-results-buffer
        (popwin:popup-buffer output-buffer)
      (popwin:display-buffer output-buffer))))
;;
;;-----------------------------------------------------------------------------

;;-----------------------------------------------------------------------------
;; editor buffer
;;
(defun ejc-create-sql-editor-buffer ()
  "Create buffer dedicated to ad-hoc edit and SQL scripts."
  (let ((sql-editor-buffer (get-buffer-create ejc-sql-editor-buffer-name)))
    (save-excursion
      (set-buffer sql-editor-buffer)
      (sql-ansi-mode)
      (auto-complete-mode t)
      (auto-fill-mode t)
      (ejc-sql-mode)
      (ejc-sql-mode t))
    sql-editor-buffer))

(defun ejc-switch-to-sql-editor-buffer ()
  "Switch to buffer dedicated to ad-hoc edit and SQL scripts.
If the buffer is not exists - create it."
  (interactive)
  (switch-to-buffer
   (ejc-get-buffer-or-create
    ejc-sql-editor-buffer-name
    'ejc-create-sql-editor-buffer)))
;;
;;-----------------------------------------------------------------------------

;;-----------------------------------------------------------------------------
;; log buffer
;;
(defun ejc-create-sql-log-buffer ()
  (let ((sql-log-buffer (get-buffer-create ejc-sql-log-buffer-name)))
    (save-excursion
      (set-buffer sql-log-buffer)
      (set-visited-file-name ejc-sql-log-file-path t t)
      (setq view-read-only t)
      (sql-ansi-mode)
      (auto-complete-mode t)
      (auto-fill-mode t))
    sql-log-buffer))

(defun ejc-switch-to-sql-log-buffer ()
  (interactive)
  (switch-to-buffer
   (ejc-get-buffer-or-create
    ejc-sql-log-buffer-name
    'ejc-create-sql-log-buffer)))
;;
;;-----------------------------------------------------------------------------

;; (shell-command "lein repl :headless")

(provide 'ejc-sql)

