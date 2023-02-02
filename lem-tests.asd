(defsystem "lem-tests"
  :depends-on ("lem-base"
               "lem"
               "lem-fake-interface"
               "lem-lisp-syntax"
               "lem-lisp-mode"
               "cl-ansi-text"
               "trivial-package-local-nicknames"
               "rove")
  :pathname "tests"
  :components ((:file "utilities")
               (:module "common"
                :components ((:file "ring")
                             (:file "killring")
                             (:file "history")))
               (:module "language-server"
                :components ((:file "utils")
                             (:file "micros-tests")
                             (:file "tests")))
               (:module "lisp-syntax"
                :components ((:file "indent-test")
                             (:file "defstruct-to-defclass")))
               (:module "lisp-mode"
                :components ((:file "package-inferred-system")))
               (:file "string-width-utils")
               (:file "syntax-test")
               (:file "buffer-list-test")
               (:file "popup-window")
               (:file "prompt")
               (:file "isearch")
               (:file "cursors")
               (:file "self-insert-command")
               (:file "interp")
               (:file "file")
               (:file "completion"))
  :perform (test-op (o c)
                    (symbol-call :rove :run c)))
