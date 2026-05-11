; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.common
  "Parses s3:// and s3+zip:// remote-origin URIs."
  (:require [git-remote-s3.enums :as enums]
            [clojure.string :as str]))

(defn parse-git-url
  "Parses the elements in a s3:// (or s3+zip://) remote-origin URI.

  Returns a map with keys :uri-scheme, :profile, :bucket, :prefix.
  All values are nil when the URI is invalid or nil itself."
  [url]
  (let [nil-result {:uri-scheme nil :profile nil :bucket nil :prefix nil}]
    (if (nil? url)
      nil-result
      ;; Regex mirrors the Python original:
      ;;   (s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?
      ;; Group 1: scheme  Group 2: profile@ (optional)
      ;; Group 3: bucket  Group 4: prefix   (optional)
      (let [pattern (re-pattern
                     "(s3|s3\\+zip)://([^@]+@)?([a-z0-9][a-z0-9.\\-]{2,62})/?(.+)?")
            m (re-find pattern url)]
        (if (nil? m)
          nil-result
          ;; m is [full-match g1 g2 g3 g4]
          (let [[_ scheme-str profile-at bucket prefix-raw] m
                profile (when profile-at
                          ;; strip trailing '@'
                          (subs profile-at 0 (dec (count profile-at))))
                prefix  (when prefix-raw
                          (str/replace (str/trim prefix-raw) #"^/+|/+$" ""))
                prefix  (when (and prefix (not (str/blank? prefix))) prefix)
                uri-scheme (case scheme-str
                              "s3"     enums/uri-scheme-s3
                              "s3+zip" enums/uri-scheme-s3zip
                              nil)]
            {:uri-scheme uri-scheme
             :profile    profile
             :bucket     bucket
             :prefix     prefix}))))))
