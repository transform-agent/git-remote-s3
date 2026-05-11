-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | HSpec test runner.
--
-- Combines all spec modules into a single test suite.
module Main (main) where

import Test.Hspec

import qualified ParseUrlSpec
import qualified RemoteSpec
import qualified ParallelFetchSpec

main :: IO ()
main = hspec $ do
  describe "ParseUrl"      ParseUrlSpec.spec
  describe "Remote"        RemoteSpec.spec
  describe "ParallelFetch" ParallelFetchSpec.spec
