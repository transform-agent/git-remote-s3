; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.lfs
  "git-lfs custom transfer agent backed by Amazon S3.
   Mirrors git_remote_s3/lfs.py."
  (:gen-class)
  (:require [clojure.string        :as str]
            [clojure.tools.logging :as log]
            [cheshire.core         :as json]
            [git-remote-s3.common  :refer [parse-git-url]]
            [git-remote-s3.git     :refer [validate-ref-name]])
  (:import [java.io File]
           [java.util.concurrent.atomic AtomicLong]
           [software.amazon.awssdk.auth.credentials
            ProfileCredentialsProvider
            DefaultCredentialsProvider]
           [software.amazon.awssdk.services.s3 S3Client]
           [software.amazon.awssdk.services.s3.model
            ListObjectsV2Request
            GetObjectRequest
            PutObjectRequest
            S3Exception]
           [software.amazon.awssdk.core.sync  RequestBody]
           [software.amazon.awssdk.transfer.s3 S3TransferManager]
           [software.amazon.awssdk.transfer.s3.model
            DownloadFileRequest
            UploadFileRequest]
           [software.amazon.awssdk.transfer.s3.progress
            TransferListener]))

;; ---------------------------------------------------------------------------
;; Logging bootstrap
;; ---------------------------------------------------------------------------

;; Initialise file-based logging when running as the lfs entry point.
;; (log4j2.xml in resources/ handles the general configuration;
;;  here we just ensure the log level can be overridden by -debug arg.)

;; ---------------------------------------------------------------------------
;; Progress callback
;; ---------------------------------------------------------------------------

(defn- make-progress-listener
  "Returns an AWS SDK TransferListener that emits LFS progress events to stdout."
  [oid]
  (let [seen-so-far (AtomicLong. 0)]
    (reify TransferListener
      (bytesTransferred [_ ctx]
        (let [bytes-amount (-> ctx .progressSnapshot .transferredBytes .orElse 0)
              total        (.addAndGet seen-so-far bytes-amount)
              event        {"event"        "progress"
                            "oid"          oid
                            "bytesSoFar"   total
                            "bytesSinceLast" bytes-amount}]
          (println (json/generate-string event))
          (flush))))))

;; ---------------------------------------------------------------------------
;; Error event helper
;; ---------------------------------------------------------------------------

(defn- write-error-event
  [oid error-msg]
  (let [evt {"event" "complete"
             "oid"   oid
             "error" {"code" 2 "message" error-msg}}]
    (println (json/generate-string evt))
    (flush)))

;; ---------------------------------------------------------------------------
;; LFSProcess record
;; ---------------------------------------------------------------------------

(defrecord LFSProcess [bucket prefix profile ^S3Client s3])

(defn- build-s3-client [profile]
  (let [creds (if profile
                (-> (ProfileCredentialsProvider/builder)
                    (.profileName profile)
                    (.build))
                (DefaultCredentialsProvider/create))]
    (-> (S3Client/builder)
        (.credentialsProvider creds)
        (.build))))

(defn make-lfs-process
  "Constructs an LFSProcess from a raw S3 URI.
  Writes an error JSON event and returns nil when the URI is invalid."
  [s3uri]
  (let [{:keys [profile bucket prefix]} (parse-git-url s3uri)]
    (if (or (nil? bucket) (nil? prefix))
      (do
        (log/error (str "s3 uri " s3uri " is invalid"))
        (let [evt {"error" {"code" 32 "message" (str "s3 uri " s3uri " is invalid")}}]
          (println (json/generate-string evt))
          (flush))
        nil)
      (let [s3 (build-s3-client profile)]
        ;; Send the LFS init acknowledgement
        (println "{}")
        (flush)
        (->LFSProcess bucket prefix profile s3)))))

;; ---------------------------------------------------------------------------
;; upload / download
;; ---------------------------------------------------------------------------

(defn lfs-upload
  "Uploads an LFS object to S3."
  [{:keys [^S3Client s3 bucket prefix]} event]
  (log/debug "upload")
  (try
    (let [oid    (get event "oid")
          s3-key (str prefix "/lfs/" oid)
          ;; Check if object already exists
          resp   (.listObjectsV2 s3 (-> (ListObjectsV2Request/builder)
                                         (.bucket bucket)
                                         (.prefix s3-key)
                                         (.build)))]
      (if (seq (.contents resp))
        (do
          (log/debug "object already exists")
          (println (json/generate-string {"event" "complete" "oid" oid}))
          (flush))
        (let [^S3TransferManager tm
              (-> (S3TransferManager/builder) (.s3Client s3) (.build))
              req (-> (UploadFileRequest/builder)
                      (.putObjectRequest
                       (-> (PutObjectRequest/builder)
                           (.bucket bucket)
                           (.key s3-key)
                           (.build)))
                      (.source (File. (get event "path")))
                      (.addTransferListener (make-progress-listener oid))
                      (.build))]
          (-> tm (.uploadFile req) .completionFuture .join)
          (.close tm)
          (println (json/generate-string {"event" "complete" "oid" oid}))
          (flush))))
    (catch Exception e
      (log/error e)
      (write-error-event (get event "oid") (.getMessage e)))))

(defn lfs-download
  "Downloads an LFS object from S3."
  [{:keys [^S3Client s3 bucket prefix]} event]
  (log/debug "download")
  (try
    (let [oid      (get event "oid")
          temp-dir (-> (File. ".git/lfs/tmp") .getAbsolutePath)
          dest     (str temp-dir "/" oid)
          s3-key   (str prefix "/lfs/" oid)
          ^S3TransferManager tm
          (-> (S3TransferManager/builder) (.s3Client s3) (.build))
          req (-> (DownloadFileRequest/builder)
                  (.getObjectRequest
                   (-> (GetObjectRequest/builder)
                       (.bucket bucket)
                       (.key s3-key)
                       (.build)))
                  (.destination (File. dest))
                  (.addTransferListener (make-progress-listener oid))
                  (.build))]
      (-> tm (.downloadFile req) .completionFuture .join)
      (.close tm)
      (let [done-event {"event" "complete" "oid" oid "path" dest}]
        (println (json/generate-string done-event))
        (flush)))
    (catch Exception e
      (log/error e)
      (write-error-event (get event "oid") (.getMessage e)))))

;; ---------------------------------------------------------------------------
;; install / debug helpers
;; ---------------------------------------------------------------------------

(defn- run-git [& cmd-args]
  (let [pb  (ProcessBuilder. ^java.util.List (map str cmd-args))
        _   (.redirectErrorStream pb true)
        p   (.start pb)
        out (String. (.readAllBytes (.getInputStream p)) "UTF-8")
        rc  (.waitFor p)]
    {:exit rc :out out}))

(defn- install []
  (let [{:keys [exit out]}
        (run-git "git" "config" "--add"
                 "lfs.customtransfer.git-lfs-s3.path" "git-lfs-s3")]
    (when (not (zero? exit))
      (binding [*out* *err*] (println (str/trim out)))
      (System/exit 1)))
  (let [{:keys [exit out]}
        (run-git "git" "config" "--add"
                 "lfs.standalonetransferagent" "git-lfs-s3")]
    (when (not (zero? exit))
      (binding [*out* *err*] (println (str/trim out)))
      (System/exit 1)))
  (println "git-lfs-s3 installed")
  (flush))

;; ---------------------------------------------------------------------------
;; main
;; ---------------------------------------------------------------------------

(defn -main [& args]
  (let [argv (vec args)]
    (when (seq argv)
      (condp = (first argv)
        "install"
        (do (install) (System/exit 0))

        "debug"
        (log/info "debug mode enabled")   ; log level set via log4j2 programmatically

        "enable-debug"
        (do (run-git "git" "config" "--add"
                     "lfs.customtransfer.git-lfs-s3.args" "debug")
            (println "debug enabled")
            (System/exit 0))

        "disable-debug"
        (do (run-git "git" "config" "--unset"
                     "lfs.customtransfer.git-lfs-s3.args")
            (println "debug disabled")
            (System/exit 0))

        ;; unknown command
        (do (println (str "unknown command " (first argv)))
            (System/exit 1)))))

  ;; Event loop
  (let [lfs-process-atom (atom nil)]
    (loop []
      (log/debug "git-lfs-s3 starting")
      (let [line (read-line)]
        (when line
          (log/debug line)
          (let [event (json/parse-string line)]
            (condp = (get event "event")
              "init"
              (let [remote-name (get event "remote")]
                (when-not (validate-ref-name remote-name)
                  (log/error (str "invalid ref " remote-name))
                  (println "{}")
                  (flush)
                  (System/exit 1))
                (let [{:keys [exit out]}
                      (run-git "git" "remote" "get-url" remote-name)]
                  (if (not (zero? exit))
                    (do
                      (log/error (str/trim out))
                      (let [err-evt {"error" {"code" 2
                                              "message" (str "cannot resolve remote \""
                                                             remote-name "\"")}}]
                        (println (json/generate-string err-evt))
                        (flush)
                        (System/exit 1)))
                    (reset! lfs-process-atom
                            (make-lfs-process (str/trim out))))))

              "upload"
              (lfs-upload @lfs-process-atom event)

              "download"
              (lfs-download @lfs-process-atom event)

              ;; ignore unknown events
              nil))
          (recur))))))
