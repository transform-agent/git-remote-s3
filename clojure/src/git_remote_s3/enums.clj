; SPDX-FileCopyrightText: Amazon.com, Inc. or its affiliates
;
; SPDX-License-Identifier: Apache-2.0

(ns git-remote-s3.enums
  "URI scheme constants, mirroring the Python UriScheme enum.")

;; The two supported URI schemes are represented as Clojure keywords.
(def uri-scheme-s3    :s3)
(def uri-scheme-s3zip :s3+zip)

;; Set used for membership testing / validation.
(def all-uri-schemes #{uri-scheme-s3 uri-scheme-s3zip})

(defn valid-uri-scheme?
  "Returns true when `scheme` is one of the known URI schemes."
  [scheme]
  (contains? all-uri-schemes scheme))
