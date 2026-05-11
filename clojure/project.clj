;; SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
;;
;; SPDX-License-Identifier: Apache-2.0

(defproject git-remote-s3 "0.3.2"
  :description "A git remote helper for Amazon S3"
  :url "https://github.com/awslabs/git-remote-s3"
  :license {:name "Apache-2.0"
            :url  "https://www.apache.org/licenses/LICENSE-2.0"}

  :dependencies [[org.clojure/clojure "1.11.1"]
                 ;; AWS SDK v2
                 [software.amazon.awssdk/s3 "2.25.60"]
                 [software.amazon.awssdk/auth "2.25.60"]
                 [software.amazon.awssdk/regions "2.25.60"]
                 [software.amazon.awssdk/transfer-manager "2.25.60"]
                 ;; CLI arg parsing
                 [org.clojure/tools.cli "1.1.230"]
                 ;; JSON
                 [cheshire "5.12.0"]
                 ;; Logging
                 [org.clojure/tools.logging "1.3.0"]
                 [org.apache.logging.log4j/log4j-core "2.23.1"]
                 [org.apache.logging.log4j/log4j-api "2.23.1"]
                 [org.apache.logging.log4j/log4j-slf4j2-impl "2.23.1"]
                 [org.slf4j/slf4j-api "2.0.13"]]

  :source-paths ["src"]
  :test-paths   ["test"]

  ;; Resource directory contains log4j2.xml
  :resource-paths ["resources"]

  ;; ── Entry-point profiles ──────────────────────────────────────────────────
  ;; Each profile produces a standalone uberjar with the correct -main class.

  :profiles
  {:remote
   {:main    git-remote-s3.remote
    :aot     [git-remote-s3.remote
              git-remote-s3.enums
              git-remote-s3.common
              git-remote-s3.git]
    :uberjar-name "git-remote-s3.jar"}

   :lfs
   {:main    git-remote-s3.lfs
    :aot     [git-remote-s3.lfs
              git-remote-s3.enums
              git-remote-s3.common
              git-remote-s3.git]
    :uberjar-name "git-lfs-s3.jar"}

   :manage
   {:main    git-remote-s3.manage
    :aot     [git-remote-s3.manage
              git-remote-s3.enums
              git-remote-s3.common
              git-remote-s3.git
              git-remote-s3.remote]
    :uberjar-name "git-s3.jar"}

   :dev
   {:dependencies [[org.clojure/test.check "1.1.1"]]}}

  ;; Default run target (the remote helper is the primary binary)
  :main git-remote-s3.remote
  :aot  [git-remote-s3.remote
         git-remote-s3.lfs
         git-remote-s3.manage
         git-remote-s3.enums
         git-remote-s3.common
         git-remote-s3.git])
