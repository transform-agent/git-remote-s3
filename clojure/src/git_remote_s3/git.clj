; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.git
  "Thin wrappers around git sub-commands invoked as external processes.
   Mirrors git_remote_s3/git.py."
  (:require [clojure.string :as str])
  (:import [java.io File IOException]
           [java.lang ProcessBuilder ProcessBuilder$Redirect]))

;; ---------------------------------------------------------------------------
;; Error type
;; ---------------------------------------------------------------------------

(defn git-error
  "Creates an ex-info map tagged as a git error."
  [message]
  (ex-info message {:type :git-error}))

(defn git-error?
  "Returns true if `e` is a git error thrown by this namespace."
  [e]
  (= :git-error (:type (ex-data e))))

;; ---------------------------------------------------------------------------
;; Private helpers
;; ---------------------------------------------------------------------------

(defn- run-process
  "Runs `args` as an external command.

  Options:
    :redirect-stdout - one of :pipe (default), :inherit, :stderr
    :redirect-stderr - one of :pipe (default), :inherit, :discard
    :check           - when true (default), throws GitError on non-zero exit

  Returns a map {:exit <int> :out <String> :err <String>}."
  [args & {:keys [redirect-stdout redirect-stderr check]
           :or   {redirect-stdout :pipe
                  redirect-stderr :pipe
                  check           true}}]
  (let [pb (ProcessBuilder. ^java.util.List (map str args))]
    ;; stdout
    (case redirect-stdout
      :pipe    (.redirectOutput pb ProcessBuilder$Redirect/PIPE)
      :inherit (.redirectOutput pb ProcessBuilder$Redirect/INHERIT)
      :stderr  (.redirectOutput pb ProcessBuilder$Redirect/INHERIT))
    ;; stderr
    (case redirect-stderr
      :pipe    (.redirectError pb ProcessBuilder$Redirect/PIPE)
      :inherit (.redirectError pb ProcessBuilder$Redirect/INHERIT)
      :discard (.redirectError pb ProcessBuilder$Redirect/DISCARD))
    (let [proc (.start pb)
          out  (String. (.readAllBytes (.getInputStream proc)) "UTF-8")
          err  (String. (.readAllBytes (.getErrorStream proc)) "UTF-8")
          exit (.waitFor proc)]
      (when (and check (not (zero? exit)))
        (throw (git-error (if (str/blank? err) out err))))
      {:exit exit :out out :err err})))

;; ---------------------------------------------------------------------------
;; Public API
;; ---------------------------------------------------------------------------

(defn archive
  "Archives the content of the repo into <folder>/repo.zip using `git archive`.

  Returns the path to the archive file."
  [& {:keys [folder ref]}]
  (let [file-path (str folder "/repo.zip")]
    (run-process ["git" "archive" "--format" "zip" "--output" file-path ref])
    file-path))

(defn bundle
  "Bundles a ref into <folder>/<sha>.bundle using `git bundle create`.

  Returns the path to the bundle file."
  [& {:keys [folder sha ref]}]
  (let [file-path (str folder "/" sha ".bundle")]
    (run-process ["git" "bundle" "create" file-path ref])
    file-path))

(defn unbundle
  "Unbundles <folder>/<sha>.bundle for `ref` using `git bundle unbundle`.

  Stdout of the sub-process is forwarded to the JVM's stderr (matching
  the Python `stdout=sys.stderr` behaviour)."
  [& {:keys [folder sha ref]}]
  ;; git bundle unbundle writes progress to stdout; we redirect that to
  ;; the process's inherited stderr so it reaches the user via System.err.
  (let [pb (ProcessBuilder. ^java.util.List
                            ["git" "bundle" "unbundle"
                             (str folder "/" sha ".bundle") ref])]
    ;; Both stdout and stderr go to the parent's stderr
    (.redirectOutput pb ProcessBuilder$Redirect/INHERIT)
    (.redirectError  pb ProcessBuilder$Redirect/INHERIT)
    (let [proc (.start pb)
          exit (.waitFor proc)]
      (when-not (zero? exit)
        (throw (git-error (str "git bundle unbundle failed with exit " exit)))))))

(defn rev-parse
  "Returns the full SHA for `ref`, or throws a git-error if not found."
  [ref]
  (let [{:keys [exit out]} (run-process ["git" "rev-parse" ref]
                                        :check false)]
    (if (zero? exit)
      (str/trim out)
      (throw (git-error (str "fatal: " ref " not found"))))))

(defn is-ancestor
  "Returns true when `ancestor` is a git ancestor of `descendant`."
  [ancestor descendant]
  (let [{:keys [exit]} (run-process
                        ["git" "merge-base" "--is-ancestor" ancestor descendant]
                        :check           false
                        :redirect-stdout :discard
                        :redirect-stderr :discard)]
    (zero? exit)))

(defn get-remote-url
  "Returns the URL for `remote`, or throws a git-error if not found."
  [remote]
  (let [{:keys [exit out]} (run-process ["git" "remote" "get-url" remote]
                                        :check false)]
    (if (zero? exit)
      (str/trim out)
      (throw (git-error (str "fatal: " remote " not found"))))))

(defn validate-ref-name
  "Returns true when `name` is a valid git ref name.

  Mirrors the Python implementation which follows:
  https://github.com/git/git/blob/406f326d/refs.c#L170"
  [name]
  (nil? (re-find
         #"(^\.)|(\.\.)|([:\?\[\\\^\~\s\*\]])|(\.lock$)|(/$)|(@\{)|([\x00-\x1f])"
         name)))

(defn get-last-commit-message
  "Returns the abbreviated hash and subject of the last commit."
  []
  (let [{:keys [exit out]} (run-process ["git" "log" "-1" "--pretty=%h %s"]
                                        :check false)]
    (if (zero? exit)
      (str/trim out)
      (throw (git-error "fatal: an error has occurred")))))
