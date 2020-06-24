;; User-level transactions on top of a single synchronous leveldb writebatch.
;;
;; This file defines transactional access to a simple key-value store.
;; All current transactions go into a current batch, that at one point is
;; triggered for commit. At that point, it will wait for current transactions
;; to all be closed while blocking any new transaction from being open.
;; Thus, transactions must always be short or there may be long delays,
;; deadlocks, and/or memory overflow. Also, we have only roll-forward and
;; not roll-back of transactions, and so they must use suitable mechanisms
;; for mutual exclusion and validation before to write anything to the database.
;;
;; Multiple threads can read the database with db-key? and db-get,
;; seeing the state before the current transaction batch,
;; and contribute to the current transaction with db-put! and db-remove!.
;; Transactions ensure that all updates made within the transaction are
;; included in a same atomic batch. A transaction is scheduled for commit
;; with close-transaction, and you can wait for its completion with
;; commit-transaction.
;;
;; with-tx is a no-op if there is already a (current-db-transaction); if not,
;; it opens a transaction, executes code while this transaction is the
;; (current-db-transaction), commit it at the end, and waits for commit.
;;
;; This code was ported from my OCaml library legilogic_lib,
;; though I did refactor and enhance the code as I ported it.
;; Notably, in the OCaml variant, every function was defined twice,
;; as a client half sending a request and some server spaghetti code
;; processing it, with some data in between and plenty of promises
;; to communicate (like Gerbil std/misc/completion, just separating the
;; post! and wait! capabilities). Instead, in Gerbil, I use locking
;; so functions can be defined only once, at the cost of having to
;; explicitly use the fields of a struct to share state instead of
;; just nicely scoped variables.
;;
;; Also, I added a timer for deferred triggering of batches by transaction.
;; I thought I had implemented that in OCaml, but that wasn't currently
;; in the master branch of legicash-facts. This is made necessary in Gambit,
;; because Gambit is lacking the OCaml feature allowing to run a FFI function
;; (in this case, the leveldb in parallel with other OCaml functions).
;; This parallelism in OCaml naturally allowed the workers to synchronize with
;; the speed of the batch commits, but that won't work on Gambit,
;; until we debug the Gambit SMP support.
;;
;; Final difference from OCaml, we use parameters for dynamic binding of the
;; database context, where OCaml could only use global variables, static binding,
;; and/or an explicit reader monad.

(export #t)
(import
  :gerbil/gambit/threads
  :std/db/leveldb
  :std/misc/completion :std/misc/list :std/sugar
  :clan/utils/number :clan/utils/path)

(import :clan/utils/debug)

(defstruct DbConnection
  (name leveldb mx txcounter
   blocked-transactions open-transactions pending-transactions hooks
   batch-id batch manager timer
   ready? triggered?)
  constructor: :init!)
(defmethod {:init! DbConnection}
  (lambda (self name leveldb)
    (def mx (make-mutex name)) ;; Mutex
    (def txcounter 0) ;; Nat
    (def hooks (make-hash-table)) ;; (Table (<-) <- Any)
    (def blocked-transactions []) ;; (List Transaction))
    (def open-transactions (make-hash-table)) ;; mutable (HashSet Transaction)
    (def pending-transactions []) ;; (List Transaction))
    (def batch-id 0) ;; Nat
    (def batch (leveldb-writebatch)) ;; leveldb-writebatch
    (def ready? #t)
    (def triggered? #f)
    (def manager (db-manager self))
    (def timer #f)
    (struct-instance-init!
     self name leveldb mx txcounter
     blocked-transactions open-transactions pending-transactions hooks
     batch-id batch manager timer
     ready? triggered?)))

(def current-db-connection (make-parameter #f))
(def (open-db-connection name (opts (leveldb-default-options)))
  (create-directory* (path-parent name))
  (DbConnection name (leveldb-open name opts)))
(def (open-db-connection! name (opts (leveldb-default-options)))
  (current-db-connection (open-db-connection name opts)))
(def (close-db-connection! c)
  (leveldb-close (DbConnection-leveldb c))
  (thread-send (DbConnection-manager c) #f))
(def (close-db-connection c)
  (with-db-lock (c)
    (register-commit-hook! 'close (lambda _ (close-db-connection! c)) c)
    (db-trigger! c))
  (thread-join! (DbConnection-manager c)))
(def (call-with-db-connection fun name (opts (leveldb-default-options)))
  (def c (open-db-connection name))
  (try
   (parameterize ((current-db-connection c))
     (fun c))
   (finally (close-db-connection c))))
(defrule (with-db-connection (c name ...) body ...)
  (call-with-db-connection (lambda (c) body ...) name ...))
(def (ensure-db-connection name)
  (def c (current-db-connection))
  (if c
    (assert! (equal? (DbConnection-name c) name))
    (open-db-connection! name)))

;; Mark the current batch as triggered, because either some transaction must be committed,
;; or a timer has hit since content was added, or we're closing the database.
;; ASSUMES YOU'RE HOLDING THE DB-LOCK
;; : <- DbConnection
(def (db-trigger! c)
  (if (and (DbConnection-ready? c) (zero? (hash-length (DbConnection-open-transactions c))))
    (finalize-batch! c)
    (set! (DbConnection-triggered? c) #t)))

;; : Real
(def deferred-db-trigger-interval-in-seconds .02)

;; ASSUMES YOU'RE HOLDING THE DB-LOCK
;; : <- DbConnection
(def (deferred-db-trigger! c)
  (unless (DbConnection-timer c)
    (let (batch-id (DbConnection-batch-id c))
      (set! (DbConnection-timer c)
        (spawn/name
         ['timer batch-id]
         (lambda () (thread-sleep! deferred-db-trigger-interval-in-seconds)
            (with-db-lock (c)
              (when (equal? batch-id (DbConnection-batch-id c))
                (db-trigger! c)))))))))

(defrules with-db-lock ()
  ((_ (conn) body ...) (with-lock (DbConnection-mx conn) (lambda () body ...)))
  ((_ () body ...) (with-db-lock (current-db-connection) body ...)))
(def (call-with-db-lock fun (conn (current-db-connection)))
  (with-db-lock (conn) (fun conn)))

;; status: blocked open pending complete
(defstruct DbTransaction (connection txid status completion) transparent: #t)
(def current-db-transaction (make-parameter #f))

;; Open Transaction
;; TODO: assert that the transaction_counter never wraps around?
;; Or check and block further transactions when it does, before resetting the counter? *)
;; TODO: commenting out the ready && triggered helps detect / enact deadlocks when running
;; tests, by having only one active transaction at a time; but then the hold can and
;; should be released as soon as "the" transaction is complete, unless we're already both
;; ready && triggered for the next batch commit. Have an option for that?
(def (open-transaction (c (current-db-connection)))
  (def completion (make-completion))
  (defvalues (transaction blocked?)
    (with-db-lock (c)
      (let* ((txid (pre-inc! (DbConnection-txcounter c)))
             (status (if (and (DbConnection-ready? c) (DbConnection-triggered? c)) 'blocked 'open))
             (transaction (DbTransaction c txid status completion)))
        (case status
          ((blocked)
           (push! transaction (DbConnection-blocked-transactions c))
           (values transaction #t))
          ((open)
           (hash-put! (DbConnection-open-transactions c) txid transaction)
           (values transaction #f))))))
  (when blocked? (completion-wait! completion)) ;; Wait without hold the lock
  transaction)
(def (call-with-new-tx fun (c #f))
  (def tx (open-transaction (or c (current-db-connection))))
  (try
   (parameterize ((current-db-transaction tx))
     (fun tx))
   (finally (commit-transaction tx))))
(def (call-with-tx fun (tx #f) (c #f))
  (def t (or tx (current-db-transaction)))
  (if t (fun t) (call-with-new-tx fun c)))
(defrule (with-tx (tx dbtx ...) body ...)
  (call-with-tx (lambda (tx) body ...) dbtx ...))
(defrule (with-new-tx (tx dbc ...) body ...)
  (call-with-new-tx (lambda (tx) body ...) dbc ...))
(defrule (after-commit (tx) body ...)
  (spawn (lambda () (completion-wait! (DbTransaction-completion tx)) body ...)))

;; Mark a transaction as ready to be committed.
;; Return a completion that will be posted when the transaction is committed to disk.
;; The system must otherwise ensure that the action that follows this promise
;; will be restarted by a new instance of this program in case the process crashes after this commit,
;; or is otherwise some client's responsibility to restart if the program acts as a server.
(def (close-transaction (tx (current-db-transaction)))
  (match tx
    ((DbTransaction c txid status completion)
     (case status
       ((blocked open)
        (set! (DbTransaction-status tx) 'pending)
        (with-db-lock (c)
          (hash-remove! (DbConnection-open-transactions c) txid)
          (push! tx (DbConnection-pending-transactions c))
          (deferred-db-trigger! c))))
     completion)
    (else (error "close-transaction: not a transaction" tx))))

;; Close a transaction, then wait for it to be committed.
(def (commit-transaction (transaction (current-db-transaction)))
  (completion-wait! (close-transaction transaction)))

;; Sync to a transaction being committed.
(def (sync-transaction (transaction (current-db-transaction)))
  (completion-wait! (DbTransaction-completion transaction)))

;; Register post-commit finalizer actions to be run after this batch commits,
;; with the batch id as a parameter.
;; The hook is called synchronously, but it if you use asynchronous message passing,
;; it is possible that the hooks may be called out of order.
;; ASSUMES YOU'RE HOLDING THE DB-LOCK
;; Unit <- Any (<- Nat) DbConnection
(def (register-commit-hook! name hook (c (current-db-connection)))
  (hash-put! (DbConnection-hooks c) name hook))

(def leveldb-sync-write-options (leveldb-write-options sync: #f))

(def (db-manager c)
  (spawn/name
   ['db-manager (DbConnection-name c)]
   (lambda ()
     (let loop ()
       (match (thread-receive)
         ([batch-id batch hooks pending-transactions]
          ;; TODO: run the leveldb-write in a different OS thread.
          (leveldb-write (DbConnection-leveldb c) batch leveldb-sync-write-options)
          (for-each (lambda (tx)
                      (set! (DbTransaction-status tx) 'complete)
                      (completion-post! (DbTransaction-completion tx) batch-id))
                    pending-transactions)
          (for-each (lambda (hook) (hook batch-id)) hooks)
          (with-db-lock (c)
            (if (and (DbConnection-triggered? c) (zero? (hash-length (DbConnection-open-transactions c))))
              (finalize-batch! c)
              (set! (DbConnection-ready? c) #t)))
          (loop))
         (#f (void))
         (x (error "foo" x)))))))

;; Fork a system thread to handle the commit;
;; when it's done, wakeup the wait-on-batch-commit completion
(def (finalize-batch! c)
  (def batch-id (DbConnection-batch-id c))
  (def batch (DbConnection-batch c))
  (def hooks (hash-values (DbConnection-hooks c)))
  (def blocked-transactions (DbConnection-blocked-transactions c))
  (def pending-transactions (DbConnection-pending-transactions c))
  (def new-batch-id (1+ batch-id))
  (set! (DbConnection-batch-id c) new-batch-id)
  (set! (DbConnection-batch c) (leveldb-writebatch))
  (set! (DbConnection-pending-transactions c) [])
  (set! (DbConnection-blocked-transactions c) [])
  (set! (DbConnection-ready? c) #f)
  (set! (DbConnection-triggered? c) #f)
  (set! (DbConnection-timer c) #f)
  (for-each (lambda (tx)
              (set! (DbTransaction-status tx) 'open)
              (hash-put! (DbConnection-open-transactions c) (DbTransaction-txid tx) tx)
              (completion-post! (DbTransaction-completion tx) new-batch-id)
              (set! (DbTransaction-completion tx) (make-completion)))
            blocked-transactions)
  (thread-send (DbConnection-manager c) [batch-id batch hooks pending-transactions]))

;; Get the batch id: not just for testing,
;; but also, within a transaction, to get the id to prepare a hook,
;; e.g. to send newly committed but previously unsent messages.
(def (get-batch-id (c (current-db-connection)))
  (DbConnection-batch-id c))

(def (db-get key (tx (current-db-transaction)) (opts (leveldb-default-read-options)))
  (leveldb-get (DbConnection-leveldb (DbTransaction-connection tx)) key opts))
(def (db-key? key (tx (current-db-transaction)) (opts (leveldb-default-read-options)))
  (leveldb-key? (DbConnection-leveldb (DbTransaction-connection tx)) key opts))

(def (db-put! k v (tx (current-db-transaction)))
  (def c (DbTransaction-connection tx))
  (with-db-lock (c)
    (leveldb-writebatch-put (DbConnection-batch c) k v)))
(def (db-put-many! l (tx (current-db-transaction)))
  (def c (DbTransaction-connection tx))
  (with-db-lock (c)
    (let (batch (DbConnection-batch c))
      (for-each (match <> ([k . v] (leveldb-writebatch-put batch k v))) l))))
(def (db-delete! k (tx (current-db-transaction)))
  (def c (DbTransaction-connection tx))
  (with-db-lock (c)
    (leveldb-writebatch-delete (DbConnection-batch c) k)))

#;(trace! current-db-connection current-db-transaction
        open-db-connection open-db-connection!
        close-db-connection! close-db-connection call-with-db-connection
        db-trigger! call-with-db-lock
        open-transaction call-with-new-tx call-with-tx close-transaction
        commit-transaction register-commit-hook! db-manager finalize-batch!
        get-batch-id db-get db-key? db-put! db-put-many! db-delete!)