; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.remote
  "Git remote helper for Amazon S3.

  Implements the git remote-helper protocol by reading commands from stdin
  and replying on stdout.  Mirrors git_remote_s3/remote.py."
  (:gen-class)
  (:require [clojure.string         :as str]
            [clojure.tools.logging  :as log]
            [git-remote-s3.enums    :as enums]
            [git-remote-s3.common   :refer [parse-git-url]]
            [git-remote-s3.git      :as git])
  (:import [java.io File IOException PrintWriter]
           [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]
           [java.util.concurrent ExecutorService Executors Future]
           [java.util.concurrent.locks ReentrantLock]
           [software.amazon.awssdk.auth.credentials
            ProfileCredentialsProvider
            DefaultCredentialsProvider]
           [software.amazon.awssdk.regions Region]
           [software.amazon.awssdk.services.s3 S3Client]
           [software.amazon.awssdk.services.s3.model
            HeadObjectRequest
            HeadObjectResponse
            ListObjectsV2Request
            ListObjectsV2Response
            S3Object
            GetObjectRequest
            PutObjectRequest
            DeleteObjectRequest
            NoSuchKeyException
            S3Exception]
           [software.amazon.awssdk.core.sync RequestBody]
           [software.amazon.awssdk.transfer.s3 S3TransferManager]
           [software.amazon.awssdk.transfer.s3.model
            DownloadFileRequest
            UploadFileRequest]))

;; ---------------------------------------------------------------------------
;; Constants
;; ---------------------------------------------------------------------------

(def default-lock-ttl-seconds 60)

;; ---------------------------------------------------------------------------
;; Custom exceptions (data-only, conveyed through ex-info)
;; ---------------------------------------------------------------------------

(defn bucket-not-found-error [bucket]
  (ex-info (str "Bucket " bucket " not found.")
           {:type :bucket-not-found :bucket bucket}))

(defn not-authorized-error [action bucket]
  (ex-info (str "Not authorized to perform " action " on the S3 bucket " bucket ".")
           {:type :not-authorized :action action :bucket bucket}))

;; ---------------------------------------------------------------------------
;; Mode constants
;; ---------------------------------------------------------------------------

(def mode-fetch "fetch")
(def mode-push  "push")

;; ---------------------------------------------------------------------------
;; S3 client helpers
;; ---------------------------------------------------------------------------

(defn- build-s3-client
  "Creates an AWS SDK v2 S3Client, optionally using a named profile."
  [profile]
  (let [creds (if profile
                (-> (ProfileCredentialsProvider/builder)
                    (.profileName profile)
                    (.build))
                (DefaultCredentialsProvider/create))
        builder (-> (S3Client/builder)
                    (.credentialsProvider creds))]
    (.build builder)))

;; ---------------------------------------------------------------------------
;; S3Remote record
;; ---------------------------------------------------------------------------

(defrecord S3Remote
  [uri-scheme
   profile
   bucket
   prefix
   ^S3Client s3
   ;; Mutable state stored in atoms
   mode-atom         ; atom<String|nil>  – current protocol mode
   fetched-refs-atom ; atom<set<String>> – SHAs already fetched
   push-cmds-atom    ; atom<vec<String>>
   fetch-cmds-atom   ; atom<vec<String>>
   lock-ttl-seconds  ; long
   ^ReentrantLock fetched-refs-lock])

(defn make-s3-remote
  "Constructs and validates an S3Remote.  Throws on bucket/auth errors."
  [uri-scheme profile bucket prefix]
  (let [s3 (build-s3-client profile)]
    ;; Probe the bucket immediately (mirrors Python __init__)
    (try
      (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                              (.bucket bucket)
                              (.prefix prefix)
                              (.build)))
      (catch S3Exception e
        (let [code (-> e .awsErrorDetails .errorCode)]
          (cond
            (= code "NoSuchBucket")
            (throw (bucket-not-found-error bucket))
            (= code "AccessDenied")
            (throw (not-authorized-error "ListObjectsV2" bucket))
            :else (throw e)))))
    (let [ttl (try
                (Long/parseLong
                 (or (System/getenv "GIT_REMOTE_S3_LOCK_TTL_SECONDS") ""))
                (catch Exception _ default-lock-ttl-seconds))]
      (->S3Remote uri-scheme profile bucket prefix s3
                  (atom nil)
                  (atom #{})
                  (atom [])
                  (atom [])
                  ttl
                  (ReentrantLock.)))))

;; ---------------------------------------------------------------------------
;; list-refs
;; ---------------------------------------------------------------------------

(defn list-refs
  "Lists all bundle keys under `prefix`, sorted newest-first.
  Returns a sequence of key strings with the `prefix/` portion stripped."
  [{:keys [^S3Client s3 bucket prefix] :as _remote} & {:keys [bucket-ov prefix-ov]
                                                         :or   {}}]
  (let [bkt (or bucket-ov bucket)
        pfx (or prefix-ov prefix)]
    (loop [continuation-token nil
           acc []]
      (let [req-b (-> (ListObjectsV2Request/builder)
                      (.bucket bkt)
                      (.prefix pfx))
            req-b (if continuation-token
                    (.continuationToken req-b continuation-token)
                    req-b)
            ^ListObjectsV2Response resp (.listObjectsV2 s3 (.build req-b))
            contents (into acc (.contents resp))
            next-tok (when (.isTruncated resp) (.nextContinuationToken resp))]
        (if next-tok
          (recur next-tok contents)
          ;; Sort by LastModified descending
          (let [sorted (->> contents
                            (sort-by #(-> ^S3Object % .lastModified .toEpochMilli))
                            reverse)]
            (->> sorted
                 (filter (fn [^S3Object o]
                           (and (str/starts-with? (.key o) (str pfx "/refs"))
                                (str/ends-with?   (.key o) ".bundle"))))
                 (mapv (fn [^S3Object o]
                         (subs (.key o) (inc (count pfx))))))))))))

;; ---------------------------------------------------------------------------
;; fetch
;; ---------------------------------------------------------------------------

(defn cmd-fetch
  "Downloads and unbundles one ref identified by sha and ref.
  Thread-safe: skips if sha was already fetched."
  [{:keys [^S3Client s3 bucket prefix
           fetched-refs-atom ^ReentrantLock fetched-refs-lock] :as remote}
   args]
  (let [[_ sha ref] (str/split (str/trim args) #"\s+" 3)]
    ;; Check if already fetched (lock-protected read)
    (.lock fetched-refs-lock)
    (let [already? (contains? @fetched-refs-atom sha)]
      (.unlock fetched-refs-lock)
      (when-not already?
        (log/info "fetch" sha ref)
        (let [temp-dir (-> (Files/createTempDirectory
                            "git_remote_s3_fetch_"
                            (make-array FileAttribute 0))
                           .toFile
                           .getAbsolutePath)
              bundle-path (str temp-dir "/" sha ".bundle")]
          (try
            ;; Download using SDK v2 transfer manager (multipart-aware)
            (let [^S3TransferManager tm
                  (-> (S3TransferManager/builder)
                      (.s3Client s3)
                      (.build))
                  req (-> (DownloadFileRequest/builder)
                          (.getObjectRequest
                           (-> (GetObjectRequest/builder)
                               (.bucket bucket)
                               (.key (str prefix "/" ref "/" sha ".bundle"))
                               (.build)))
                          (.destination (File. bundle-path))
                          (.build))]
              (-> tm (.downloadFile req) .completionFuture .join)
              (.close tm))
            (log/info "fetched" bundle-path ref)
            (git/unbundle :folder temp-dir :sha sha :ref ref)
            (.lock fetched-refs-lock)
            (swap! fetched-refs-atom conj sha)
            (.unlock fetched-refs-lock)
            (catch S3Exception e
              (let [code (-> e .awsErrorDetails .errorCode)]
                (if (= code "AccessDenied")
                  (throw (not-authorized-error "GetObject" bucket))
                  (throw e))))
            (finally
              (let [f (File. bundle-path)]
                (when (.exists f) (.delete f))))))))))

;; ---------------------------------------------------------------------------
;; Parallel fetch
;; ---------------------------------------------------------------------------

(defn process-fetch-cmds
  "Processes a batch of fetch commands in parallel using a thread pool."
  [remote cmds]
  (when (seq cmds)
    (log/info "Processing" (count cmds) "fetch commands in parallel")
    (let [^ExecutorService pool (Executors/newCachedThreadPool)
          futures (mapv (fn [cmd]
                          (.submit pool ^Callable #(cmd-fetch remote cmd)))
                        cmds)]
      (doseq [^Future f futures] (.get f))
      (.shutdown pool))
    (log/info "Completed" (count cmds) "fetch commands")))

;; ---------------------------------------------------------------------------
;; push helpers
;; ---------------------------------------------------------------------------

(defn- get-bundles-for-ref
  "Lists all bundle objects for `remote-ref` (excludes PROTECTED#, .zip, LOCKS/, .lock)."
  [{:keys [^S3Client s3 bucket prefix]} remote-ref]
  (let [pfx (str prefix "/" remote-ref "/")
        ^ListObjectsV2Response resp
        (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                                (.bucket bucket)
                                (.prefix pfx)
                                (.build)))]
    (->> (.contents resp)
         (filterv (fn [^S3Object o]
                    (let [k (.key o)]
                      (and (not (str/includes? k "PROTECTED#"))
                           (not (str/ends-with?  k ".zip"))
                           (not (str/includes? k "/LOCKS/"))
                           (not (str/ends-with?  k ".lock")))))))))

(defn- is-protected?
  [{:keys [^S3Client s3 bucket prefix]} remote-ref]
  (let [pfx (str prefix "/" remote-ref "/PROTECTED#")
        ^ListObjectsV2Response resp
        (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                                (.bucket bucket)
                                (.prefix pfx)
                                (.build)))]
    (seq (.contents resp))))

(defn- init-remote-head
  "Creates the remote HEAD object if it does not already exist."
  [{:keys [^S3Client s3 bucket prefix]} ref]
  (try
    (.headObject s3 (-> (HeadObjectRequest/builder)
                         (.bucket bucket)
                         (.key (str prefix "/HEAD"))
                         (.build)))
    (catch S3Exception _
      ;; HEAD does not exist — create it
      (.putObject s3
                  (-> (PutObjectRequest/builder)
                      (.bucket bucket)
                      (.key (str prefix "/HEAD"))
                      (.build))
                  (RequestBody/fromString ref)))))

;; ---------------------------------------------------------------------------
;; Locking
;; ---------------------------------------------------------------------------

(defn- acquire-lock
  "Acquires a per-ref S3 lock using conditional put (IfNoneMatch=*).
  Returns the lock key string on success, or nil on failure."
  [{:keys [^S3Client s3 bucket prefix lock-ttl-seconds]} remote-ref]
  (let [lock-key (str prefix "/" remote-ref "/LOCK#.lock")]
    (try
      (.putObject s3
                  (-> (PutObjectRequest/builder)
                      (.bucket bucket)
                      (.key lock-key)
                      (.ifNoneMatch "*")
                      (.build))
                  (RequestBody/empty))
      lock-key
      (catch S3Exception e
        (let [status (-> e .statusCode)]
          (if (= 412 status)
            ;; Lock exists — check if stale
            (try
              (let [^HeadObjectResponse head
                    (.headObject s3 (-> (HeadObjectRequest/builder)
                                        (.bucket bucket)
                                        (.key lock-key)
                                        (.build)))
                    last-mod  (.lastModified head)
                    now       (java.time.Instant/now)
                    age-secs  (- (.getEpochSecond now) (.getEpochSecond last-mod))]
                (if (> age-secs lock-ttl-seconds)
                  ;; Stale — delete and retry
                  (do
                    (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                          (.bucket bucket)
                                          (.key lock-key)
                                          (.build)))
                    (.putObject s3
                                (-> (PutObjectRequest/builder)
                                    (.bucket bucket)
                                    (.key lock-key)
                                    (.ifNoneMatch "*")
                                    (.build))
                                (RequestBody/empty))
                    lock-key)
                  nil))
              (catch S3Exception inner
                (log/info "failed to check staleness of" lock-key ":" inner)
                (throw inner)))
            (throw e)))))))

(defn- release-lock
  "Deletes the lock object."
  [{:keys [^S3Client s3 bucket]} lock-key]
  (try
    (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                           (.bucket bucket)
                           (.key lock-key)
                           (.build)))
    (catch S3Exception e
      (when (not= 404 (.statusCode e))
        (throw e)))))

;; ---------------------------------------------------------------------------
;; remove-remote-ref
;; ---------------------------------------------------------------------------

(defn- remove-remote-ref
  [{:keys [^S3Client s3 bucket prefix uri-scheme] :as remote} remote-ref]
  (log/info "Removing remote ref" remote-ref)
  (try
    (let [pfx (str prefix "/" remote-ref "/")
          ^ListObjectsV2Response resp
          (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                                  (.bucket bucket)
                                  (.prefix pfx)
                                  (.build)))
          objs (.contents resp)
          cnt  (count objs)
          expected (cond
                     (= uri-scheme enums/uri-scheme-s3)    1
                     (= uri-scheme enums/uri-scheme-s3zip) 2
                     :else 1)]
      (cond
        (and (= cnt expected))
        (do
          (doseq [^S3Object o objs]
            (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                   (.bucket bucket)
                                   (.key (.key o))
                                   (.build))))
          (str "ok " remote-ref "\n"))

        (zero? cnt)
        (str "error " remote-ref " not found\n")

        :else
        (str "error " remote-ref
             " \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n")))
    (catch S3Exception e
      (if (= 404 (.statusCode e))
        (str "error " remote-ref " not found\n")
        (throw e)))))

;; ---------------------------------------------------------------------------
;; cmd-push
;; ---------------------------------------------------------------------------

(defn cmd-push
  "Processes a single push command string.  Returns the response string."
  [{:keys [^S3Client s3 bucket prefix uri-scheme] :as remote} args]
  (let [ref-pair  (nth (str/split (str/trim args) #"\s+") 1)
        [local-ref remote-ref] (str/split ref-pair #":" 2)]
    (if (str/blank? local-ref)
      ;; Delete remote ref
      (remove-remote-ref remote remote-ref)
      (let [force-push? (atom false)
            local-ref   (if (str/starts-with? local-ref "+")
                          (do
                            (reset! force-push? (not (is-protected? remote remote-ref)))
                            (log/info "Force push" @force-push?)
                            (subs local-ref 1))
                          local-ref)]
        (log/info "push !" local-ref "! !" remote-ref "!")
        (let [temp-dir (-> (Files/createTempDirectory
                            "git_remote_s3_push_"
                            (make-array FileAttribute 0))
                           .toFile
                           .getAbsolutePath)
              contents (get-bundles-for-ref remote remote-ref)]
          (if (> (count contents) 1)
            (str "error " remote-ref
                 " \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n")
            (let [remote-to-remove (when (= 1 (count contents))
                                     (.key ^S3Object (first contents)))
                  sha-atom     (atom nil)
                  lock-key-atom (atom nil)]
              (try
                (let [sha (git/rev-parse local-ref)]
                  (reset! sha-atom sha)
                  ;; Ancestry check
                  (when remote-to-remove
                    (let [remote-sha (-> remote-to-remove
                                         (str/split #"/")
                                         last
                                         (str/split #"\.")
                                         first)]
                      (when (and (not @force-push?)
                                 (not (git/is-ancestor remote-sha sha)))
                        (throw (ex-info "not-ancestor" {:type :not-ancestor
                                                         :remote-ref remote-ref})))))
                  ;; Bundle locally before acquiring the lock
                  (let [temp-file (git/bundle :folder temp-dir :sha sha :ref local-ref)
                        lock-key  (acquire-lock remote remote-ref)]
                    (reset! lock-key-atom lock-key)
                    (when-not lock-key
                      (let [lock-path (str prefix "/" remote-ref "/LOCK#.lock")]
                        (throw (ex-info "lock-failed"
                                        {:type       :lock-failed
                                         :remote-ref remote-ref
                                         :lock-path  lock-path}))))
                    ;; Re-check for multiple bundles after lock
                    (let [current-contents (get-bundles-for-ref remote remote-ref)]
                      (when (> (count current-contents) 1)
                        (throw (ex-info "multiple-bundles-post-lock"
                                        {:type :multiple-bundles-post-lock
                                         :remote-ref remote-ref})))
                      (let [current-remote-to-remove
                            (when (= 1 (count current-contents))
                              (.key ^S3Object (first current-contents)))]
                        ;; Stale remote check
                        (when (and remote-to-remove
                                   current-remote-to-remove
                                   (not= current-remote-to-remove remote-to-remove))
                          (throw (ex-info "stale-remote"
                                          {:type :stale-remote :remote-ref remote-ref})))
                        ;; Upload bundle
                        (.putObject s3
                                    (-> (PutObjectRequest/builder)
                                        (.bucket bucket)
                                        (.key (str prefix "/" remote-ref "/" sha ".bundle"))
                                        (.build))
                                    (RequestBody/fromFile (File. temp-file)))
                        (init-remote-head remote remote-ref)
                        (log/info "pushed" temp-file "to" remote-ref)
                        ;; Delete old bundle
                        (when remote-to-remove
                          (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                                 (.bucket bucket)
                                                 (.key remote-to-remove)
                                                 (.build))))
                        ;; S3+zip: also push archive
                        (when (= uri-scheme enums/uri-scheme-s3zip)
                          (let [commit-msg    (git/get-last-commit-message)
                                archive-file  (git/archive :folder temp-dir :ref local-ref)]
                            (.putObject s3
                                        (-> (PutObjectRequest/builder)
                                            (.bucket bucket)
                                            (.key (str prefix "/" remote-ref "/repo.zip"))
                                            (.contentDisposition
                                             (str "attachment; filename=repo-"
                                                  (subs sha 0 8) ".zip"))
                                            (.metadata
                                             {"codepipeline-artifact-revision-summary"
                                              commit-msg})
                                            (.build))
                                        (RequestBody/fromFile (File. archive-file)))
                            (log/info "pushed archive to" remote-ref "/repo.zip")))
                        (str "ok " remote-ref "\n")))))
                (catch clojure.lang.ExceptionInfo e
                  (let [t (:type (ex-data e))]
                    (cond
                      (= t :not-ancestor)
                      (str "error " remote-ref
                           " \"remote ref is not ancestor of " local-ref ".\"?\n")
                      (= t :lock-failed)
                      (str "error " remote-ref
                           " \"failed to acquire ref lock at "
                           (:lock-path (ex-data e))
                           ". Another client may be pushing. If this persists beyond "
                           (:lock-ttl-seconds remote default-lock-ttl-seconds)
                           "s, run git-remote-s3 doctor --lock-ttl "
                           (:lock-ttl-seconds remote default-lock-ttl-seconds)
                           " to inspect and optionally clear stale locks.\"?\n")
                      (= t :multiple-bundles-post-lock)
                      (str "error " remote-ref
                           " \"multiple bundles exists for the same ref on server."
                           " Run git-s3 doctor to fix."
                           " Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n")
                      (= t :stale-remote)
                      (str "error " remote-ref " \"stale remote. Please fetch and retry.\"?\n")
                      :else
                      (str "error " remote-ref " \"" (.getMessage e) "\"?\n"))))
                (catch Exception e
                  (if (git/git-error? e)
                    (do
                      (log/info "fatal:" local-ref "not found")
                      (str "error " remote-ref " \"" local-ref " not found\"?\n"))
                    (do
                      (log/info "fatal:" e)
                      (str "error " remote-ref " \"" (.getMessage e) "\"?\n"))))
                (finally
                  ;; Release lock
                  (when @lock-key-atom
                    (try
                      (release-lock remote @lock-key-atom)
                      (catch Exception e
                        (log/info "failed to release lock" @lock-key-atom ":" e))))
                  ;; Clean up temp bundle
                  (when @sha-atom
                    (let [f (File. (str temp-dir "/" @sha-atom ".bundle"))]
                      (when (.exists f) (.delete f)))))))))))))

;; ---------------------------------------------------------------------------
;; cmd-list
;; ---------------------------------------------------------------------------

(defn- get-remote-head
  [{:keys [^S3Client s3 bucket prefix]}]
  (let [^software.amazon.awssdk.core.ResponseInputStream body
        (.getObjectAsBytes s3 (-> (GetObjectRequest/builder)
                                   (.bucket bucket)
                                   (.key (str prefix "/HEAD"))
                                   (.build)))]
    (str/trim (String. (.asByteArray body) "UTF-8"))))

(defn cmd-list
  "Writes the list of remote refs to stdout."
  [{:keys [bucket prefix] :as remote} & {:keys [for-push?] :or {for-push? false}}]
  (let [objs (list-refs remote :bucket-ov bucket :prefix-ov prefix)]
    (log/info objs)
    (when-not for-push?
      (try
        (let [head (get-remote-head remote)]
          (log/info (str "HEAD=[" head "]"))
          (doseq [o objs]
            (let [ref (str/join "/" (butlast (str/split o #"/")))]
              (when (= ref head)
                (log/info (str "@" ref " HEAD"))
                (print (str "@" ref " HEAD\n"))))))
        (catch S3Exception e
          (when (not= "NoSuchKey" (-> e .awsErrorDetails .errorCode))
            (throw e)))))
    ;; List refs: only lines matching .+/.+/.+/<40-hex-sha>.bundle
    (let [sha-pattern (re-pattern ".+/.+/.+/[a-f0-9]{40}\\.bundle")]
      (doseq [o (filter #(re-matches sha-pattern %) objs)]
        (let [elements (str/split o #"/")
              sha      (first (str/split (last elements) #"\."))
              ref      (str/join "/" (butlast elements))]
          (print (str sha " " ref "\n")))))
    (print "\n")
    (flush)))

;; ---------------------------------------------------------------------------
;; cmd-option
;; ---------------------------------------------------------------------------

(defn cmd-option
  [args]
  (let [parts  (str/split (str/trim args) #"\s+")
        option (nth parts 1)
        value  (nth parts 2 nil)]
    (if (and (= option "verbosity") value (>= (Long/parseLong value) 2))
      (do
        (.setLevel (org.apache.logging.log4j.LogManager/getRootLogger)
                   org.apache.logging.log4j.Level/INFO)
        (print "ok\n"))
      (print "unsupported\n"))
    (flush)))

;; ---------------------------------------------------------------------------
;; cmd-capabilities
;; ---------------------------------------------------------------------------

(defn cmd-capabilities []
  (print "*push\n")
  (print "*fetch\n")
  (print "option\n")
  (print "\n")
  (flush))

;; ---------------------------------------------------------------------------
;; process-cmd  (dispatch)
;; ---------------------------------------------------------------------------

(defn process-cmd
  "Dispatches one line of the git remote-helper protocol."
  [{:keys [mode-atom push-cmds-atom fetch-cmds-atom] :as remote} cmd]
  (cond
    (str/starts-with? cmd "fetch")
    (do
      (when (not= @mode-atom mode-fetch)
        (reset! mode-atom mode-fetch)
        (reset! fetch-cmds-atom []))
      (swap! fetch-cmds-atom conj (str/trim cmd)))

    (str/starts-with? cmd "push")
    (do
      (when (not= @mode-atom mode-push)
        (reset! mode-atom mode-push)
        (reset! push-cmds-atom []))
      (swap! push-cmds-atom conj (str/trim cmd)))

    (str/starts-with? cmd "option")
    (cmd-option (str/trim cmd))

    (= (str/trim cmd) "list for-push")
    (cmd-list remote :for-push? true)

    (str/starts-with? cmd "list")
    (cmd-list remote)

    (str/starts-with? cmd "capabilities")
    (cmd-capabilities)

    (= cmd "\n")
    (do
      (log/info "empty line")
      (cond
        (and (= @mode-atom mode-push) (seq @push-cmds-atom))
        (let [cmds @push-cmds-atom]
          (log/info "pushing" cmds)
          (doseq [c cmds]
            (print (cmd-push remote c)))
          (reset! push-cmds-atom []))

        (and (= @mode-atom mode-fetch) (seq @fetch-cmds-atom))
        (let [cmds @fetch-cmds-atom]
          (log/info "fetching" (count cmds) "refs in parallel")
          (process-fetch-cmds remote cmds)
          (reset! fetch-cmds-atom [])))
      (print "\n")
      (flush))

    :else
    (do
      (binding [*out* *err*]
        (println (str "fatal: invalid command '" cmd "'")))
      (System/exit 1))))

;; ---------------------------------------------------------------------------
;; main
;; ---------------------------------------------------------------------------

(defn -main [& args]
  (log/info args)
  ;; argv[2] is the remote URL (git passes: helper-name <remote-name> <url>)
  (let [remote-url (nth (vec args) 1 nil)
        {:keys [uri-scheme profile bucket prefix]} (parse-git-url remote-url)]
    (when (or (nil? bucket) (nil? prefix))
      (binding [*out* *err*]
        (println (str "fatal: invalid remote '" remote-url
                      "'. You need to have a bucket and a prefix.")))
      (System/exit 1))
    (try
      (let [s3remote (make-s3-remote uri-scheme profile bucket prefix)]
        (loop []
          (let [line (read-line)]
            (when line
              (log/info "cmd:" line)
              (process-cmd s3remote line)
              (recur)))))
      (catch IOException e
        ;; Broken pipe
        (when (str/includes? (.getMessage e) "Broken pipe")
          (log/info "BrokenPipeError")
          (System/exit 0))
        (throw e))
      (catch clojure.lang.ExceptionInfo e
        (let [t (:type (ex-data e))]
          (cond
            (= t :bucket-not-found)
            (do (binding [*out* *err*]
                  (println (str "fatal: bucket not found " (:bucket (ex-data e)))))
                (System/exit 1))
            (= t :not-authorized)
            (do (binding [*out* *err*]
                  (println (str "fatal: user not authorized to perform "
                                (:action (ex-data e)) " on " (:bucket (ex-data e)))))
                (System/exit 1))
            :else (throw e))))
      (catch S3Exception e
        (binding [*out* *err*]
          (println (str "fatal: invalid credentials " e)))
        (System/exit 1))
      (catch Exception e
        (log/info e)
        (binding [*out* *err*]
          (println "fatal: unknown error. Run with --verbose flag to get full log"))
        (System/exit 1)))))
