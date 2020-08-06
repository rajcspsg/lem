(in-package :lem)

(defparameter *frame-display-map* (make-hash-table))

(defstruct frame
  ;; window
  current-window
  (window-tree nil)
  (floating-windows '())
  (header-windows '())
  (modified-floating-windows nil)
  (modified-header-windows nil)
  ;; minibuffer
  minibuffer-buffer
  echoarea-buffer
  (minibuf-window nil)
  (minibuffer-calls-window nil)
  (minibuffer-start-charpos nil))

(defun map-frame (key frame)
  (setf (gethash key *frame-display-map*) frame))

(defun get-frame (key)
  (gethash key *frame-display-map*))

(defun current-frame ()
  (get-frame (implementation)))

(defun unmap-frame (key)
  (let ((frame (gethash key *frame-display-map*)))
    (remhash key)
    frame))

(defun setup-frame (frame)
  (setup-minibuffer frame)
  (setup-windows frame))

(defun teardown-frame (frame)
  (teardown-windows frame)
  ;; (teardown-minibuffer frame) ; minibufferをfloating-windowとして扱うので開放処理はしない
)

(defun teardown-frames ()
  (maphash (lambda (k v)
             (declare (ignore k))
             (teardown-frame v))
           *frame-display-map*))

(defun redraw-frame (frame)
  (redraw-display* frame))
