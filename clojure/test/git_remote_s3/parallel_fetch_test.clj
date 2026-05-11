; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.parallel-fetch-test
  "Parallel-fetch tests, mirroring test/parallel_fetch_test.py."
  (:require [clojure.test  :refer [deftest is]]
            [clojure.string :as str]
            [git-remote-s3.enums  :as enums]
            [git-remote-s3.remote :as remote]
            [git-remote-s3.git    :as git]))

;; ---------------------------------------------------------------------------
;; Constants
;; ---------------------------------------------------------------------------

(def sha1 "c105d19ba64965d2c9d3d3246e7269059ef8bb8a")
(def sha2 "c105d19ba64965d2c9d3d3246e7269059ef8bb8b")
(def sha3 "c105d19ba64965d2c9d3d3246e7269059ef8bb8c")
(def test-branch "pytest")

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defn- make-remote []
  ;; Bypass the live-S3 constructor
  (->remote/S3Remote
   enums/uri-scheme-s3 nil "test_bucket" "test_prefix"
   nil
   (atom nil)
   (atom #{})
   (atom [])
   (atom [])
   remote/default-lock-ttl-seconds
   (java.util.concurrent.locks.ReentrantLock.)))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(deftest test-process-fetch-cmds-empty-list
  "process-fetch-cmds handles empty command list gracefully – no S3 calls."
  (let [r           (make-remote)
        fetch-calls (atom 0)]
    (with-redefs [remote/cmd-fetch (fn [_ _] (swap! fetch-calls inc))]
      (remote/process-fetch-cmds r [])
      (is (zero? @fetch-calls)))))

(deftest test-process-fetch-cmds-single-command
  "Processing a single fetch command."
  (let [r           (make-remote)
        fetch-calls (atom 0)]
    (with-redefs [remote/cmd-fetch
                  (fn [r args]
                    (swap! fetch-calls inc)
                    (let [[_ sha _] (str/split (str/trim args) #"\s+" 3)]
                      (swap! (:fetched-refs-atom r) conj sha)))]
      (remote/process-fetch-cmds r [(str "fetch " sha1 " refs/heads/" test-branch)])
      (is (= 1 @fetch-calls))
      (is (contains? @(:fetched-refs-atom r) sha1)))))

(deftest test-process-fetch-cmds-multiple-commands
  "Processing multiple fetch commands in parallel."
  (let [r           (make-remote)
        fetch-calls (atom 0)]
    (with-redefs [remote/cmd-fetch
                  (fn [r args]
                    (swap! fetch-calls inc)
                    (let [[_ sha _] (str/split (str/trim args) #"\s+" 3)]
                      (swap! (:fetched-refs-atom r) conj sha)))]
      (remote/process-fetch-cmds r [(str "fetch " sha1 " refs/heads/" test-branch)
                                    (str "fetch " sha2 " refs/heads/" test-branch)
                                    (str "fetch " sha3 " refs/heads/" test-branch)])
      (is (= 3 @fetch-calls))
      (is (contains? @(:fetched-refs-atom r) sha1))
      (is (contains? @(:fetched-refs-atom r) sha2))
      (is (contains? @(:fetched-refs-atom r) sha3)))))

(deftest test-process-fetch-cmds-uses-thread-pool
  "process-fetch-cmds processes commands in parallel (all three SHAs end up in fetched-refs)."
  (let [r           (make-remote)
        fetch-calls (atom 0)]
    (with-redefs [remote/cmd-fetch
                  (fn [r args]
                    (swap! fetch-calls inc)
                    (let [[_ sha _] (str/split (str/trim args) #"\s+" 3)]
                      (swap! (:fetched-refs-atom r) conj sha)))]
      (remote/process-fetch-cmds r [(str "fetch " sha1 " refs/heads/" test-branch)
                                    (str "fetch " sha2 " refs/heads/" test-branch)
                                    (str "fetch " sha3 " refs/heads/" test-branch)])
      (is (= 3 @fetch-calls))
      (is (contains? @(:fetched-refs-atom r) sha1))
      (is (contains? @(:fetched-refs-atom r) sha2))
      (is (contains? @(:fetched-refs-atom r) sha3)))))

(deftest test-process-cmd-batch-processing
  "Fetch commands are collected and processed as a batch on empty line."
  (let [r                   (make-remote)
        batch-process-calls (atom 0)
        batch-args-capture  (atom nil)]
    ;; Enqueue three fetch commands (no processing yet)
    (remote/process-cmd r (str "fetch " sha1 " refs/heads/" test-branch))
    (remote/process-cmd r (str "fetch " sha2 " refs/heads/" test-branch))
    (remote/process-cmd r (str "fetch " sha3 " refs/heads/" test-branch))

    ;; Verify commands are queued but not yet dispatched
    (is (= 3 (count @(:fetch-cmds-atom r))))

    ;; Override process-fetch-cmds to capture the call
    (with-redefs [remote/process-fetch-cmds
                  (fn [_ cmds]
                    (swap! batch-process-calls inc)
                    (reset! batch-args-capture cmds))]
      ;; Empty line triggers batch dispatch
      (let [out (java.io.StringWriter.)]
        (binding [*out* out]
          (remote/process-cmd r "\n")))

      (is (= 1 @batch-process-calls))
      (is (= 3 (count @batch-args-capture)))
      ;; Queue cleared
      (is (= 0 (count @(:fetch-cmds-atom r)))))))

(deftest test-thread-safety-of-fetched-refs
  "fetched-refs atom is updated safely under concurrent access."
  (let [r       (make-remote)
        n       20
        futures (mapv (fn [_]
                        (future
                          (with-redefs [remote/cmd-fetch
                                        (fn [r args]
                                          (let [[_ sha _]
                                                (str/split (str/trim args) #"\s+" 3)]
                                            ;; Simulate the lock-protected swap
                                            (.lock (:fetched-refs-lock r))
                                            (try
                                              (swap! (:fetched-refs-atom r) conj sha)
                                              (finally
                                                (.unlock (:fetched-refs-lock r))))))]
                            (remote/cmd-fetch r (str "fetch " sha1 " refs/heads/" test-branch)))))
                      (range n))]
    (doseq [f futures] (deref f))
    (is (contains? @(:fetched-refs-atom r) sha1))))

(deftest test-cmd-fetch-thread-safety
  "cmd-fetch is thread-safe when called concurrently."
  (let [r       (make-remote)
        n       5
        futures (mapv (fn [_]
                        (future
                          (with-redefs [remote/cmd-fetch
                                        (fn [r args]
                                          (let [[_ sha _]
                                                (str/split (str/trim args) #"\s+" 3)]
                                            (swap! (:fetched-refs-atom r) conj sha)))]
                            (remote/cmd-fetch r (str "fetch " sha1 " refs/heads/" test-branch)))))
                      (range n))]
    (doseq [f futures] (deref f))
    (is (contains? @(:fetched-refs-atom r) sha1))))
