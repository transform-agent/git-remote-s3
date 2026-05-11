; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.common-test
  "Tests for parse-git-url, mirroring test/parse_url_test.py"
  (:require [clojure.test :refer [deftest is testing]]
            [git-remote-s3.common :refer [parse-git-url]]
            [git-remote-s3.enums  :as enums]))

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defn- parse
  "Convenience wrapper – returns [uri-scheme profile bucket prefix]."
  [url]
  (let [{:keys [uri-scheme profile bucket prefix]} (parse-git-url url)]
    [uri-scheme profile bucket prefix]))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(deftest test-parse-url-trailing-slash-no-profile
  (let [[scheme profile bucket prefix] (parse "s3://bucket-name/path/to/")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket-name" bucket))
    (is (nil? profile))
    (is (= "path/to" prefix))))

(deftest test-parse-url-no-profile
  (let [[scheme profile bucket prefix] (parse "s3://bucket-name/path/to")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket-name" bucket))
    (is (nil? profile))
    (is (= "path/to" prefix))))

(deftest test-parse-url
  (let [[scheme profile bucket prefix] (parse "s3://profile-test@bucket-name/path/to")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket-name" bucket))
    (is (= "profile-test" profile))
    (is (= "path/to" prefix))))

(deftest test-parse-url-issue5
  (let [[scheme profile bucket prefix] (parse "s3://er@bucket/path/")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket" bucket))
    (is (= "er" profile))
    (is (= "path" prefix))))

(deftest test-parse-url-1-char-profile
  (let [[scheme profile bucket prefix] (parse "s3://A@bucket/path/")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket" bucket))
    (is (= "A" profile))
    (is (= "path" prefix))))

(deftest test-parse-url-all-supported-symbols-in-profile
  (let [[scheme profile bucket prefix] (parse "s3://Ab-tr+54_quwww@bucket/path/")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket" bucket))
    (is (= "Ab-tr+54_quwww" profile))
    (is (= "path" prefix))))

(deftest test-parse-url-unsupported-symbols-in-profile
  ;; The Python regex captures everything before '@', including '!'
  (let [[scheme profile bucket prefix] (parse "s3://A!@bucket/path/")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket" bucket))
    (is (= "A!" profile))
    (is (= "path" prefix))))

(deftest test-parse-url-empty-profile
  ;; "s3://@bucket/path/" — empty profile → regex won't match
  (let [[scheme profile bucket prefix] (parse "s3://@bucket/path/")]
    (is (nil? scheme))
    (is (nil? bucket))
    (is (nil? profile))
    (is (nil? prefix))))

(deftest test-parse-url-no-prefix-trailing-slash
  (let [[scheme profile bucket prefix] (parse "s3://profile-test@bucket-name/")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket-name" bucket))
    (is (= "profile-test" profile))
    (is (nil? prefix))))

(deftest test-parse-url-no-prefix
  (let [[scheme profile bucket prefix] (parse "s3://profile-test@bucket-name")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket-name" bucket))
    (is (= "profile-test" profile))
    (is (nil? prefix))))

(deftest test-parse-url-no-prefix-no-profile
  (let [[scheme profile bucket prefix] (parse "s3://bucket-name")]
    (is (= enums/uri-scheme-s3 scheme))
    (is (= "bucket-name" bucket))
    (is (nil? profile))
    (is (nil? prefix))))

(deftest test-parse-url-not-valid
  (let [[scheme profile bucket prefix] (parse "s4://bucket-name/path/to")]
    (is (nil? scheme))
    (is (nil? bucket))
    (is (nil? profile))
    (is (nil? prefix))))

(deftest test-parse-url-none
  (let [[scheme profile bucket prefix] (parse nil)]
    (is (nil? scheme))
    (is (nil? bucket))
    (is (nil? profile))
    (is (nil? prefix))))

(deftest test-parse-url-uri-scheme-s3-zip-no-profile
  (let [[scheme profile bucket prefix] (parse "s3+zip://bucket-name/path/to")]
    (is (= enums/uri-scheme-s3zip scheme))
    (is (= "bucket-name" bucket))
    (is (nil? profile))
    (is (= "path/to" prefix))))

(deftest test-parse-url-uri-scheme-s3-zip
  (let [[scheme profile bucket prefix] (parse "s3+zip://profile-test@bucket-name/path/to")]
    (is (= enums/uri-scheme-s3zip scheme))
    (is (= "bucket-name" bucket))
    (is (= "profile-test" profile))
    (is (= "path/to" prefix))))

(deftest test-parse-url-uri-scheme-not-valid
  (let [[scheme profile bucket prefix] (parse "s3+foo://bucket-name/path/to")]
    (is (nil? scheme))
    (is (nil? bucket))
    (is (nil? profile))
    (is (nil? prefix))))
