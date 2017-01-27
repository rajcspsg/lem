(in-package :cl-user)
(defpackage :lem.abbrev
  (:use :cl :lem)
  (:export :abbrev))
(in-package :lem.abbrev)

(defun preceding-word (point)
  (with-point ((cur point)
               (end point))
    (skip-chars-backward cur #'syntax-symbol-char-p)
    (points-to-string cur end)))

(defun scan-line-words (str)
  (let ((words))
    (do ((i 0 (1+ i)))
        ((>= i (length str)))
      (when (syntax-symbol-char-p (aref str i))
        (push (subseq str i
                      (do ((j i (1+ j)))
                          ((or (>= j (length str))
                               (not (syntax-symbol-char-p (aref str j))))
                           (setq i j)
                           j)))
              words)))
    (nreverse words)))

(defun scan-buffer-words (buffer word)
  (let ((words))
    (with-open-stream (in (make-buffer-input-stream (buffers-start buffer)))
      (loop :for str := (read-line in nil)
	 :while str
	 :do (dolist (w (remove-if-not #'(lambda (tok)
					   (and (string/= word tok)
						(eql 0 (search word tok))))
				       (scan-line-words str)))
	       (push w words))))
    (nreverse words)))

(defun scan-all-buffer-words (word)
  (remove-duplicates
   (nconc (scan-buffer-words (current-buffer) word)
          (mapcan #'(lambda (buffer)
                      (unless (eq buffer (current-buffer))
                        (scan-buffer-words buffer word)))
                  (buffer-list)))
   :test #'equal))

(define-key *global-keymap* (kbd "C-x /") 'abbrev-with-pop-up-window)
(define-command abbrev-with-pop-up-window () ()
  (let* ((src-word (preceding-word (current-point)))
         (words (scan-all-buffer-words src-word)))
    (with-point ((start (current-point))
                 (end (current-point)))
      (skip-chars-backward start #'syntax-symbol-char-p)
      (run-completion (mapcar (lambda (word)
                                (make-completion-item :label word
                                                      :start start
                                                      :end end))
                              words)))))

(defvar *rest-words* nil)
(defvar *all-words* nil)
(defvar *start-charpos* nil)

(define-key *global-keymap* (kbd "M-/") 'abbrev)
(define-command abbrev () ()
  (let ((point (current-point)))
    (cond ((continue-flag :abbrev)
           (when (null *rest-words*)
             (setf *rest-words* *all-words*))
           (let ((n (- (point-charpos point) *start-charpos*)))
             (line-offset point 0 *start-charpos*)
             (delete-character point n))
           (insert-string point (first *rest-words*))
           (setf *rest-words* (rest *rest-words*)))
          (t
           (let* ((src-word (preceding-word point))
                  (words (scan-all-buffer-words src-word)))
             (delete-character point (- (length src-word)))
             (setf *rest-words* (rest words))
             (setf *all-words* words)
             (setf *start-charpos* (point-charpos point))
             (insert-string point (first words)))))))
