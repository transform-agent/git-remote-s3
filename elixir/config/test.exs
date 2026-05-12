import Config

# In the test environment we swap the real ExAws S3 module for a Mox mock.
# The actual mock is declared in test/support/mocks.ex.
config :git_remote_s3, :s3_client, GitRemoteS3.MockS3Client

config :logger, level: :warning
