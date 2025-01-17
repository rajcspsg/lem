(defpackage :lem-lsp-mode/lsp-mode
  (:nicknames :lem-lsp-mode)
  (:use :cl
        :lem
        :alexandria
        :lem-lsp-base/type
        :lem-lsp-base/converter
        :lem-lsp-base/yason-utils
        :lem-lsp-base/utils)
  (:shadow :execute-command)
  (:import-from :lem-language-client/request)
  (:import-from :lem-lsp-mode/client)
  (:import-from :lem-lsp-mode/context-menu)
  (:local-nicknames (:request :lem-language-client/request))
  (:local-nicknames (:completion :lem.completion-mode))
  (:local-nicknames (:context-menu :lem-lsp-mode/context-menu))
  (:local-nicknames (:spinner :lem.loading-spinner))
  (:export :spec-initialization-options
           :define-language-spec))
(in-package :lem-lsp-mode/lsp-mode)

;;;
(defparameter *client-capabilities-text*
  (load-time-value
   (uiop:read-file-string
    (asdf:system-relative-pathname :lem-lsp-mode
                                   "client-capabilities.json"))))

(defun client-capabilities ()
  (convert-from-json
   (parse-json *client-capabilities-text*)
   'lsp:client-capabilities))

;;;
(defvar *language-id-server-info-map* (make-hash-table :test 'equal))

(defstruct server-info
  port
  process
  disposable)

(defun server-process-buffer-name (spec)
  (format nil "*Lsp <~A>*" (spec-language-id spec)))

(defun make-server-process-buffer (spec)
  (make-buffer (server-process-buffer-name spec)))

(defun get-spec-command (spec &rest args)
  (let ((command (spec-command spec)))
    (if (functionp command)
        (apply command args)
        command)))

(define-condition not-found-program (editor-error)
  ((name :initarg :name
         :initform (required-argument :name)
         :reader not-found-program-name)
   (spec :initarg :spec
         :initform (required-argument :spec)
         :reader not-found-program-spec))
  (:report (lambda (c s)
             (with-slots (name spec) c
               (format s (gen-install-help-message name spec))))))

(defun gen-install-help-message (program spec)
  (with-output-to-string (out)
    (format out "\"~A\" is not installed." program)
    (when (spec-install-command spec)
      (format out
              "~&You can install it with the following command.~2% $ ~A"
              (spec-install-command spec)))
    (when (spec-readme-url spec)
      (format out "~&~%See follow for the readme URL~2% ~A ~%" (spec-readme-url spec)))))

(defun exist-program-p (program)
  (let ((status
          (nth-value 2
                     (uiop:run-program (list "which" program)
                                       :ignore-error-status t))))
    (= status 0)))

(defun check-exist-program (program spec)
  (unless (exist-program-p program)
    (error 'not-found-program :name program :spec spec)))

(defmethod run-server-using-mode ((mode (eql :tcp)) spec)
  (flet ((output-callback (string)
           (let* ((buffer (make-server-process-buffer spec))
                  (point (buffer-point buffer)))
             (buffer-end point)
             (insert-string point string))))
    (let* ((port (or (spec-port spec) (lem-socket-utils:random-available-port)))
           (process (when-let (command (get-spec-command spec port))
                      (check-exist-program (first command) spec)
                      (lem-process:run-process command :output-callback #'output-callback))))
      (make-server-info :process process
                        :port port
                        :disposable (lambda ()
                                      (when process
                                        (lem-process:delete-process process)))))))

(defmethod run-server-using-mode ((mode (eql :stdio)) spec)
  (let ((command (get-spec-command spec)))
    (check-exist-program (first command) spec)
    (let ((process (async-process:create-process command :nonblock nil)))
      (make-server-info :process process
                        :disposable (lambda () (async-process:delete-process process))))))

(defmethod run-server (spec)
  (run-server-using-mode (spec-mode spec) spec))

(defun get-running-server-info (spec)
  (gethash (spec-language-id spec) *language-id-server-info-map*))

(defun remove-server-info (spec)
  (remhash (spec-language-id spec) *language-id-server-info-map*))

(defun ensure-running-server-process (spec)
  (unless (get-running-server-info spec)
    (setf (gethash (spec-language-id spec) *language-id-server-info-map*)
          (run-server spec))
    t))

(defun kill-server-process (spec)
  (when-let* ((server-info (get-running-server-info spec))
              (disposable (server-info-disposable server-info)))
    (funcall disposable)
    (remove-server-info spec)))

(defun quit-all-server-process ()
  (maphash (lambda (language-id server-info)
             (declare (ignore language-id))
             (when-let ((disposable (server-info-disposable server-info)))
               (funcall disposable)))
           *language-id-server-info-map*)
  (clrhash *language-id-server-info-map*))

;;;
(defmacro with-jsonrpc-error (() &body body)
  (with-unique-names (c)
    `(handler-case (progn ,@body)
       (jsonrpc/errors:jsonrpc-callback-error (,c)
         (editor-error "~A" ,c)))))

(defun jsonrpc-editor-error (message code)
  (editor-error "JSONRPC-CALLBACK-ERROR: ~A (Code=~A)" message code))

(defun async-request (client request params &key then)
  (request:request-async client
                         request
                         params
                         (lambda (response)
                           (send-event (lambda () (funcall then response))))
                         (lambda (message code)
                           (send-event (lambda () (jsonrpc-editor-error message code))))))

(defun display-message (text &key (gravity :cursor) source-window)
  (when text
    (show-message text
                  :style `(:gravity ,gravity
                           :use-border t
                           :background-color "#404040")
                  :timeout nil
                  :source-window source-window)))

;;;
(defun buffer-language-mode (buffer)
  (or (lem.language-mode:language-mode-tag buffer)
      (buffer-major-mode buffer)))

;;;
(defgeneric spec-initialization-options (spec)
  (:method (spec) nil))

(defclass spec ()
  ((language-id
    :initarg :language-id
    :initform (required-argument :language-id)
    :reader spec-language-id)
   (root-uri-patterns
    :initarg :root-uri-patterns
    :initform nil
    :reader spec-root-uri-patterns)
   (command
    :initarg :command
    :initform nil
    :reader spec-command)
   (install-command
    :initarg :install-command
    :initform nil
    :reader spec-install-command)
   (readme-url
    :initarg :readme-url
    :initform nil
    :reader spec-readme-url)
   (mode
    :initarg :mode
    :initform (required-argument :mode)
    :reader spec-mode)
   (port
    :initarg :port
    :initform nil
    :reader spec-port)))

(defun get-language-spec (major-mode)
  (make-instance (get major-mode 'spec)))

(defun register-language-spec (major-mode spec-name)
  (setf (get major-mode 'spec) spec-name))

;;;
(defvar *workspaces* '())

(defstruct workspace
  root-uri
  client
  spec
  server-capabilities
  server-info
  (trigger-characters (make-hash-table))
  plist)

(defun workspace-value (workspace key)
  (getf (workspace-plist workspace) key))

(defun (setf workspace-value) (value workspace key)
  (setf (getf (workspace-plist workspace) key) value))

(defun workspace-language-id (workspace)
  (spec-language-id (workspace-spec workspace)))

(defun find-workspace (language-id &key (errorp t))
  (dolist (workspace *workspaces*
                     (when errorp
                       (editor-error "The ~A workspace is not found." language-id)))
    (when (equal (workspace-language-id workspace)
                 language-id)
      (return workspace))))

(defun buffer-workspace (buffer)
  (buffer-value buffer 'workspace))

(defun (setf buffer-workspace) (workspace buffer)
  (setf (buffer-value buffer 'workspace) workspace))

(defun buffer-language-spec (buffer)
  (get-language-spec (buffer-language-mode buffer)))

(defun buffer-language-id (buffer)
  (let ((spec (buffer-language-spec buffer)))
    (when spec
      (spec-language-id spec))))

(defun buffer-version (buffer)
  (buffer-modified-tick buffer))

(defun random-string (length)
  (with-output-to-string (out)
              (loop :repeat length
                    :do (loop :for code := (random 128)
                              :for char := (code-char code)
                              :until (alphanumericp char)
                              :finally (write-char char out)))))

(defun temporary-buffer-uri (buffer)
  (or (buffer-value buffer 'uri)
      (setf (buffer-value buffer 'uri)
            (format nil "/tmp/~A" (random-string 32)))))

(defun buffer-uri (buffer)
  ;; TODO: lem-language-server::buffer-uri
  (if (buffer-filename buffer)
      (pathname-to-uri (buffer-filename buffer))
      ;; ファイルに関連付けられていないバッファ(*tmp*やRPEL)は一時ファイルという扱いにしている
      (temporary-buffer-uri buffer)))

(defun get-workspace-from-point (point)
  (buffer-workspace (point-buffer point)))

(defvar *lsp-mode-keymap* (make-keymap))

(define-key *lsp-mode-keymap* "C-c h" 'lsp-hover)

(define-minor-mode lsp-mode
    (:name "lsp"
     :keymap *lsp-mode-keymap*
     :enable-hook 'enable-hook)
  (setf (variable-value 'lem.language-mode:completion-spec)
        (lem.completion-mode:make-completion-spec 'text-document/completion :async t))
  (setf (variable-value 'lem.language-mode:find-definitions-function)
        #'find-definitions)
  (setf (variable-value 'lem.language-mode:find-references-function)
        #'find-references)
  (setf (buffer-value (current-buffer) 'revert-buffer-function)
        #'lsp-revert-buffer))

(defun enable-hook ()
  (let ((buffer (current-buffer)))
    (unless (buffer-temporary-p buffer)
      (handler-case
          (progn
            (add-hook *exit-editor-hook* 'quit-all-server-process)
            (ensure-lsp-buffer buffer
                               (lambda ()
                                 (text-document/did-open buffer)
                                 (enable-document-highlight-idle-timer)
                                 (redraw-display))))
        (editor-error (c)
          (show-message (princ-to-string c)))))))

(defun reopen-buffer (buffer)
  (text-document/did-close buffer)
  (text-document/did-open buffer))

(define-command lsp-sync-buffer () ()
  (reopen-buffer (current-buffer)))

(defun lsp-revert-buffer (buffer)
  (remove-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)
  (unwind-protect (progn
                    (lem::revert-buffer-internal buffer)
                    (reopen-buffer buffer))
    (add-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)))

(defun find-root-pathname (directory uri-patterns)
  (labels ((root-file-p (file)
             (let ((file-name (file-namestring file)))
               (dolist (uri-pattern uri-patterns)
                 (when (search uri-pattern file-name)
                   (return t)))))
           (recursive (directory)
             (cond ((dolist (file (uiop:directory-files directory))
                      (when (root-file-p file)
                        (return directory))))
                   ((uiop:pathname-equal directory (user-homedir-pathname)) nil)
                   ((recursive (uiop:pathname-parent-directory-pathname directory))))))
    (or (recursive directory)
        (pathname directory))))

(defun get-connected-port (spec)
  (let ((server-info (get-running-server-info spec)))
    (assert server-info)
    (server-info-port server-info)))

(defun get-spec-process (spec)
  (let ((server-info (get-running-server-info spec)))
    (assert server-info)
    (server-info-process server-info)))

(defun make-client (spec)
  (ecase (spec-mode spec)
    (:tcp (make-instance 'lem-lsp-mode/client:tcp-client :port (get-connected-port spec)))
    (:stdio (make-instance 'lem-lsp-mode/client:stdio-client :process (get-spec-process spec)))))

(defun make-client-and-connect (spec)
  (let ((client (make-client spec)))
    (lem-language-client/client:jsonrpc-connect client)
    client))

(defun convert-to-characters (string-characters)
  (map 'list
       (lambda (string) (char string 0))
       string-characters))

(defun get-completion-trigger-characters (workspace)
  (convert-to-characters
   (handler-case
       (lsp:completion-options-trigger-characters
        (lsp:server-capabilities-completion-provider
         (workspace-server-capabilities workspace)))
     (unbound-slot ()
       nil))))

(defun get-signature-help-trigger-characters (workspace)
  (convert-to-characters
   (handler-case
       (lsp:signature-help-options-trigger-characters
        (lsp:server-capabilities-signature-help-provider
         (workspace-server-capabilities workspace)))
     (unbound-slot ()
       nil))))

(defun self-insert-hook (c)
  (when-let* ((workspace (buffer-workspace (current-buffer)))
              (command (gethash c (workspace-trigger-characters workspace))))
    (funcall command c)))

(defun buffer-change-event-to-content-change-event (point arg)
  (labels ((inserting-content-change-event (string)
             (let ((position (point-to-lsp-position point)))
               (make-lsp-map :range (make-instance 'lsp:range
                                                   :start position
                                                   :end position)
                             :range-length 0
                             :text string)))
           (deleting-content-change-event (count)
             (with-point ((end point))
               (character-offset end count)
               (make-lsp-map :range (points-to-lsp-range
                                     point
                                     end)
                             :range-length (count-characters point end)
                             :text ""))))
    (etypecase arg
      (character
       (inserting-content-change-event (string arg)))
      (string
       (inserting-content-change-event arg))
      (integer
       (deleting-content-change-event arg)))))

(defun handle-change-buffer (point arg)
  (let ((buffer (point-buffer point))
        (change-event (buffer-change-event-to-content-change-event point arg)))
    (text-document/did-change buffer (make-lsp-array change-event))))

(defun assign-workspace-to-buffer (buffer workspace)
  (setf (buffer-workspace buffer) workspace)
  (add-hook (variable-value 'kill-buffer-hook :buffer buffer) 'text-document/did-close)
  (add-hook (variable-value 'after-save-hook :buffer buffer) 'text-document/did-save)
  (add-hook (variable-value 'before-change-functions :buffer buffer) 'handle-change-buffer)
  (add-hook (variable-value 'self-insert-after-hook :buffer buffer) 'self-insert-hook)
  (dolist (character (get-completion-trigger-characters workspace))
    (setf (gethash character (workspace-trigger-characters workspace))
          #'completion-with-trigger-character))
  (dolist (character (get-signature-help-trigger-characters workspace))
    (setf (gethash character (workspace-trigger-characters workspace))
          #'lsp-signature-help-with-trigger-character)))

(defun register-lsp-method (workspace method function)
  (jsonrpc:expose (lem-language-client/client:client-connection (workspace-client workspace))
                  method
                  function))

(defun initialize-workspace (workspace continuation)
  (register-lsp-method workspace
                       "textDocument/publishDiagnostics"
                       'text-document/publish-diagnostics)
  (register-lsp-method workspace
                       "window/showMessage"
                       'window/show-message)
  (register-lsp-method workspace
                       "window/logMessage"
                       'window/log-message)
  (initialize workspace
              (lambda ()
                (initialized workspace)
                (push workspace *workspaces*)
                (funcall continuation workspace))))

(defun establish-connection (spec)
  (when (ensure-running-server-process spec)
    (let ((client (make-client spec)))
      (loop :with condition := nil
            :repeat 20
            :do (handler-case (with-yason-bindings ()
                                (lem-language-client/client:jsonrpc-connect client))
                  (:no-error (&rest values)
                    (declare (ignore values))
                    (return client))
                  (error (c)
                    (setq condition c)
                    (sleep 0.5)))
            :finally (editor-error
                      "Could not establish a connection with the Language Server (condition: ~A)"
                      condition)))))

(defgeneric initialized-workspace (mode workspace)
  (:method (mode workspace)))

(defun ensure-lsp-buffer (buffer &optional continuation)
  (let* ((spec (buffer-language-spec buffer))
         (root-uri (pathname-to-uri
                    (find-root-pathname (buffer-directory buffer)
                                        (spec-root-uri-patterns spec)))))
    (handler-bind ((error (lambda (c)
                            (log:info c (princ-to-string c))
                            (kill-server-process spec))))
      (let ((new-client (establish-connection spec)))
        (cond ((null new-client)
               (let ((workspace (find-workspace (spec-language-id spec) :errorp t)))
                 (assign-workspace-to-buffer buffer workspace)
                 (when continuation (funcall continuation))))
              (t
               (let ((spinner (spinner:start-loading-spinner
                               :modeline
                               :loading-message "initializing"
                               :buffer buffer)))
                 (initialize-workspace
                  (make-workspace :client new-client
                                  :root-uri root-uri
                                  :spec spec)
                  (lambda (workspace)
                    (assign-workspace-to-buffer buffer workspace)
                    (when continuation (funcall continuation))
                    (spinner:stop-loading-spinner spinner)
                    (let ((mode (lem::ensure-mode-object (buffer-language-mode buffer))))
                      (initialized-workspace mode workspace))
                    (redraw-display))))))))))

(defun check-connection ()
  (let* ((buffer (current-buffer))
         (spec (buffer-language-spec buffer)))
    (unless (get-running-server-info spec)
      (ensure-lsp-buffer buffer))))

(defun buffer-to-text-document-item (buffer)
  (make-instance 'lsp:text-document-item
                 :uri (buffer-uri buffer)
                 :language-id (buffer-language-id buffer)
                 :version (buffer-version buffer)
                 :text (buffer-text buffer)))

(defun make-text-document-identifier (buffer)
  (make-instance 'lsp:text-document-identifier
                 :uri (buffer-uri buffer)))

(defun make-text-document-position-arguments (point)
  (list :text-document (make-text-document-identifier (point-buffer point))
        :position (point-to-lsp-position point)))

(defun make-text-document-position-params (point)
  (apply #'make-instance
         'lsp:text-document-position-params
         (make-text-document-position-arguments point)))

(defun find-buffer-from-uri (uri)
  (let ((pathname (uri-to-pathname uri)))
    (find-file-buffer pathname)))

(defun get-buffer-from-text-document-identifier (text-document-identifier)
  (let ((uri (lsp:text-document-identifier-uri text-document-identifier)))
    (find-buffer-from-uri uri)))

(defun apply-text-edits (buffer text-edits)
  (flet ((replace-points ()
           (let ((points '()))
             (with-point ((start (buffer-point buffer) :left-inserting)
                          (end (buffer-point buffer) :left-inserting))
               (do-sequence (text-edit text-edits)
                 (let ((range (lsp:text-edit-range text-edit))
                       (new-text (lsp:text-edit-new-text text-edit)))
                   (move-to-lsp-position start (lsp:range-start range))
                   (move-to-lsp-position end (lsp:range-end range))
                   (push (list (copy-point start)
                               (copy-point end)
                               new-text)
                         points))))
             (nreverse points))))
    (let ((points (replace-points)))
      (unwind-protect
           (loop :for (start end text) :in points
                 :do (delete-between-points start end)
                     (insert-string start text))
        (loop :for (start end) :in points
              :do (delete-point start)
                  (delete-point end))))))

(defgeneric apply-document-change (document-change))

(defmethod apply-document-change ((document-change lsp:text-document-edit))
  (let* ((buffer
           (get-buffer-from-text-document-identifier
            (lsp:text-document-edit-text-document document-change))))
    (apply-text-edits buffer (lsp:text-document-edit-edits document-change))))

(defmethod apply-document-change ((document-change lsp:create-file))
  (error "createFile is not yet supported"))

(defmethod apply-document-change ((document-change lsp:rename-file))
  (error "renameFile is not yet supported"))

(defmethod apply-document-change ((document-change lsp:delete-file))
  (error "deleteFile is not yet supported"))

(defun apply-workspace-edit (workspace-edit)
  (labels ((apply-document-changes (document-changes)
             (do-sequence (document-change document-changes)
               (apply-document-change document-change)))
           (apply-changes (changes)
             (declare (ignore changes))
             (error "Not yet implemented")))
    (if-let ((document-changes (handler-case
                                   (lsp:workspace-edit-document-changes workspace-edit)
                                 (unbound-slot () nil))))
      (apply-document-changes document-changes)
      (when-let ((changes (handler-case (lsp:workspace-edit-changes workspace-edit)
                            (unbound-slot () nil))))
        (apply-changes changes)))))

;;; General Messages

(defun initialize (workspace continuation)
  (async-request
   (workspace-client workspace)
   (make-instance 'lsp:initialize)
   (apply #'make-instance
          'lsp:initialize-params
          :process-id (get-pid)
          :client-info (make-lsp-map :name "lem" #|:version "0.0.0"|#)
          :root-uri (workspace-root-uri workspace)
          :capabilities (client-capabilities)
          :trace "off"
          :workspace-folders +null+
          (when-let ((value (spec-initialization-options (workspace-spec workspace))))
            (list :initialization-options value)))
   :then (lambda (initialize-result)
           (setf (workspace-server-capabilities workspace)
                 (lsp:initialize-result-capabilities initialize-result))
           (handler-case (lsp:initialize-result-server-info initialize-result)
             (unbound-slot () nil)
             (:no-error (server-info)
               (setf (workspace-server-info workspace)
                     server-info)))
           (funcall continuation))))

(defun initialized (workspace)
  (request:request (workspace-client workspace)
                   (make-instance 'lsp:initialized)
                   (make-instance 'lsp:initialized-params)))

;;; Window

;; TODO
;; - window/showMessageRequest
;; - window/workDoneProgress/create
;; - window/workDoenProgress/cancel

(defun window/show-message (params)
  (request::do-request-log "window/showMessage" params :from :server)
  (let* ((params (convert-from-json params 'lsp:show-message-params))
         (text (format nil "~A: ~A"
                       (switch ((lsp:show-message-params-type params) :test #'=)
                         (lsp:message-type-error
                          "Error")
                         (lsp:message-type-warning
                          "Warning")
                         (lsp:message-type-info
                          "Info")
                         (lsp:message-type-log
                          "Log"))
                       (lsp:show-message-params-message params))))
    (send-event (lambda ()
                  (display-popup-message text
                                         :style '(:gravity :top)
                                         :timeout 3)))))

(defun log-message (text)
  (let ((buffer (make-buffer "*lsp output*")))
    (with-point ((point (buffer-point buffer) :left-inserting))
      (buffer-end point)
      (unless (start-line-p point)
        (insert-character point #\newline))
      (insert-string point text))
    (when (get-buffer-windows buffer)
      (redraw-display))))

(defun window/log-message (params)
  (request::do-request-log "window/logMessage" params :from :server)
  (let* ((params (convert-from-json params 'lsp:log-message-params))
         (text (lsp:log-message-params-message params)))
    (send-event (lambda ()
                  (log-message text)))))

;;; Text Synchronization

(defun text-document/did-open (buffer)
  (request:request
   (workspace-client (buffer-workspace buffer))
   (make-instance 'lsp:text-document/did-open)
   (make-instance 'lsp:did-open-text-document-params
                  :text-document (buffer-to-text-document-item buffer))))

(defun text-document/did-change (buffer content-changes)
  (request:request
   (workspace-client (buffer-workspace buffer))
   (make-instance
    'lsp:text-document/did-change)
   (make-instance 'lsp:did-change-text-document-params
                  :text-document (make-instance 'lsp:versioned-text-document-identifier
                                                :version (buffer-version buffer)
                                                :uri (buffer-uri buffer))
                  :content-changes content-changes)))

(defun provide-did-save-text-document-p (workspace)
  (let ((sync (lsp:server-capabilities-text-document-sync
               (workspace-server-capabilities workspace))))
    (etypecase sync
      (number
       (member sync
               (list lsp:text-document-sync-kind-full
                     lsp:text-document-sync-kind-incremental)))
      (lsp:text-document-sync-options
       (handler-case (lsp:text-document-sync-options-save sync)
         (unbound-slot ()
           nil))))))

(defun text-document/did-save (buffer)
  (when (provide-did-save-text-document-p (buffer-workspace buffer))
    (request:request
     (workspace-client (buffer-workspace buffer))
     (make-instance 'lsp:text-document/did-save)
     (make-instance 'lsp:did-save-text-document-params
                    :text-document (make-text-document-identifier buffer)
                    :text (buffer-text buffer)))))

(defun text-document/did-close (buffer)
  (request:request
   (workspace-client (buffer-workspace buffer))
   (make-instance 'lsp:text-document/did-close)
   (make-instance 'lsp:did-close-text-document-params
                  :text-document (make-text-document-identifier buffer))))

;;; publishDiagnostics

;; TODO
;; - tagSupport
;; - versionSupport

(define-attribute diagnostic-error-attribute
  (t :foreground "red" :underline-p t))

(define-attribute diagnostic-warning-attribute
  (t :foreground "orange" :underline-p t))

(define-attribute diagnostic-information-attribute
  (t :foreground "gray" :underline-p t))

(define-attribute diagnostic-hint-attribute
  (t :foreground "yellow" :underline-p t))

(defun diagnostic-severity-attribute (diagnostic-severity)
  (switch (diagnostic-severity :test #'=)
    (lsp:diagnostic-severity-error
     'diagnostic-error-attribute)
    (lsp:diagnostic-severity-warning
     'diagnostic-warning-attribute)
    (lsp:diagnostic-severity-information
     'diagnostic-information-attribute)
    (lsp:diagnostic-severity-hint
     'diagnostic-hint-attribute)))

(defstruct diagnostic
  buffer
  position
  message)

(defun buffer-diagnostic-overlays (buffer)
  (buffer-value buffer 'diagnostic-overlays))

(defun (setf buffer-diagnostic-overlays) (overlays buffer)
  (setf (buffer-value buffer 'diagnostic-overlays) overlays))

(defun clear-diagnostic-overlays (buffer)
  (mapc #'delete-overlay (buffer-diagnostic-overlays buffer))
  (setf (buffer-diagnostic-overlays buffer) '()))

(defun buffer-diagnostic-idle-timer (buffer)
  (buffer-value buffer 'diagnostic-idle-timer))

(defun (setf buffer-diagnostic-idle-timer) (idle-timer buffer)
  (setf (buffer-value buffer 'diagnostic-idle-timer) idle-timer))

(defun overlay-diagnostic (overlay)
  (overlay-get overlay 'diagnostic))

(defun buffer-diagnostics (buffer)
  (mapcar #'overlay-diagnostic (buffer-diagnostic-overlays buffer)))

(defun reset-buffer-diagnostic (buffer)
  (clear-diagnostic-overlays buffer)
  (when-let (timer (buffer-diagnostic-idle-timer buffer))
    (stop-timer timer)
    (setf (buffer-diagnostic-idle-timer buffer) nil)))

(defun point-to-xref-position (point)
  (lem.language-mode::make-xref-position :line-number (line-number-at-point point)
                                         :charpos (point-charpos point)))

(defun highlight-diagnostic (buffer diagnostic)
  (with-point ((start (buffer-point buffer))
               (end (buffer-point buffer)))
    (let ((range (lsp:diagnostic-range diagnostic)))
      (move-to-lsp-position start (lsp:range-start range))
      (move-to-lsp-position end (lsp:range-end range))
      (when (point= start end)
        ;; XXX: gopls用
        ;; func main() {
        ;;     fmt.
        ;; というコードでrange.start, range.endが行末を
        ;; 差していてハイライトされないので一文字ずらしておく
        (if (end-line-p end)
            (character-offset start -1)
            (character-offset end 1)))
      (let ((overlay (make-overlay start end
                                   (handler-case (lsp:diagnostic-severity diagnostic)
                                     (unbound-slot ()
                                       'diagnostic-error-attribute)
                                     (:no-error (severity)
                                       (diagnostic-severity-attribute severity))))))
        (overlay-put overlay
                     'diagnostic
                     (make-diagnostic :buffer buffer
                                      :position (point-to-xref-position start)
                                      :message (lsp:diagnostic-message diagnostic)))
        (push overlay (buffer-diagnostic-overlays buffer))))))

(defun highlight-diagnostics (params)
  (when-let ((buffer (find-buffer-from-uri (lsp:publish-diagnostics-params-uri params))))
    (reset-buffer-diagnostic buffer)
    (do-sequence (diagnostic (lsp:publish-diagnostics-params-diagnostics params))
      (highlight-diagnostic buffer diagnostic))
    (setf (buffer-diagnostic-idle-timer buffer)
          (start-idle-timer 200 t #'popup-diagnostic nil "lsp-diagnostic"))))

(defun popup-diagnostic ()
  (dolist (overlay (buffer-diagnostic-overlays (current-buffer)))
    (when (point<= (overlay-start overlay)
                   (current-point)
                   (overlay-end overlay))
      (display-message (diagnostic-message (overlay-diagnostic overlay)))
      (return))))

(defun text-document/publish-diagnostics (params)
  (request::do-request-log "textDocument/publishDiagnostics" params :from :server)
  (let ((params (convert-from-json params 'lsp:publish-diagnostics-params)))
    (send-event (lambda () (highlight-diagnostics params)))))

(define-command lsp-document-diagnostics () ()
  (when-let ((diagnostics (buffer-diagnostics (current-buffer))))
    (lem.sourcelist:with-sourcelist (sourcelist "*Diagnostics*")
      (dolist (diagnostic diagnostics)
        (lem.sourcelist:append-sourcelist
         sourcelist
         (lambda (point)
           (insert-string point (buffer-filename (diagnostic-buffer diagnostic))
                          :attribute 'lem.sourcelist:title-attribute)
           (insert-string point ":")
           (insert-string point
                          (princ-to-string (lem.language-mode::xref-position-line-number
                                            (diagnostic-position diagnostic)))
                          :attribute 'lem.sourcelist:position-attribute)
           (insert-string point ":")
           (insert-string point
                          (princ-to-string (lem.language-mode::xref-position-charpos
                                            (diagnostic-position diagnostic)))
                          :attribute 'lem.sourcelist:position-attribute)
           (insert-string point ":")
           (insert-string point (diagnostic-message diagnostic)))
         (let ((diagnostic diagnostic))
           (lambda (set-buffer-fn)
             (funcall set-buffer-fn (diagnostic-buffer diagnostic))
             (lem.language-mode:move-to-xref-location-position
              (buffer-point (diagnostic-buffer diagnostic))
              (diagnostic-position diagnostic)))))))))

;;; hover

;; TODO
;; - workDoneProgress
;; - partialResult
;; - hoverClientCapabilitiesのcontentFormatを設定する
;; - hoverのrangeを使って範囲に背景色をつける
;; - serverでサポートしているかのチェックをする

(defun trim-final-newlines (point)
  (with-point ((start point :left-inserting)
               (end point :left-inserting))
    (buffer-end start)
    (buffer-end end)
    (skip-whitespace-backward start)
    (delete-between-points start end)))

(defun markdown-buffer (markdown-text)
  (labels ((make-markdown-buffer (markdown-text)
             (let* ((buffer (make-buffer nil
                                         :temporary t
                                         :enable-undo-p nil))
                    (point (buffer-point buffer)))
               (setf (variable-value 'lem:line-wrap :buffer buffer) nil)
               (setf (variable-value 'enable-syntax-highlight :buffer buffer) t)
               (erase-buffer buffer)
               (insert-string point markdown-text)
               (put-foreground buffer)
               buffer))
           (get-syntax-table-from-mode (mode-name)
             (when-let* ((mode (lem::find-mode mode-name))
                         (syntax-table (mode-syntax-table mode)))
               syntax-table))

           (put-foreground (buffer)
             (put-text-property (buffer-start-point buffer)
                                (buffer-end-point buffer)
                                :attribute (make-attribute :foreground "#F0F0F0")))

           (delete-line (point)
             (with-point ((start point)
                          (end point))
               (line-start start)
               (line-end end)
               (delete-between-points start end)))
           (process-header (point)
             (buffer-start point)
             (loop :while (search-forward-regexp point "^#+\\s*")
                   :do (with-point ((start point))
                         (line-start start)
                         (delete-between-points start point)
                         (line-end point)
                         (put-text-property start
                                            point
                                            :attribute (make-attribute :bold-p t)))))
           (process-code-block (point)
             (buffer-start point)
             (loop :while (search-forward-regexp point "^```")
                   :do (with-point ((start point :right-inserting)
                                    (end point :right-inserting))
                         (let* ((mode-name (looking-at start "[\\w-]+"))
                                (syntax-table (get-syntax-table-from-mode mode-name)))
                           (line-start start)
                           (unless (search-forward-regexp end "^```") (return))
                           (delete-line start)
                           (delete-line end)
                           (syntax-scan-region start end :syntax-table syntax-table)
                           (apply-region-lines start
                                               end
                                               (lambda (point)
                                                 (line-start point)
                                                 (insert-string point " ")
                                                 (line-end point)
                                                 (insert-string point " ")))))))
           (process-horizontal-line (point)
             (buffer-start point)
             (let ((width (lem.popup-window::compute-buffer-width (point-buffer point))))
               (loop :while (search-forward-regexp point "^-+$")
                     :do (with-point ((start point :right-inserting)
                                      (end point :left-inserting))
                           (line-start start)
                           (line-end end)
                           (delete-between-points start end)
                           (insert-string start (make-string width :initial-element #\_))
                           (insert-character end #\newline))))))
    (let* ((buffer (make-markdown-buffer markdown-text))
           (point (buffer-point buffer)))
      (process-header point)
      (process-code-block point)
      (process-horizontal-line point)
      (trim-final-newlines point)
      buffer)))

(defun contents-to-string (contents)
  (flet ((marked-string-to-string (marked-string)
           (if (stringp marked-string)
               marked-string
               (or (get-map marked-string "value")
                   ""))))
    (cond
      ;; MarkedString
      ((typep contents 'lsp:marked-string)
       (marked-string-to-string contents))
      ;; MarkedString[]
      ((lsp-array-p contents)
       (with-output-to-string (out)
         (do-sequence (content contents)
           (write-string (marked-string-to-string content)
                         out))))
      ;; MarkupContent
      ((typep contents 'lsp:markup-content)
       (lsp:markup-content-value contents))
      (t
       ""))))

(defun contents-to-markdown-buffer (contents)
  (let ((string (contents-to-string contents)))
    (unless (emptyp (string-trim '(#\space #\newline) string))
      (markdown-buffer string))))

(defun provide-hover-p (workspace)
  (handler-case (lsp:server-capabilities-hover-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/hover (point)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-hover-p workspace)
      (let ((result
              (request:request
               (workspace-client workspace)
               (make-instance 'lsp:text-document/hover)
               (apply #'make-instance
                      'lsp:hover-params
                      (make-text-document-position-arguments point)))))
        (unless (lsp-null-p result)
          (contents-to-markdown-buffer (lsp:hover-contents result)))))))

(define-command lsp-hover () ()
  (check-connection)
  (when-let ((result (text-document/hover (current-point))))
    (display-message result)))

;;; completion

;; TODO
;; - serverでサポートしているかのチェックをする
;; - workDoneProgress
;; - partialResult
;; - completionParams.context, どのように補完が起動されたかの情報を含める
;; - completionItemの使っていない要素が多分にある
;; - completionResolve

(defclass completion-item (completion:completion-item)
  ((sort-text
    :initarg :sort-text
    :reader completion-item-sort-text)))

(defun convert-to-range (point range)
  (let ((range-start (lsp:range-start range))
        (range-end (lsp:range-end range)))
    (with-point ((start point)
                 (end point))
      (move-to-lsp-position start range-start)
      (move-to-lsp-position end range-end)
      (list start end))))

(defun convert-completion-items (point items)
  (labels ((sort-items (items)
             (sort items #'string< :key #'completion-item-sort-text))
           (label-and-points (item)
             (let ((text-edit
                     (handler-case (lsp:completion-item-text-edit item)
                       (unbound-slot () nil))))
               (if text-edit
                   (cons (lsp:text-edit-new-text text-edit)
                         (convert-to-range point (lsp:text-edit-range text-edit)))
                   (list (lsp:completion-item-label item) nil nil))))
           (make-completion-item (item)
             (destructuring-bind (label start end)
                 (label-and-points item)
               (declare (ignore end))
               (make-instance
                'completion-item
                :start start
                ;; 補完候補を表示した後に文字を入力し, 候補選択をするとendがずれるので使えない
                ;; :end end
                :label label
                :detail (handler-case (lsp:completion-item-detail item)
                          (unbound-slot () ""))
                :sort-text (handler-case (lsp:completion-item-sort-text item)
                             (unbound-slot ()
                               (lsp:completion-item-label item)))
                :focus-action (when-let ((documentation
                                          (handler-case (lsp:completion-item-documentation item)
                                            (unbound-slot () nil))))
                                (lambda ()
                                  (when-let ((result (contents-to-markdown-buffer documentation)))
                                    (display-message result
                                                     :gravity :adjacent-window
                                                     :source-window (lem.popup-window::popup-menu-window
                                                                     lem.popup-window::*popup-menu*)))))))))
    (sort-items
     (map 'list
          #'make-completion-item
          items))))

(defun convert-completion-list (point completion-list)
  (convert-completion-items point (lsp:completion-list-items completion-list)))

(defun convert-completion-response (point value)
  (cond ((typep value 'lsp:completion-list)
         (convert-completion-list point value))
        ((lsp-array-p value)
         (convert-completion-items point value))
        (t
         nil)))

(defun provide-completion-p (workspace)
  (handler-case (lsp:server-capabilities-completion-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/completion (point then)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-completion-p workspace)
      (async-request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/completion)
       (apply #'make-instance
              'lsp:completion-params
              (make-text-document-position-arguments point))
       :then (lambda (response)
               (funcall then (convert-completion-response point response)))))))

(defun completion-with-trigger-character (c)
  (declare (ignore c))
  (check-connection)
  (lem.language-mode::complete-symbol))

;;; signatureHelp

(define-attribute signature-help-active-parameter-attribute
  (t :background "blue" :underline-p t))

(defun provide-signature-help-p (workspace)
  (handler-case (lsp:server-capabilities-signature-help-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun insert-markdown (point markdown-text)
  (insert-buffer point (markdown-buffer markdown-text)))

(defun insert-markup-content (point markup-content)
  (switch ((lsp:markup-content-kind markup-content) :test #'equal)
    ("markdown"
     (insert-markdown point (lsp:markup-content-value markup-content)))
    ("plaintext"
     (insert-string point (lsp:markup-content-value markup-content)))
    (otherwise
     (insert-string point (lsp:markup-content-value markup-content)))))

(defun insert-documentation (point documentation)
  (insert-character point #\newline)
  (etypecase documentation
    (lsp:markup-content
     (insert-markup-content point documentation))
    (string
     (insert-string point documentation))))

(defun make-signature-help-buffer (signature-help)
  (let* ((buffer (make-buffer nil :temporary t))
         (point (buffer-point buffer)))
    (setf (lem:variable-value 'lem:line-wrap :buffer buffer) nil)
    (let ((active-parameter
            (handler-case (lsp:signature-help-active-parameter signature-help)
              (unbound-slot () 0)))
          (active-signature
            (handler-case (lsp:signature-help-active-signature signature-help)
              (unbound-slot () nil)))
          (signatures (lsp:signature-help-signatures signature-help)))
      (do-sequence ((signature index) signatures)
        (when (plusp index) (insert-character point #\newline))
        (insert-string point (lsp:signature-information-label signature))
        (when (or (eql index active-signature)
                  (length= 1 signatures))
          (let ((parameters
                  (handler-case (lsp:signature-information-parameters signature)
                    (unbound-slot () nil)))
                (active-parameter
                  (handler-case (lsp:signature-information-active-parameter signature)
                    (unbound-slot () active-parameter))))
            (when (and (plusp (length parameters))
                       (< active-parameter (length parameters)))
              (let ((label (lsp:parameter-information-label
                            (elt parameters active-parameter))))
                ;; TODO: labelの型が[number, number]の場合に対応する
                (when (stringp label)
                  (with-point ((p point))
                    (buffer-start p)
                    (when (search-forward p label)
                      (with-point ((start p))
                        (character-offset start (- (length label)))
                        (put-text-property start p
                                           :attribute 'signature-help-active-parameter-attribute)))))))))
        (insert-character point #\newline)
        (handler-case (lsp:signature-information-documentation signature)
          (unbound-slot () nil)
          (:no-error (documentation)
            (insert-documentation point documentation))))
      (buffer-start point)
      buffer)))

(defun display-signature-help (signature-help)
  (let ((buffer (make-signature-help-buffer signature-help)))
    (display-message buffer)))

(defun text-document/signature-help (point &optional signature-help-context)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-signature-help-p workspace)
      (async-request (workspace-client workspace)
                     (make-instance 'lsp:text-document/signature-help)
                     (apply #'make-instance
                            'lsp:signature-help-params
                            (append (when signature-help-context
                                      `(:context ,signature-help-context))
                                    (make-text-document-position-arguments point)))
                     :then (lambda (result)
                             (unless (lsp-null-p result)
                               (display-signature-help result)))))))

(defun lsp-signature-help-with-trigger-character (character)
  (text-document/signature-help
   (current-point)
   (make-instance 'lsp:signature-help-context
                  :trigger-kind lsp:signature-help-trigger-kind-trigger-character
                  :trigger-character (string character)
                  :is-retrigger +false+
                  #|:active-signature-help|#)))

(define-command lsp-signature-help () ()
  (check-connection)
  (text-document/signature-help (current-point)
                                (make-instance 'lsp:signature-help-context
                                               :trigger-kind lsp:signature-help-trigger-kind-invoked
                                               :is-retrigger +false+)))

;;; declaration

(defun provide-declaration-p (workspace)
  (handler-case (lsp:server-capabilities-declaration-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/declaration (point)
  (declare (ignore point))
  ;; TODO: goplsが対応していなかったので後回し
  nil)

;;; definition

(defun provide-definition-p (workspace)
  (handler-case (lsp:server-capabilities-definition-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun definition-location-to-content (file location)
  (when-let* ((buffer (find-file-buffer file))
              (point (buffer-point buffer))
              (range (lsp:location-range location)))
    (with-point ((start point)
                 (end point))
      (move-to-lsp-position start (lsp:range-start range))
      (move-to-lsp-position end (lsp:range-end range))
      (line-start start)
      (line-end end)
      (points-to-string start end))))

(defgeneric convert-location (location)
  (:method ((location lsp:location))
    ;; TODO: end-positionも使い、定義位置への移動後のハイライトをstart/endの範囲にする
    (let* ((start-position (lsp:range-start (lsp:location-range location)))
           (end-position (lsp:range-end (lsp:location-range location)))
           (uri (lsp:location-uri location))
           (file (uri-to-pathname uri)))
      (declare (ignore end-position))
      (when (uiop:file-exists-p file)
        (lem.language-mode:make-xref-location
         :filespec file
         :position (lem.language-mode::make-position
                    (1+ (lsp:position-line start-position))
                    (lsp:position-character start-position))
         :content (definition-location-to-content file location)))))
  (:method ((location lsp:location-link))
    (error "locationLink is unsupported")))

(defun convert-definition-response (value)
  (remove nil
          (cond ((typep value 'lsp:location)
                 (list (convert-location value)))
                ((lsp-array-p value)
                 ;; TODO: location-link
                 (map 'list #'convert-location value))
                (t
                 nil))))

(defun text-document/definition (point then)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-definition-p workspace)
      (async-request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/definition)
       (apply #'make-instance
              'lsp:definition-params
              (make-text-document-position-arguments point))
       :then (lambda (response)
               (funcall then (convert-definition-response response))
               (redraw-display))))))

(defun find-definitions (point)
  (check-connection)
  (text-document/definition point #'lem.language-mode:display-xref-locations))

;;; type definition

(defun provide-type-definition-p (workspace)
  (handler-case (lsp:server-capabilities-type-definition-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun convert-type-definition-response (value)
  (convert-definition-response value))

(defun text-document/type-definition (point then)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-type-definition-p workspace)
      (async-request (workspace-client workspace)
                     (make-instance 'lsp:text-document/type-definition)
                     (apply #'make-instance
                            'lsp:type-definition-params
                            (make-text-document-position-arguments point))
                     :then (lambda (response)
                             (funcall then (convert-type-definition-response response)))))))

(define-command lsp-type-definition () ()
  (check-connection)
  (text-document/type-definition (current-point) #'lem.language-mode:display-xref-locations))

;;; implementation

(defun provide-implementation-p (workspace)
  (handler-case (lsp:server-capabilities-implementation-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun convert-implementation-response (value)
  (convert-definition-response value))

(defun text-document/implementation (point then)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-implementation-p workspace)
      (async-request (workspace-client workspace)
                     (make-instance 'lsp:text-document/implementation)
                     (apply #'make-instance
                            'lsp:type-definition-params
                            (make-text-document-position-arguments point))
                     :then (lambda (response)
                             (funcall then (convert-implementation-response response)))))))

(define-command lsp-implementation () ()
  (check-connection)
  (text-document/implementation (current-point)
                                #'lem.language-mode:display-xref-locations))

;;; references

(defun provide-references-p (workspace)
  (handler-case (lsp:server-capabilities-references-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun xref-location-to-content (location)
  (when-let*
      ((buffer (find-file-buffer (lem.language-mode:xref-location-filespec location) :temporary t))
       (point (buffer-point buffer)))
    (lem.language-mode::move-to-location-position
     point
     (lem.language-mode:xref-location-position location))
    (string-trim '(#\space #\tab) (line-string point))))

(defun convert-references-response (value)
  (lem.language-mode:make-xref-references
   :type nil
   :locations (mapcar (lambda (location)
                        (lem.language-mode:make-xref-location
                         :filespec (lem.language-mode:xref-location-filespec location)
                         :position (lem.language-mode:xref-location-position location)
                         :content (xref-location-to-content location)))
                      (convert-definition-response value))))

(defun text-document/references (point then &optional include-declaration)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-references-p workspace)
      (async-request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/references)
       (apply #'make-instance
              'lsp:reference-params
              :context (make-instance 'lsp:reference-context
                                      :include-declaration include-declaration)
              (make-text-document-position-arguments point))
       :then (lambda (response)
               (funcall then (convert-references-response response)))))))

(defun find-references (point)
  (check-connection)
  (text-document/references point
                            #'lem.language-mode:display-xref-references))

;;; document highlights

(define-attribute document-highlight-text-attribute
  (t :background "yellow4"))

(defun provide-document-highlight-p (workspace)
  (handler-case (lsp:server-capabilities-document-highlight-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defstruct document-highlight-context
  (overlays '())
  (last-modified-tick 0))

(defvar *document-highlight-context* (make-document-highlight-context))

(defun document-highlight-overlays ()
  (document-highlight-context-overlays *document-highlight-context*))

(defun (setf document-highlight-overlays) (value)
  (setf (document-highlight-context-overlays *document-highlight-context*)
        value))

(defun cursor-in-document-highlight-p ()
  (dolist (ov (document-highlight-overlays))
    (unless (eq (current-buffer) (overlay-buffer ov))
      (return nil))
    (when (point<= (overlay-start ov) (current-point) (overlay-end ov))
      (return t))))

(defun clear-document-highlight-overlays ()
  (unless (and (cursor-in-document-highlight-p)
               (= (document-highlight-context-last-modified-tick *document-highlight-context*)
                  (buffer-modified-tick (current-buffer))))
    (mapc #'delete-overlay (document-highlight-overlays))
    (setf (document-highlight-overlays) '())
    (setf (document-highlight-context-last-modified-tick *document-highlight-context*)
          (buffer-modified-tick (current-buffer)))
    t))

(defun display-document-highlights (buffer document-highlights)
  (with-point ((start (buffer-point buffer))
               (end (buffer-point buffer)))
    (do-sequence (document-highlight document-highlights)
      (let ((range (lsp:document-highlight-range document-highlight)))
        (move-to-lsp-position start (lsp:range-start range))
        (move-to-lsp-position end (lsp:range-end range))
        (push (make-overlay start end 'document-highlight-text-attribute)
              (document-highlight-overlays))))))

(defun text-document/document-highlight (point)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-document-highlight-p workspace)
      (unless (cursor-in-document-highlight-p)
        (let ((counter (lem::command-loop-counter)))
          (async-request
           (workspace-client workspace)
           (make-instance 'lsp:text-document/document-highlight)
           (apply #'make-instance
                  'lsp:document-highlight-params
                  (make-text-document-position-arguments point))
           :then (lambda (value)
                   (unless (lsp-null-p value)
                     (when (= counter (lem::command-loop-counter))
                       (display-document-highlights (point-buffer point)
                                                    value)
                       (redraw-display))))))))))

(defun document-highlight-calls-timer ()
  (when (mode-active-p (current-buffer) 'lsp-mode)
    (text-document/document-highlight (current-point))))

(define-command lsp-document-highlight () ()
  (when (mode-active-p (current-buffer) 'lsp-mode)
    (check-connection)
    (text-document/document-highlight (current-point))))

(defvar *document-highlight-idle-timer* nil)

(defun enable-document-highlight-idle-timer ()
  (unless *document-highlight-idle-timer*
    (setf *document-highlight-idle-timer*
          (start-idle-timer 200 t #'document-highlight-calls-timer nil
                            "lsp-document-highlight"))))

(define-condition lsp-after-executing-command (after-executing-command) ())
(defmethod handle-signal ((condition lsp-after-executing-command))
  (when (mode-active-p (current-buffer) 'lsp-mode)
    (clear-document-highlight-overlays)))

;;; document symbols

;; TODO
;; - position順でソートする

(define-attribute symbol-kind-file-attribute
  (t :foreground "snow1"))

(define-attribute symbol-kind-module-attribute
  (t :foreground "firebrick"))

(define-attribute symbol-kind-namespace-attribute
  (t :foreground "dark orchid"))

(define-attribute symbol-kind-package-attribute
  (t :foreground "green"))

(define-attribute symbol-kind-class-attribute
  (t :foreground "bisque2"))

(define-attribute symbol-kind-method-attribute
  (t :foreground "MediumPurple2"))

(define-attribute symbol-kind-property-attribute
  (t :foreground "MistyRose4"))

(define-attribute symbol-kind-field-attribute
  (t :foreground "azure3"))

(define-attribute symbol-kind-constructor-attribute
  (t :foreground "LightSkyBlue3"))

(define-attribute symbol-kind-enum-attribute
  (t :foreground "LightCyan4"))

(define-attribute symbol-kind-interface-attribute
  (t :foreground "gray78"))

(define-attribute symbol-kind-function-attribute
  (t :foreground "LightSkyBlue"))

(define-attribute symbol-kind-variable-attribute
  (t :foreground "LightGoldenrod"))

(define-attribute symbol-kind-constant-attribute
  (t :foreground "yellow2"))

(define-attribute symbol-kind-string-attribute
  (t :foreground "green"))

(define-attribute symbol-kind-number-attribute
  (t :foreground "yellow"))

(define-attribute symbol-kind-boolean-attribute
  (t :foreground "honeydew3"))

(define-attribute symbol-kind-array-attribute
  (t :foreground "red"))

(define-attribute symbol-kind-object-attribute
  (t :foreground "PeachPuff4"))

(define-attribute symbol-kind-key-attribute
  (t :foreground "lime green"))

(define-attribute symbol-kind-null-attribute
  (t :foreground "gray"))

(define-attribute symbol-kind-enum-membe-attribute
  (t :foreground "PaleTurquoise4"))

(define-attribute symbol-kind-struct-attribute
  (t :foreground "turquoise4"))

(define-attribute symbol-kind-event-attribute
  (t :foreground "aquamarine1"))

(define-attribute symbol-kind-operator-attribute
  (t :foreground "SeaGreen3"))

(define-attribute symbol-kind-type-attribute
  (t :foreground "moccasin"))

(defun preview-symbol-kind-colors ()
  (let* ((buffer (make-buffer "symbol-kind-colors"))
         (point (buffer-point buffer)))
    (dolist (attribute
             (list 'symbol-kind-file-attribute
                   'symbol-kind-module-attribute
                   'symbol-kind-namespace-attribute
                   'symbol-kind-package-attribute
                   'symbol-kind-class-attribute
                   'symbol-kind-method-attribute
                   'symbol-kind-property-attribute
                   'symbol-kind-field-attribute
                   'symbol-kind-constructor-attribute
                   'symbol-kind-enum-attribute
                   'symbol-kind-interface-attribute
                   'symbol-kind-function-attribute
                   'symbol-kind-variable-attribute
                   'symbol-kind-constant-attribute
                   'symbol-kind-string-attribute
                   'symbol-kind-number-attribute
                   'symbol-kind-boolean-attribute
                   'symbol-kind-array-attribute
                   'symbol-kind-object-attribute
                   'symbol-kind-key-attribute
                   'symbol-kind-null-attribute
                   'symbol-kind-enum-membe-attribute
                   'symbol-kind-struct-attribute
                   'symbol-kind-event-attribute
                   'symbol-kind-operator-attribute
                   'symbol-kind-type-attribute))
      (insert-string point (string-downcase attribute) :attribute attribute)
      (insert-character point #\newline))))

(defun provide-document-symbol-p (workspace)
  (handler-case (lsp:server-capabilities-document-symbol-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun symbol-kind-to-string-and-attribute (symbol-kind)
  (switch (symbol-kind :test #'=)
    (lsp:symbol-kind-file
     (values "File" 'symbol-kind-file-attribute))
    (lsp:symbol-kind-module
     (values "Module" 'symbol-kind-module-attribute))
    (lsp:symbol-kind-namespace
     (values "Namespace" 'symbol-kind-namespace-attribute))
    (lsp:symbol-kind-package
     (values "Package" 'symbol-kind-package-attribute))
    (lsp:symbol-kind-class
     (values "Class" 'symbol-kind-class-attribute))
    (lsp:symbol-kind-method
     (values "Method" 'symbol-kind-method-attribute))
    (lsp:symbol-kind-property
     (values "Property" 'symbol-kind-property-attribute))
    (lsp:symbol-kind-field
     (values "Field" 'symbol-kind-field-attribute))
    (lsp:symbol-kind-constructor
     (values "Constructor" 'symbol-kind-constructor-attribute))
    (lsp:symbol-kind-enum
     (values "Enum" 'symbol-kind-enum-attribute))
    (lsp:symbol-kind-interface
     (values "Interface" 'symbol-kind-interface-attribute))
    (lsp:symbol-kind-function
     (values "Function" 'symbol-kind-function-attribute))
    (lsp:symbol-kind-variable
     (values "Variable" 'symbol-kind-variable-attribute))
    (lsp:symbol-kind-constant
     (values "Constant" 'symbol-kind-constant-attribute))
    (lsp:symbol-kind-string
     (values "String" 'symbol-kind-string-attribute))
    (lsp:symbol-kind-number
     (values "Number" 'symbol-kind-number-attribute))
    (lsp:symbol-kind-boolean
     (values "Boolean" 'symbol-kind-boolean-attribute))
    (lsp:symbol-kind-array
     (values "Array" 'symbol-kind-array-attribute))
    (lsp:symbol-kind-object
     (values "Object" 'symbol-kind-object-attribute))
    (lsp:symbol-kind-key
     (values "Key" 'symbol-kind-key-attribute))
    (lsp:symbol-kind-null
     (values "Null" 'symbol-kind-null-attribute))
    (lsp:symbol-kind-enum-member
     (values "EnumMember" 'symbol-kind-enum-member-attribute))
    (lsp:symbol-kind-struct
     (values "Struct" 'symbol-kind-struct-attribute))
    (lsp:symbol-kind-event
     (values "Event" 'symbol-kind-event-attribute))
    (lsp:symbol-kind-operator
     (values "Operator" 'symbol-kind-operator-attribute))
    (lsp:symbol-kind-type-parameter
     (values "TypeParameter" 'symbol-kind-type-attribute))))

(define-attribute document-symbol-detail-attribute
  (t :foreground "gray"))

(defun append-document-symbol-item (sourcelist buffer document-symbol nest-level)
  (let ((selection-range (lsp:document-symbol-selection-range document-symbol))
        (range (lsp:document-symbol-range document-symbol)))
    (lem.sourcelist:append-sourcelist
     sourcelist
     (lambda (point)
       (multiple-value-bind (kind-name attribute)
           (symbol-kind-to-string-and-attribute (lsp:document-symbol-kind document-symbol))
         (insert-string point (make-string (* 2 nest-level) :initial-element #\space))
         (insert-string point (format nil "[~A]" kind-name) :attribute attribute)
         (insert-character point #\space)
         (insert-string point (lsp:document-symbol-name document-symbol))
         (insert-string point " ")
         (when-let (detail (handler-case (lsp:document-symbol-detail document-symbol)
                             (unbound-slot () nil)))
           (insert-string point detail :attribute 'document-symbol-detail-attribute))))
     (lambda (set-buffer-fn)
       (funcall set-buffer-fn buffer)
       (let ((point (buffer-point buffer)))
         (move-to-lsp-position point (lsp:range-start selection-range))))
     :highlight-overlay-function (lambda (point)
                                   (with-point ((start point)
                                                (end point))
                                     (make-overlay
                                      (move-to-lsp-position start (lsp:range-start range))
                                      (move-to-lsp-position end (lsp:range-end range))
                                      'lem.sourcelist::jump-highlight)))))
  (do-sequence
      (document-symbol
       (handler-case (lsp:document-symbol-children document-symbol)
         (unbound-slot () nil)))
    (append-document-symbol-item sourcelist buffer document-symbol (1+ nest-level))))

(defun display-document-symbol-response (buffer value)
  (lem.sourcelist:with-sourcelist (sourcelist "*Document Symbol*")
    (do-sequence (item value)
      (append-document-symbol-item sourcelist buffer item 0))))

(defun text-document/document-symbol (buffer)
  (when-let ((workspace (buffer-workspace buffer)))
    (when (provide-document-symbol-p workspace)
      (request:request
       (workspace-client workspace)
       (make-instance 'lsp:text-document/document-symbol)
       (make-instance
        'lsp:document-symbol-params
        :text-document (make-text-document-identifier buffer))))))

(define-command lsp-document-symbol () ()
  (check-connection)
  (display-document-symbol-response
   (current-buffer)
   (text-document/document-symbol (current-buffer))))

;;; code action
;; TODO
;; - codeAction.diagnostics
;; - codeAction.isPreferred

(defun provide-code-action-p (workspace)
  (handler-case (lsp:server-capabilities-code-action-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun execute-command (workspace command)
  ;; TODO
  ;; レスポンスを見てなんらかの処理をする必要がある
  ;; この機能はgoplsで使われる事が今のところないので動作テストをできていない
  (request:request
   (workspace-client workspace)
   (make-instance 'lsp:workspace/execute-command)
   (make-instance 'lsp:execute-command-params
                  :command (lsp:command-command command)
                  :arguments (lsp:command-arguments command))))

(defun execute-code-action (workspace code-action)
  (handler-case (lsp:code-action-edit code-action)
    (unbound-slot () nil)
    (:no-error (workspace-edit)
      (apply-workspace-edit workspace-edit)))
  (handler-case (lsp:code-action-command code-action)
    (unbound-slot () nil)
    (:no-error (command)
      (execute-command workspace command))))

(defun convert-code-actions (code-actions workspace)
  (let ((items '()))
    (do-sequence (command-or-code-action code-actions)
      (etypecase command-or-code-action
        (lsp:code-action
         (let ((code-action command-or-code-action))
           (push (context-menu:make-item :label (lsp:code-action-title code-action)
                                         :callback (curry #'execute-code-action workspace code-action))
                 items)))
        (lsp:command
         (let ((command command-or-code-action))
           (push (context-menu:make-item :label (lsp:command-title command)
                                         :callback (curry #'execute-command workspace command))
                 items)))))
    (nreverse items)))

(defun text-document/code-action (point)
  (flet ((point-to-line-range (point)
           (with-point ((start point)
                        (end point))
             (line-start start)
             (line-end end)
             (points-to-lsp-range start end))))
    (when-let ((workspace (get-workspace-from-point point)))
      (when (provide-code-action-p workspace)
        (request:request
         (workspace-client workspace)
         (make-instance 'lsp:text-document/code-action)
         (make-instance
          'lsp:code-action-params
          :text-document (make-text-document-identifier (point-buffer point))
          :range (point-to-line-range point)
          :context (make-instance 'lsp:code-action-context
                                  :diagnostics (make-lsp-array))))))))

(define-command lsp-code-action () ()
  (check-connection)
  (let ((response (text-document/code-action (current-point)))
        (workspace (buffer-workspace (current-buffer))))
    (cond ((typep response 'lsp:command)
           (execute-command workspace response))
          ((and (lsp-array-p response)
                (not (length= response 0)))
           (context-menu:display-context-menu
            (convert-code-actions response
                                  workspace)))
          (t
           (message "No suggestions from code action")))))

(defun find-organize-imports (code-actions)
  (do-sequence (code-action code-actions)
    (when (equal "source.organizeImports" (lsp:code-action-kind code-action))
      (return-from find-organize-imports code-action))))

(defun organize-imports (buffer)
  (let ((response (text-document/code-action (buffer-point buffer)))
        (workspace (buffer-workspace buffer)))
    (let ((code-action (find-organize-imports response)))
      (unless (lsp-null-p code-action)
        (execute-code-action workspace code-action)))))

(define-command lsp-organize-imports () ()
  (organize-imports (current-buffer)))

;;; formatting

(defun provide-formatting-p (workspace)
  (handler-case (lsp:server-capabilities-document-formatting-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun make-formatting-options (buffer)
  (make-instance
   'lsp:formatting-options
   :tab-size (or (variable-value 'tab-width :buffer buffer) +default-tab-size+)
   :insert-spaces (not (variable-value 'indent-tabs-mode :buffer buffer))
   :trim-trailing-whitespace t
   :insert-final-newline t
   :trim-final-newlines t))

(defun text-document/formatting (buffer)
  (when-let ((workspace (buffer-workspace buffer)))
    (when (provide-formatting-p workspace)
      (apply-text-edits
       buffer
       (request:request
        (workspace-client workspace)
        (make-instance 'lsp:text-document/formatting)
        (make-instance
         'lsp:document-formatting-params
         :text-document (make-text-document-identifier buffer)
         :options (make-formatting-options buffer)))))))

(define-command lsp-document-format () ()
  (check-connection)
  (text-document/formatting (current-buffer)))

;;; range formatting

;; WARNING: goplsでサポートされていないので動作未確認

(defun provide-range-formatting-p (workspace)
  (handler-case (lsp:server-capabilities-document-range-formatting-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/range-formatting (start end)
  (when (point< end start) (rotatef start end))
  (let ((buffer (point-buffer start)))
    (when-let ((workspace (buffer-workspace buffer)))
      (when (provide-range-formatting-p workspace)
        (apply-text-edits
         buffer
         (request:request
          (workspace-client workspace)
          (make-instance 'lsp:text-document/range-formatting)
          (make-instance
           'lsp:document-range-formatting-params
           :text-document (make-text-document-identifier buffer)
           :range (points-to-lsp-range start end)
           :options (make-formatting-options buffer))))))))

(define-command lsp-document-range-format (start end) ("r")
  (check-connection)
  (text-document/range-formatting start end))

;;; onTypeFormatting

;; TODO
;; - バッファの初期化時にtext-document/on-type-formattingを呼び出すフックを追加する

(defun provide-on-type-formatting-p (workspace)
  (handler-case (lsp:server-capabilities-document-on-type-formatting-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/on-type-formatting (point typed-character)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-on-type-formatting-p workspace)
      (when-let ((response
                  (with-jsonrpc-error ()
                    (request:request
                     (workspace-client workspace)
                     (make-instance 'lsp:text-document-client-capabilities-on-type-formatting)
                     (apply #'make-instance
                            'lsp:document-on-type-formatting-params
                            :ch typed-character
                            :options (make-formatting-options (point-buffer point))
                            (make-text-document-position-arguments point))))))
        (apply-text-edits (point-buffer point) response)))))

;;; rename

;; TODO
;; - prepareSupport

(defun provide-rename-p (workspace)
  (handler-case (lsp:server-capabilities-rename-provider
                 (workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun text-document/rename (point new-name)
  (when-let ((workspace (get-workspace-from-point point)))
    (when (provide-rename-p workspace)
      (when-let ((response
                  (with-jsonrpc-error ()
                    (request:request
                     (workspace-client workspace)
                     (make-instance 'lsp:text-document/rename)
                     (apply #'make-instance
                            'lsp:rename-params
                            :new-name new-name
                            (make-text-document-position-arguments point))))))
        (apply-workspace-edit response)))))

(define-command lsp-rename (new-name) ("sNew name: ")
  (check-connection)
  (text-document/rename (current-point) new-name))

;;;
(define-command lsp-restart-server () ()
  (when-let ((spec (buffer-language-spec (current-buffer))))
    (kill-server-process spec)
    (ensure-lsp-buffer (current-buffer))))

;;;
(defun enable-lsp-mode ()
  (lsp-mode t))

(defmacro define-language-spec ((spec-name major-mode) &body initargs)
  `(progn
     (register-language-spec ',major-mode ',spec-name)
     ,(when (lem::mode-hook-variable major-mode)
        `(add-hook ,(lem::mode-hook-variable major-mode) 'enable-lsp-mode))
     (defclass ,spec-name (spec) ()
       (:default-initargs ,@initargs))))

#|
(define-language-spec (js-spec lem-js-mode:js-mode)
  :language-id "javascript"
  :root-uri-patterns '("package.json" "tsconfig.json")
  :command '("typescript-language-server" "--stdio")
  :install-command "npm install -g typescript-language-server typescript"
  :readme-url "https://github.com/typescript-language-server/typescript-language-server"
  :mode :stdio)

(define-language-spec (rust-spec lem-rust-mode:rust-mode)
  :language-id "rust"
  :root-uri-patterns '("Cargo.toml")
  :command '("rls")
  :readme-url "https://github.com/rust-lang/rls"
  :mode :stdio)

(define-language-spec (sql-spec lem-sql-mode:sql-mode)
  :language-id "sql"
  :root-uri-patterns '()
  :command '("sql-language-server" "up" "--method" "stdio")
  :readme-url "https://github.com/joe-re/sql-language-server"
  :mode :stdio)

(defun find-dart-bin-path ()
  (multiple-value-bind (output error-output status)
      (uiop:run-program '("which" "dart")
                        :output :string
                        :ignore-error-status t)
    (declare (ignore error-output))
    (if (zerop status)
        (namestring
         (uiop:pathname-directory-pathname
          (string-right-trim '(#\newline) output)))
        nil)))

(defun find-dart-language-server ()
  (let ((program-name "analysis_server.dart.snapshot"))
    (when-let (path (find-dart-bin-path))
      (let ((result
              (string-right-trim
               '(#\newline)
               (uiop:run-program (list "find" path "-name" program-name)
                                 :output :string))))
        (when (search program-name result)
          result)))))

(define-language-spec (dart-spec lem-dart-mode:dart-mode)
  :language-id "dart"
  :root-uri-patterns '("pubspec.yaml")
  :mode :stdio)

(defmethod spec-command ((spec dart-spec))
  (if-let ((lsp-path (find-dart-language-server)))
    (list "dart" lsp-path "--lsp")
    (editor-error "dart language server not found")))

(defmethod spec-initialization-options ((spec dart-spec))
  (make-lsp-map "onlyAnalyzeProjectsWithOpenFiles" +true+
                "suggestFromUnimportedLibraries" +true+))
|#

#|
Language Features
- [X] completion
- [ ] completion resolve
- [X] hover
- [X] signatureHelp
- [ ] declaration
- [X] definition
- [X] typeDefinition
- [X] implementation
- [X] references
- [X] documentHighlight
- [X] documentSymbol
- [X] codeAction
- [ ] codeLens
- [ ] codeLens resolve
- [ ] documentLink
- [ ] documentLink resolve
- [ ] documentColor
- [ ] colorPresentation
- [X] formatting
- [X] rangeFormatting
- [X] onTypeFormatting
- [X] rename
- [ ] prepareRename
- [ ] foldingRange
- [ ] selectionRange

TODO
- partialResult
- workDoneProgress
|#
