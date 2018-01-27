;; -*- Gerbil -*-
;;;; Utilities for files

(export
  #t)

(import
  :gerbil/gambit/ports
  :std/format :std/misc/ports :std/sugar :std/pregexp
  :clan/utils/base :clan/utils/temporary-files)

;; Output some contents to a port.
;; The contents can be a string (display'ed), a u8vector (written),
;; or a procedure (called with the port as argument)
(def (output-contents contents port)
  (cond
   ((string? contents) (display contents port))
   ((u8vector? contents) (write-u8vector contents port)) ;; TODO: does this retry on incomplete write?
   ((procedure? contents) (contents port))
   (else (error "invalid contents" contents))))

;; Atomically replace a file by one produced from the contents using output-contents
(def (clobber-file file contents settings: (settings '()))
  (let* ((target (path-normalize file))
         (directory (path-directory target)))
    (call-with-temporary-file
     directory: directory
     prefix: (path-strip-directory target)
     settings: settings
     while-open: (λ (port path) (output-contents contents port))
     after-close: (λ (path) (rename-file path target))))) ;; should be atomic, at least on Unix

;; Run the contents of a file into a transformer, then,
;; if the new contents are different from the old contents,
;; atomically replace the file by one with the new contents.
(def (maybe-replace-file
      file transformer
      reader: (reader read-all-as-string)
      writer: (writer #f)
      comparator: (comparator equal?)
      settings: (settings '()))
  (printf "Transforming file ~a... " file)
  (let* ((old-contents (call-with-input-file [path: file . settings] reader))
         (new-contents (transformer old-contents)))
    (if (comparator old-contents new-contents)
      (printf "no changes needed!~%")
      (begin
        (clobber-file file (λ (port) ((or writer display) new-contents port)) settings: settings)
        (printf "done.~%"))))
  (void))