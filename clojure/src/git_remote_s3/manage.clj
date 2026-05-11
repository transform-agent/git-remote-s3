; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.manage
  "Management commands for git-remote-s3 (doctor, delete-branch, protect, unprotect).
   Mirrors git_remote_s3/manage.py."
  (:gen-class)
  (:require [clojure.string        :as str]
            [clojure.tools.cli     :as cli]
            [clojure.tools.logging :as log]
            [git-remote-s3.common  :refer [parse-git-url]]
            [git-remote-s3.git     :as git :refer [get-remote-url]]
            [git-remote-s3.remote  :refer [default-lock-ttl-seconds]])
  (:import [java.time Instant ZoneOffset]
           [software.amazon.awssdk.auth.credentials
            ProfileCredentialsProvider
            DefaultCredentialsProvider]
           [software.amazon.awssdk.services.s3 S3Client]
           [software.amazon.awssdk.services.s3.model
            ListObjectsV2Request
            GetObjectRequest
            PutObjectRequest
            DeleteObjectRequest
            CopyObjectRequest
            S3Object
            S3Exception]
           [software.amazon.awssdk.core.sync RequestBody]))

;; ---------------------------------------------------------------------------
;; S3 client factory
;; ---------------------------------------------------------------------------

(defn- build-s3-client [profile]
  (let [creds (if profile
                (-> (ProfileCredentialsProvider/builder)
                    (.profileName profile)
                    (.build))
                (DefaultCredentialsProvider/create))]
    (-> (S3Client/builder)
        (.credentialsProvider creds)
        (.build))))

;; ---------------------------------------------------------------------------
;; Doctor record
;; ---------------------------------------------------------------------------

(defrecord Doctor
  [bucket prefix delete-bundle? ^S3Client s3
   lock-ttl-seconds delete-stale-locks?])

(defn make-doctor
  [profile bucket prefix delete-bundle?
   lock-ttl-seconds delete-stale-locks?]
  (->Doctor bucket prefix delete-bundle?
            (build-s3-client profile)
            lock-ttl-seconds delete-stale-locks?))

;; ---------------------------------------------------------------------------
;; analyze-repo
;; ---------------------------------------------------------------------------

(defn- analyze-repo
  [{:keys [^S3Client s3 bucket prefix]}]
  (let [^java.util.List contents
        (-> (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                                    (.bucket bucket)
                                    (.prefix (str prefix "/"))
                                    (.build)))
            .contents)]
    (reduce
     (fn [repos ^S3Object obj]
       (let [key        (.key obj)
             key-parts  (str/split key #"/")
             repo-name  (first key-parts)
             repos      (if (contains? repos repo-name)
                          repos
                          (assoc repos repo-name {:refs {} :head "Missing"}))]
         (let [ref (str/join "/" (subvec key-parts 1 (dec (count key-parts))))]
           (cond
             ;; HEAD object
             (= (second key-parts) "HEAD")
             (let [head-ref (-> (.getObjectAsBytes s3
                                                   (-> (GetObjectRequest/builder)
                                                       (.bucket bucket)
                                                       (.key key)
                                                       (.build)))
                                .asByteArray
                                (String. "UTF-8")
                                str/trim)]
               (assoc-in repos [repo-name :head] head-ref))

             ;; PROTECTED marker
             (= "PROTECTED#" (last key-parts))
             (assoc-in repos [repo-name :refs ref :protected?] true)

             ;; Bundle file
             :else
             (let [sha (first (str/split (last key-parts) #"\."))
                   bundle {:sha sha :last-modified (.lastModified obj)}]
               (update-in repos [repo-name :refs ref :bundles]
                          (fnil conj []) bundle))))))
     {}
     contents)))

;; ---------------------------------------------------------------------------
;; list-and-handle-stale-locks
;; ---------------------------------------------------------------------------

(defn- list-and-handle-stale-locks
  [{:keys [^S3Client s3 bucket prefix lock-ttl-seconds delete-stale-locks?]}]
  (println "\nScanning for stale locks...")
  (let [^java.util.List contents
        (-> (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                                    (.bucket bucket)
                                    (.prefix (str prefix "/"))
                                    (.build)))
            .contents)
        now     (Instant/now)
        stale   (->> contents
                     (filter (fn [^S3Object o]
                               (str/ends-with? (.key o) ".lock")))
                     (keep (fn [^S3Object o]
                              (let [lm  (.lastModified o)
                                    age (- (.getEpochSecond now) (.getEpochSecond lm))]
                                (when (> age lock-ttl-seconds)
                                  [(.key o) (long age)])))))]
    (if (empty? stale)
      (println "No stale locks found.")
      (do
        (println "Found stale locks:")
        (doseq [[k age] stale]
          (println (str " - " k " (age: " age "s)")))
        (if delete-stale-locks?
          (do
            (println "\nDeleting stale locks...")
            (doseq [[k _] stale]
              (try
                (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                       (.bucket bucket)
                                       (.key k)
                                       (.build)))
                (println (str "Deleted " k))
                (catch S3Exception e
                  (println (str "Failed to delete " k ": " e))))))
          (println "\nRun with --delete-stale-locks to remove them automatically."))))))

;; ---------------------------------------------------------------------------
;; fix-multiple-bundles / fix-head
;; ---------------------------------------------------------------------------

(defn- fix-multiple-bundles
  [{:keys [^S3Client s3 bucket prefix delete-bundle?] :as doctor}
   repos r ref]
  (println (str "\nFix multiple bundles for repo " r " and ref " ref))
  (let [bundles (get-in repos [r :refs ref :bundles])]
    (doseq [[i {:keys [sha last-modified]}] (map-indexed vector bundles)]
      (println (str (inc i) ". " sha " " last-modified)))
    (loop []
      (print "Enter the number of the bundle to keep: ")
      (flush)
      (let [input (str/trim (or (read-line) ""))]
        (if-let [i (try (Long/parseLong input) (catch Exception _ nil))]
          (if (and (> i 0) (<= i (count bundles)))
            (let [sha-to-keep (:sha (nth bundles (dec i)))]
              (println (str "Keeping " sha-to-keep))
              (print "Press enter to confirm or Ctrl+C to cancel")
              (flush)
              (read-line)
              (doseq [{:keys [sha]} bundles]
                (when (not= sha sha-to-keep)
                  (if delete-bundle?
                    (do
                      (println (str "Removing " sha))
                      (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                             (.bucket bucket)
                                             (.key (str prefix "/" ref "/" sha ".bundle"))
                                             (.build))))
                    (let [tmp-branch (str ref "_" (subs (str (java.util.UUID/randomUUID)) 0 8))]
                      (println (str "Moving " sha " to new branch " tmp-branch))
                      (.copyObject s3 (-> (CopyObjectRequest/builder)
                                           (.sourceBucket bucket)
                                           (.sourceKey (str prefix "/" ref "/" sha ".bundle"))
                                           (.destinationBucket bucket)
                                           (.destinationKey (str prefix "/" tmp-branch "/" sha ".bundle"))
                                           (.build)))
                      (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                             (.bucket bucket)
                                             (.key (str prefix "/" ref "/" sha ".bundle"))
                                             (.build))))))))
          (do (println "Invalid input") (recur)))
        (do (println "Invalid input") (recur))))))

(defn- fix-head
  [{:keys [^S3Client s3 bucket prefix]} repos r]
  (println (str "\nFix invalid HEAD for repo " r))
  (let [heads (->> (keys (get-in repos [r :refs]))
                   (filter #(str/includes? % "heads"))
                   vec)]
    (doseq [[i head] (map-indexed vector heads)]
      (println (str (inc i) ". " (last (str/split head #"/")))))
    (loop []
      (print "Enter the number of the branch to use as head: ")
      (flush)
      (let [input (str/trim (or (read-line) ""))]
        (if-let [i (try (Long/parseLong input) (catch Exception _ nil))]
          (if (and (> i 0) (<= i (count heads)))
            (let [head (nth heads (dec i))]
              (println (str "Setting " head " as HEAD"))
              (.putObject s3 (-> (PutObjectRequest/builder)
                                  (.bucket bucket)
                                  (.key (str prefix "/HEAD"))
                                  (.build))
                          (RequestBody/fromString head)))
            (do (println "Invalid input") (recur)))
          (do (println "Invalid input") (recur)))))))

;; ---------------------------------------------------------------------------
;; fix-issues / run
;; ---------------------------------------------------------------------------

(defn- fix-issues
  [doctor repos]
  (doseq [r (keys repos)]
    (doseq [ref (keys (get-in repos [r :refs]))]
      (when (> (count (get-in repos [r :refs ref :bundles])) 1)
        (fix-multiple-bundles doctor repos r ref)))
    (when (= (get-in repos [r :head]) "Invalid")
      (fix-head doctor repos r)))
  (list-and-handle-stale-locks doctor))

(defn doctor-run
  [{:keys [] :as doctor}]
  (let [repos (analyze-repo doctor)]
    (doseq [r (keys repos)]
      (println (str r ":"))
      (let [head-ref (atom "Invalid")]
        (doseq [ref (keys (get-in repos [r :refs]))]
          (when (= (get-in repos [r :head]) ref)
            (reset! head-ref ref))
          (let [ref-value (get-in repos [r :refs ref])
                part-1    (if (:protected? ref-value) "*" "")
                part-2    (if (= 1 (count (:bundles ref-value))) "Ok" "Multiple refs")]
            (println (str " " part-1 " " ref ": " part-2))))
        (when (= @head-ref "Invalid")
          (assoc-in repos [r :head] "Invalid"))
        (println (str "  HEAD: " @head-ref))))
    (fix-issues doctor repos)))

;; ---------------------------------------------------------------------------
;; ManageBranch record
;; ---------------------------------------------------------------------------

(defrecord ManageBranch [bucket prefix branch ^S3Client s3])

(defn make-manage-branch
  [profile bucket prefix branch]
  (let [s3  (build-s3-client profile)
        obj (->ManageBranch bucket prefix branch s3)
        objs (-> (.listObjectsV2 s3
                                 (-> (ListObjectsV2Request/builder)
                                     (.bucket bucket)
                                     (.prefix (str prefix "/refs/heads/" branch "/"))
                                     (.build)))
                 .contents)]
    (when (empty? objs)
      (throw (ex-info (str "Branch " branch " does not exist")
                      {:type :branch-not-found :branch branch})))
    obj))

(defn- get-branch-content
  [{:keys [^S3Client s3 bucket prefix branch]}]
  (-> (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                              (.bucket bucket)
                              (.prefix (str prefix "/refs/heads/" branch "/"))
                              (.build)))
      .contents))

(defn delete-branch
  [{:keys [^S3Client s3 bucket branch] :as mb}]
  (let [objs (get-branch-content mb)]
    (print (str "Delete " branch " branch [yes/no]: "))
    (flush)
    (let [resp (str/trim (or (read-line) ""))]
      (if (= (str/lower-case resp) "yes")
        (do
          (doseq [^S3Object o objs]
            (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                                   (.bucket bucket)
                                   (.key (.key o))
                                   (.build))))
          (println (str "Branch " branch " has been deleted")))
        (println "Aborted")))))

(defn protect-branch
  [{:keys [^S3Client s3 bucket prefix branch]}]
  (.putObject s3
              (-> (PutObjectRequest/builder)
                  (.bucket bucket)
                  (.key (str prefix "/refs/heads/" branch "/PROTECTED#"))
                  (.build))
              (RequestBody/empty))
  (println (str "Branch " branch " is now protected")))

(defn unprotect-branch
  [{:keys [^S3Client s3 bucket prefix branch]}]
  (.deleteObject s3 (-> (DeleteObjectRequest/builder)
                         (.bucket bucket)
                         (.key (str prefix "/refs/heads/" branch "/PROTECTED#"))
                         (.build)))
  (println (str "Branch " branch " is now unprotected")))

(defn process-cmd-mb
  [mb cmd]
  (condp = cmd
    "delete-branch" (delete-branch mb)
    "protect"       (protect-branch mb)
    "unprotect"     (unprotect-branch mb)
    nil))

;; ---------------------------------------------------------------------------
;; main
;; ---------------------------------------------------------------------------

(def cli-options
  [[nil  "--delete-bundle"        "Delete the bundle instead of creating a new branch"
    :id :delete-bundle?]
   [nil  "--lock-ttl SECONDS"     (str "Seconds after which a lock is considered stale (default: "
                                       default-lock-ttl-seconds ")")
    :id      :lock-ttl
    :default default-lock-ttl-seconds
    :parse-fn #(Long/parseLong %)]
   [nil  "--delete-stale-locks"   "Delete stale lock files found during doctor run"
    :id :delete-stale-locks?]
   ["-h" "--help"]])

(defn -main [& args]
  (when (< (count args) 2)
    (binding [*out* *err*]
      (println "usage: git-s3 <command> <remote> [options]"))
    (System/exit 1))
  (let [[command remote & rest-args] args
        {:keys [options errors]} (cli/parse-opts rest-args cli-options)
        branch (first rest-args)]  ; positional branch arg
    (when errors
      (binding [*out* *err*]
        (doseq [e errors] (println e)))
      (System/exit 1))
    (let [remote-url
          (try
            (get-remote-url remote)
            (catch Exception e
              (binding [*out* *err*]
                (println (str "fatal: " (.getMessage e))))
              (System/exit 1)))]
      (let [{:keys [profile bucket prefix]} (parse-git-url remote-url)]
        (try
          (condp = command
            "doctor"
            (let [d (make-doctor profile bucket prefix
                                 (:delete-bundle? options)
                                 (:lock-ttl options)
                                 (:delete-stale-locks? options))]
              (doctor-run d))

            "delete-branch"
            (if (nil? branch)
              (do (binding [*out* *err*] (println "fatal: branch argument is required"))
                  (System/exit 1))
              (try
                (let [mb (make-manage-branch profile bucket prefix branch)]
                  (process-cmd-mb mb "delete-branch"))
                (catch clojure.lang.ExceptionInfo e
                  (binding [*out* *err*] (println (str "fatal: " (.getMessage e))))
                  (System/exit 1))))

            "protect"
            (if (nil? branch)
              (do (binding [*out* *err*] (println "fatal: branch argument is required"))
                  (System/exit 1))
              (try
                (let [mb (make-manage-branch profile bucket prefix branch)]
                  (process-cmd-mb mb "protect"))
                (catch clojure.lang.ExceptionInfo e
                  (binding [*out* *err*] (println (str "fatal: " (.getMessage e))))
                  (System/exit 1))))

            "unprotect"
            (if (nil? branch)
              (do (binding [*out* *err*] (println "fatal: branch argument is required"))
                  (System/exit 1))
              (try
                (let [mb (make-manage-branch profile bucket prefix branch)]
                  (process-cmd-mb mb "unprotect"))
                (catch clojure.lang.ExceptionInfo e
                  (binding [*out* *err*] (println (str "fatal: " (.getMessage e))))
                  (System/exit 1))))

            ;; unknown command
            (do (binding [*out* *err*]
                  (println (str "unknown command: " command)))
                (System/exit 1)))
          (System/exit 0)
          (catch S3Exception e
            (binding [*out* *err*]
              (println (str "fatal: invalid credentials " e)))
            (System/exit 1)))))))
